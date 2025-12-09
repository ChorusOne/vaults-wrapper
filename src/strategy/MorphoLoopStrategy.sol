// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {IStETH} from "src/interfaces/core/IStETH.sol";
import {IWstETH} from "src/interfaces/core/IWstETH.sol";
import {StrategyCallForwarderRegistry} from "src/strategy/StrategyCallForwarderRegistry.sol";
import {FeaturePausable} from "src/utils/FeaturePausable.sol";

import {IMorpho, Id, Market, MarketParams, Position} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoRepayCallback, IMorphoSupplyCallback} from "lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "lib/morpho-blue/src/interfaces/IOracle.sol";
import {IWETH} from "src/interfaces/erc20/IWETH.sol";
import {IDexRouter} from "src/interfaces/IDexRouter.sol";

import {console} from "forge-std/console.sol";

contract MorphoLoopStrategy is
    IStrategy,
    IMorphoRepayCallback,
    IMorphoSupplyCallback,
    AccessControlEnumerableUpgradeable,
    FeaturePausable,
    StrategyCallForwarderRegistry
{
    StvStETHPool private immutable POOL_;

    IStETH public immutable STETH;
    IWETH public immutable WETH;
    IWstETH public immutable WSTETH;

    IMorpho public immutable MORPHO;

    // Morpho market parameters stored as individual immutables
    address public immutable MARKET_LOAN_TOKEN;
    address public immutable MARKET_COLLATERAL_TOKEN;
    address public immutable MARKET_ORACLE;
    address public immutable MARKET_IRM;
    uint256 public immutable MARKET_LLTV;
    Id public immutable MARKET_ID;

    // Maximum leverage in basis points (e.g., 30000 = 3x)
    uint256 public immutable MAX_LEVERAGE_BP;

    // DEX router for wstETH -> WETH swaps during withdrawal
    IDexRouter public immutable DEX_ROUTER;

    // ACL
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    struct LoopSupplyParams {
        uint256 targetLeverageBp; // Target leverage (10000-30000 = 1x-3x)
    }

    struct LoopExitParams {
        uint256 slippageBps; // DEX slippage tolerance (e.g., 100 = 1%)
    }

    // Morpho callbacks.
    enum MorphoCallback {
        Unused,
        OnMorphoSupplyCollateral,
        OnMorphoRepay
    }

    // Data passed to onMorphoRepay callback
    struct RepayCallbackData {
        uint256 slippageBps;
        address callForwarder;
    }

    // Temporary storage for callback context
    struct CallbackContext {
        address callBackFrom;
        uint256 borrowAmount;
        MorphoCallback callbackType;
    }

    CallbackContext private _callbackContext;

    event LoopExecuted(
        address indexed user,
        uint256 initialCollateral,
        uint256 finalCollateral,
        uint256 totalDebt,
        uint256 actualLeverageBp
    );

    event ExitRequested(address indexed user, bytes32 requestId, uint256 collateralWithdrawn, uint256 debtRepaid);

    error InvalidLeverage();
    error UnauthorizedCallback();
    error InsufficientCollateral();
    error InsufficientDeposit();
    error NoActiveContext();
    error InvalidMorphoCallback();
    error ZeroArgument(string name);

    constructor(
        bytes32 _strategyId,
        address _strategyCallForwarderImpl,
        address _pool,
        address _morpho,
        address _weth,
        address _dexRouter,
        MarketParams memory _marketParams,
        uint256 _maxLeverageBp
    ) StrategyCallForwarderRegistry(_strategyId, _strategyCallForwarderImpl) {
        if (_pool == address(0)) revert ZeroArgument("_pool");
        if (_morpho == address(0)) revert ZeroArgument("_morpho");
        if (_weth == address(0)) revert ZeroArgument("_weth");
        if (_dexRouter == address(0)) revert ZeroArgument("_dexRouter");
        if (_marketParams.loanToken != _weth) revert ZeroArgument("loan token must be WETH");

        POOL_ = StvStETHPool(payable(_pool));
        WSTETH = IWstETH(POOL_.WSTETH());
        STETH = IStETH(POOL_.STETH());
        MORPHO = IMorpho(_morpho);
        WETH = IWETH(_weth);
        DEX_ROUTER = IDexRouter(_dexRouter);

        // Store market params as individual immutables
        MARKET_LOAN_TOKEN = _marketParams.loanToken;
        MARKET_COLLATERAL_TOKEN = _marketParams.collateralToken;
        MARKET_ORACLE = _marketParams.oracle;
        MARKET_IRM = _marketParams.irm;
        MARKET_LLTV = _marketParams.lltv;
        MARKET_ID = Id.wrap(keccak256(abi.encode(_marketParams)));
        MAX_LEVERAGE_BP = _maxLeverageBp;

        require(_marketParams.collateralToken == address(WSTETH), "Collateral must be wstETH");

        // Note: We do NOT call _disableInitializers() here because this contract
        // can be used both directly (for testing/simple deployments) and via proxy (for production).
        // If used via proxy, the factory will ensure the implementation has initializers disabled.
        _pauseFeature(SUPPLY_FEATURE);
    }

    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert ZeroArgument("_admin");

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function POOL() external view returns (address) {
        return address(POOL_);
    }

    /**
     * @notice Reconstructs the MarketParams struct from immutable fields
     * @return MarketParams struct for use with Morpho functions
     */
    function getMarketParams() public view returns (MarketParams memory) {
        return
            MarketParams({
                loanToken: MARKET_LOAN_TOKEN,
                collateralToken: MARKET_COLLATERAL_TOKEN,
                oracle: MARKET_ORACLE,
                irm: MARKET_IRM,
                lltv: MARKET_LLTV
            });
    }

    receive() external payable {}

    // =================================================================================
    // SUPPLY WITH ATOMIC LOOPING
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function supply(
        address _referral,
        uint256 /* _wstethToMint is not used, we always mint the maximum */,
        bytes calldata _params
    ) external payable returns (uint256 stv) {
        console.log("=== supply() ===");
        _checkFeatureNotPaused(SUPPLY_FEATURE);

        LoopSupplyParams memory params = abi.decode(_params, (LoopSupplyParams));
        if (params.targetLeverageBp < 10000) revert InvalidLeverage();
        if (params.targetLeverageBp > MAX_LEVERAGE_BP) revert InvalidLeverage();

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        // 2. Execute atomic borrow and stake via Morpho callback
        _executeBorrowStakeRepay(callForwarder, params);

        // TODO figure out what to return here. Should probably return the total stv and wstETH minted.
        emit StrategySupplied(msg.sender, _referral, msg.value, stv, 0, _params);
    }

    // Type of collateral supply callback data.
    struct SupplyCollateralData {
        MarketParams marketParams;
        uint256 loanAmount;
        address loanOwner;
    }

    function _executeBorrowStakeRepay(IStrategyCallForwarder callForwarder, LoopSupplyParams memory params) internal {
        console.log("=== _executeBorrowStakeRepay ===");
        MarketParams memory marketParams = getMarketParams();

        // Figure out how much stETH we can mint for the deposited ETH.
        uint256 initialStEth = POOL_.remainingMintingCapacitySharesOf(address(callForwarder), msg.value);
        console.log("Can mint %d stETH for %d ETH", initialStEth, msg.value);

        // 1. Deposit ETH to pool and get stvETH.
        uint256 stv = POOL_.depositETH{value: msg.value}(address(callForwarder), address(0));
        console.log("Got %d stvTokens for %d ETH deposit", stv, msg.value);

        // Mint initial stETH from pool.
        callForwarder.doCall(address(POOL_), abi.encodeWithSelector(POOL_.mintStethShares.selector, initialStEth));
        console.log("Minted stETH");

        // Wrap stETH for wstETH.
        callForwarder.doCall(
            address(STETH),
            abi.encodeWithSelector(WSTETH.approve.selector, address(WSTETH), initialStEth)
        );
        bytes memory data = callForwarder.doCall(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.wrap.selector, initialStEth)
        );
        uint256 initialWstEth = abi.decode(data, (uint256));
        console.log("Minted %d wstETH for %d stETH", initialWstEth, initialStEth);

        // // 1. Get the price from the Morpho Oracle.
        // // Price is scaled by 1e36: price = (unitCollateral * price) / unitLoan
        // uint256 morphoOraclePrice = IOracle(marketParams.oracle).price();

        // // 2. Calculate the value of initialWstEth terms of loan assets (WETH)
        // // value = (amount * price) / 1e36
        // uint256 initialValueInWETH = (initialWstEth * morphoOraclePrice) / 1e36;

        // 3. Calculate Target Borrow Amount based on requested leverage
        // ETH <-> WETH is always 1:1 for deposit() and withdraw()
        // Leverage = (Equity + Debt) / Equity
        // Debt = Equity * (Leverage - 1initialWstEth
        // TargetBorrow = InitialValue * (TargetLeverage - 1)
        // TargetLeverage is in bps (e.g. 20000 = 2x)
        uint256 targetBorrowAmount = (msg.value * (params.targetLeverageBp - 10000)) / 10000;

        // 4. Calculate Max Safe Borrow Amount based on LLTV
        // For a single borrow iteration: MaxBorrow = CollateralValue * LLTV
        // We use a 95% safety buffer to avoid immediate liquidation or issues with price fluctuations
        uint256 loan_lltv = marketParams.lltv;
        console.log("Morpho LLTV: %d", loan_lltv);
        uint256 ltv_target = loan_lltv - 0.03e18; // 30 bps under LLTV
        console.log("Morpho LTV target", ltv_target);

        uint256 maxMintLidoBps = 10000 - POOL_.reserveRatioBP();
        uint256 lidoLTV = maxMintLidoBps * 1e14;
        console.log("Lido Pool max LTV:", lidoLTV);

        uint256 effectiveLTV = (lidoLTV * ltv_target) / 1e18;
        console.log("Effective system LTV: %d", effectiveLTV);

        uint256 maxLeverage = (1e18 * 1e18) / (1e18 - effectiveLTV);
        console.log("Max leverage: %d", maxLeverage);

        uint256 maxBorrowAmount = (msg.value * maxLeverage) / 1e18;
        console.log("Max borrow amount: %d", maxBorrowAmount);

        // 5. Cap the borrow amount
        if (targetBorrowAmount > maxBorrowAmount) {
            console.log("Capping target borrow from", targetBorrowAmount, "to", maxBorrowAmount);
            targetBorrowAmount = maxBorrowAmount;
        }
        console.log("Final borrow amount:", targetBorrowAmount);

        // Calculate how much wstETH we can actually mint from the borrowed funds
        // We need to account for minting capacity which is limited by reserve ratios
        // After depositing targetBorrowAmount ETH, check how much capacity we'll have
        uint256 additionalMintingCapacityShares = POOL_.remainingMintingCapacitySharesOf(
            address(callForwarder),
            targetBorrowAmount
        );
        uint256 additionalMintingCapacitySteth = STETH.getPooledEthByShares(additionalMintingCapacityShares);

        console.log("Additional minting capacity from borrow (shares):", additionalMintingCapacityShares);
        console.log("Additional minting capacity from borrow (stETH):", additionalMintingCapacitySteth);

        // The actual wstETH we can mint is the minimum of what we want and what's available
        uint256 additionalWstethFromBorrow = additionalMintingCapacitySteth < targetBorrowAmount
            ? additionalMintingCapacitySteth
            : targetBorrowAmount;

        // Calculate the final amount of collateral we'll actually have
        uint256 finalCollateralAmount = initialWstEth + additionalWstethFromBorrow;

        console.log("Initial wstETH:", initialWstEth);
        console.log("Target borrow amount:", targetBorrowAmount);
        console.log("Additional wstETH from borrow:", additionalWstethFromBorrow);
        console.log("Final collateral amount:", finalCollateralAmount);

        // Set up callback context
        _callbackContext = CallbackContext({
            callBackFrom: address(callForwarder),
            borrowAmount: targetBorrowAmount,
            callbackType: MorphoCallback.OnMorphoSupplyCollateral
        });

        // Authorize the strategy to manage the callForwarder's positions in Morpho
        // This allows the strategy to borrow on behalf of the callForwarder in the callback
        callForwarder.doCall(
            address(MORPHO),
            abi.encodeWithSignature("setAuthorization(address,bool)", address(this), true)
        );

        // Approve the final collateral amount (Morpho will pull it after the callback)
        callForwarder.doCall(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.approve.selector, address(MORPHO), finalCollateralAmount)
        );

        // Supply the FINAL collateral amount to Morpho
        // The callback will borrow funds and convert them to collateral
        // After callback returns, Morpho will pull the collateral from callForwarder
        callForwarder.doCall(
            address(MORPHO),
            abi.encodeCall(
                MORPHO.supplyCollateral,
                (
                    getMarketParams(),
                    finalCollateralAmount, // Total collateral including what we'll create in callback
                    address(callForwarder),
                    abi.encode(
                        SupplyCollateralData({
                            marketParams: marketParams,
                            loanAmount: targetBorrowAmount,
                            loanOwner: address(callForwarder)
                        })
                    )
                )
            )
        );

        console.log("Leverage loop completed");

        // Clear callback context
        delete _callbackContext;

        // Get final position for event emission
        Position memory position = MORPHO.position(MARKET_ID, address(callForwarder));

        // Calculate actual leverage
        // Leverage = (CollateralValue) / (CollateralValue - DebtValue)
        // But simpler: Leverage = Collateral / InitialCollateral (if we assume price constant for a moment)
        // Or better: Leverage = TotalCollateral * Price / (TotalCollateral * Price - Debt)
        // For the event, we can just emit the raw values or a simple ratio
        uint256 actualLeverageBp = 0;
        if (msg.value > 0) {
            actualLeverageBp = (position.collateral * 10000) / initialWstEth;
        }

        emit LoopExecuted(msg.sender, msg.value, position.collateral, position.borrowShares, actualLeverageBp);
    }

    // =================================================================================
    // MORPHO CALLBACKS - ATOMIC LEVERAGE MAGIC
    // =================================================================================

    /**
     * @notice Morpho callback executed during supply
     * @dev Called BEFORE the supply is finalized
     */
    function onMorphoSupply(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(MORPHO)) revert UnauthorizedCallback();
        // Not used in current implementation
    }

    function onMorphoSupplyCollateral(uint256 amount, bytes calldata data) external {
        console.log("=== onMorphoSupplyCollateral callback ===");
        console.log("Amount (total collateral to supply):", amount);

        // Verify that the callback is currently allowed
        CallbackContext memory ctx = _callbackContext;
        if (ctx.callBackFrom == address(0)) revert NoActiveContext();
        if (ctx.callBackFrom != msg.sender) revert UnauthorizedCallback();
        if (ctx.callbackType != MorphoCallback.OnMorphoSupplyCollateral) revert InvalidMorphoCallback();

        // ctx.callBackFrom is the callForwarder address
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(ctx.callBackFrom);

        console.log("CallForwarder wstETH balance before borrow:", WSTETH.balanceOf(address(callForwarder)));

        // Step 1: Borrow WETH from Morpho (borrowed funds sent to this strategy contract)
        SupplyCollateralData memory decoded = abi.decode(data, (SupplyCollateralData));
        (uint256 assetsBorrowed, ) = MORPHO.borrow(
            decoded.marketParams,
            decoded.loanAmount,
            0,
            decoded.loanOwner, // Borrow position is owned by the callForwarder
            address(this) // WETH is sent to this strategy contract
        );

        console.log("Borrowed WETH:", assetsBorrowed);

        // Step 2: Convert borrowed WETH → ETH → stETH → wstETH
        // Unwrap WETH to ETH
        WETH.withdraw(assetsBorrowed);
        uint256 ethReceived = address(this).balance; // TODO: this is not safe, check balance before and after.

        console.log("Unwrapped to ETH:", ethReceived);

        // Deposit ETH to pool to get stvETH for the callForwarder
        POOL_.depositETH{value: ethReceived}(address(callForwarder), address(0));

        console.log("Deposited ETH to pool, got stvETH for callForwarder");

        // Check available minting capacity for the callForwarder (in stETH shares)
        // Pass 0 for ethToFund since we already deposited
        uint256 mintingCapacityShares = POOL_.remainingMintingCapacitySharesOf(address(callForwarder), 0);
        console.log("Available minting capacity (shares):", mintingCapacityShares);

        // Convert shares to stETH amount
        uint256 mintingCapacitySteth = STETH.getPooledEthByShares(mintingCapacityShares);
        console.log("Available minting capacity (stETH):", mintingCapacitySteth);

        // Mint only what's available (might be less than ethReceived due to reserve ratios)
        uint256 amountToMint = mintingCapacitySteth < ethReceived ? mintingCapacitySteth : ethReceived;
        console.log("Amount to mint:", amountToMint);

        if (amountToMint > 0) {
            uint256 wstethBefore = WSTETH.balanceOf(address(callForwarder));
            callForwarder.doCall(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, amountToMint));
            uint256 wstethAfter = WSTETH.balanceOf(address(callForwarder));
            uint256 newWstethCreated = wstethAfter - wstethBefore;

            console.log("wstETH balance before mint:", wstethBefore);
            console.log("wstETH balance after mint:", wstethAfter);
            console.log("New wstETH created:", newWstethCreated);
        } else {
            console.log("No minting capacity available, skipping wstETH mint");
        }

        // Step 3: Now callForwarder should have enough wstETH (initial + newly created)
        // Morpho will pull `amount` wstETH from callForwarder after this callback returns
        uint256 finalWstethBalance = WSTETH.balanceOf(address(callForwarder));
        console.log("Final wstETH balance:", finalWstethBalance);
        console.log("Callback complete. Morpho will now pull", amount, "wstETH from callForwarder");

        if (finalWstethBalance < amount) {
            console.log("WARNING: Not enough wstETH! Have", finalWstethBalance, "but need", amount);
        }
    }

    /**
     * @notice Morpho callback executed during repay
     * @dev Called BEFORE Morpho pulls the repayment amount
     * @dev This allows us to atomically:
     *      1. Withdraw all wstETH collateral from Morpho
     *      2. Swap wstETH -> WETH via DEX
     *      3. Approve WETH to Morpho for repayment
     *      4. Return to Morpho which will pull the WETH
     * @param repaidAssets The amount of WETH that needs to be repaid
     * @param data Encoded RepayCallbackData containing slippage and forwarder info
     */
    function onMorphoRepay(uint256 repaidAssets, bytes calldata data) external {
        console.log("=== onMorphoRepay callback ===");
        console.log("Repaid assets (WETH needed):", repaidAssets);

        // 1. Validate caller is Morpho
        if (msg.sender != address(MORPHO)) revert UnauthorizedCallback();

        // 2. Validate callback context
        CallbackContext memory ctx = _callbackContext;
        if (ctx.callBackFrom == address(0)) revert NoActiveContext();
        if (ctx.callbackType != MorphoCallback.OnMorphoRepay) revert InvalidMorphoCallback();

        // 3. Decode callback data
        RepayCallbackData memory cbData = abi.decode(data, (RepayCallbackData));
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(cbData.callForwarder);

        // 4. Get current collateral amount and withdraw ALL from Morpho
        Position memory pos = MORPHO.position(MARKET_ID, cbData.callForwarder);
        uint256 collateralAmount = pos.collateral;
        console.log("Collateral to withdraw:", collateralAmount);

        if (collateralAmount > 0) {
            // Withdraw collateral to strategy contract (not callForwarder)
            // Strategy is authorized to act on behalf of callForwarder
            MORPHO.withdrawCollateral(
                getMarketParams(),
                collateralAmount,
                cbData.callForwarder,
                address(this) // Receive wstETH here for swapping
            );
            console.log("Withdrew collateral to strategy");
        }

        // 5. Calculate max wstETH to spend with slippage
        // repaidAssets = exact WETH needed
        uint256 maxWstethToSpend = (repaidAssets * (10000 + cbData.slippageBps)) / 10000;
        console.log("Max wstETH to spend (with slippage):", maxWstethToSpend);

        // 6. Approve wstETH to DEX router
        WSTETH.approve(address(DEX_ROUTER), maxWstethToSpend);

        // 7. Execute swap: wstETH -> exact WETH
        uint256 wstethUsed = DEX_ROUTER.buy(
            address(WSTETH),
            address(WETH),
            repaidAssets, // exact WETH needed
            maxWstethToSpend // max wstETH to spend
        );
        console.log("wstETH used for swap:", wstethUsed);

        // 8. Return unused wstETH to call forwarder
        uint256 remainingWsteth = WSTETH.balanceOf(address(this));
        console.log("Remaining wstETH after swap:", remainingWsteth);
        if (remainingWsteth > 0) {
            WSTETH.transfer(cbData.callForwarder, remainingWsteth);
            console.log("Transferred remaining wstETH to callForwarder");
        }

        // 9. Approve WETH to Morpho for repayment
        WETH.approve(address(MORPHO), repaidAssets);
        console.log("Approved WETH to Morpho for repayment");

        // Morpho will pull the WETH after this callback returns
        console.log("=== onMorphoRepay callback complete ===");
    }

    // =================================================================================
    // EXIT STRATEGY (DELEVERAGE)
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     * @notice Requests a full exit from the leveraged position
     * @dev Uses Morpho's repay callback to atomically:
     *      1. Repay all debt
     *      2. Withdraw all collateral
     *      3. Swap wstETH -> WETH for debt repayment
     *      4. Unwrap remaining wstETH -> stETH
     *      5. Request pool withdrawal
     * @param _wsteth Ignored for full exit (always exits entire position)
     * @param _params Encoded LoopExitParams with slippageBps
     * @return requestId The withdrawal request ID
     */
    function requestExitByWsteth(uint256 _wsteth, bytes calldata _params) external returns (bytes32 requestId) {
        console.log("=== requestExitByWsteth ===");

        LoopExitParams memory exitParams = abi.decode(_params, (LoopExitParams));
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        // 1. Get current Morpho position
        Position memory pos = MORPHO.position(MARKET_ID, address(callForwarder));
        console.log("Current collateral:", pos.collateral);
        console.log("Current borrow shares:", pos.borrowShares);

        if (pos.collateral == 0 && pos.borrowShares == 0) {
            revert InsufficientCollateral();
        }

        // 2. Setup callback context
        _callbackContext = CallbackContext({
            callBackFrom: address(callForwarder),
            borrowAmount: 0, // not used for repay
            callbackType: MorphoCallback.OnMorphoRepay
        });

        // 3. Prepare callback data
        RepayCallbackData memory cbData = RepayCallbackData({
            slippageBps: exitParams.slippageBps,
            callForwarder: address(callForwarder)
        });

        // 4. Execute repay with callback (repays ALL debt using shares)
        // The callback will withdraw collateral, swap to WETH, and approve for repayment
        if (pos.borrowShares > 0) {
            console.log("Calling Morpho.repay with callback");
            callForwarder.doCall(
                address(MORPHO),
                abi.encodeCall(
                    MORPHO.repay,
                    (
                        getMarketParams(),
                        0, // assets = 0 means use shares
                        pos.borrowShares, // repay all borrow shares
                        address(callForwarder),
                        abi.encode(cbData)
                    )
                )
            );
        }

        // Clear callback context
        delete _callbackContext;

        // 5. After repay: unwrap remaining wstETH -> stETH
        uint256 remainingWsteth = WSTETH.balanceOf(address(callForwarder));
        console.log("Remaining wstETH after exit:", remainingWsteth);

        if (remainingWsteth > 0) {
            callForwarder.doCall(
                address(WSTETH),
                abi.encodeWithSelector(WSTETH.unwrap.selector, remainingWsteth)
            );
            console.log("Unwrapped remaining wstETH to stETH");
        }

        // 6. Request pool withdrawal
        requestId = _requestPoolWithdrawal(msg.sender, callForwarder);

        emit ExitRequested(msg.sender, requestId, pos.collateral, pos.borrowShares);
        emit StrategyExitRequested(msg.sender, requestId, _wsteth, _params);

        console.log("=== requestExitByWsteth complete ===");
    }

    /**
     * @notice Requests withdrawal from the pool after position exit
     * @param _user The user requesting withdrawal
     * @param _callForwarder The user's call forwarder
     * @return requestId The withdrawal request ID as bytes32
     */
    function _requestPoolWithdrawal(
        address _user,
        IStrategyCallForwarder _callForwarder
    ) internal returns (bytes32 requestId) {
        // 1. Get stv balance
        uint256 stvBalance = POOL_.balanceOf(address(_callForwarder));
        console.log("STV balance for withdrawal:", stvBalance);

        // 2. Get minted stETH shares that need rebalancing
        uint256 mintedShares = POOL_.mintedStethSharesOf(address(_callForwarder));
        console.log("Minted stETH shares to rebalance:", mintedShares);

        if (stvBalance == 0) {
            // Nothing to withdraw
            return bytes32(0);
        }

        // 3. Request withdrawal with rebalancing
        // This handles: burning stv, rebalancing stETH liability
        bytes memory data = _callForwarder.doCall(
            address(POOL_.WITHDRAWAL_QUEUE()),
            abi.encodeWithSelector(
                WithdrawalQueue.requestWithdrawal.selector,
                _user, // recipient
                stvBalance, // stv to withdraw
                mintedShares // stETH shares to rebalance
            )
        );

        uint256 poolRequestId = abi.decode(data, (uint256));
        requestId = bytes32(poolRequestId);
        console.log("Pool withdrawal request ID:", poolRequestId);
    }

    // TODO: Implement deleverage logic here.
    /**
     * @inheritdoc IStrategy
     */
    function finalizeRequestExit(bytes32 _requestId) external pure {}

    // =================================================================================
    // HELPER VIEWS
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function mintedStethSharesOf(address _user) external view returns (uint256) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        return POOL_.mintedStethSharesOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
     */
    function remainingMintingCapacitySharesOf(address _user, uint256 _ethToFund) external view returns (uint256) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        return POOL_.remainingMintingCapacitySharesOf(address(callForwarder), _ethToFund);
    }

    /**
     * @inheritdoc IStrategy
     */
    function wstethOf(address _user) external view returns (uint256) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        return WSTETH.balanceOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
     */
    function stvOf(address _user) external view returns (uint256) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        return POOL_.balanceOf(address(callForwarder));
    }

    /**
     * @notice Returns the Morpho position details for a user
     * @param _user The user address
     * @return supplyShares The amount of supply shares
     * @return borrowShares The amount of borrow shares
     * @return collateral The amount of wstETH collateral
     */
    function morphoPositionOf(
        address _user
    ) external view returns (uint256 supplyShares, uint256 borrowShares, uint256 collateral) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        Position memory position = MORPHO.position(MARKET_ID, address(callForwarder));
        supplyShares = position.supplyShares;
        borrowShares = position.borrowShares;
        collateral = position.collateral;
    }

    /**
     * @notice Calculates the current leverage ratio for a user
     * @param _user The user address
     * @return leverageBp The leverage in basis points (10000 = 1x)
     * @dev This is a simplified calculation and may not be fully accurate
     */
    function currentLeverageOf(address _user) external view returns (uint256 leverageBp) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        Position memory position = MORPHO.position(MARKET_ID, address(callForwarder));

        // For now, return a simple ratio
        // TODO: Implement proper leverage calculation based on initial deposit tracking
        if (position.collateral == 0) return 10000;

        leverageBp = 10000; // Placeholder
    }

    // =================================================================================
    // POOL OPERATIONS
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function requestWithdrawalFromPool(
        address _recipient,
        uint256 _stvToWithdraw,
        uint256 _stethSharesToRebalance
    ) external returns (uint256 requestId) {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        bytes memory data = callForwarder.doCall(
            address(POOL_.WITHDRAWAL_QUEUE()),
            abi.encodeWithSelector(
                WithdrawalQueue.requestWithdrawal.selector,
                _recipient,
                _stvToWithdraw,
                _stethSharesToRebalance
            )
        );

        requestId = abi.decode(data, (uint256));
    }

    /**
     * @inheritdoc IStrategy
     */
    function burnWsteth(uint256 _wstethToBurn) external {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        callForwarder.doCall(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), _wstethToBurn)
        );

        callForwarder.doCall(address(POOL_), abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
    }

    // =================================================================================
    // PAUSE/RESUME
    // =================================================================================

    /**
     * @notice Pause supply operations
     */
    function pauseSupply() external {
        _checkRole(SUPPLY_PAUSE_ROLE, msg.sender);
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Resume supply operations
     */
    function resumeSupply() external {
        _checkRole(SUPPLY_RESUME_ROLE, msg.sender);
        _resumeFeature(SUPPLY_FEATURE);
    }

    // =================================================================================
    // RECOVERY
    // =================================================================================

    /**
     * @notice Recovers ERC20 tokens from the call forwarder
     * @param _token The token to recover
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to recover
     */
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);
        callForwarder.doCall(_token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }
}
