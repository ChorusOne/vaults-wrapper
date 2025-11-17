// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStrategy} from "src/interfaces/IStrategy.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IWstETH} from "src/interfaces/core/IWstETH.sol";
import {IStETH} from "src/interfaces/core/IStETH.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {StrategyCallForwarderRegistry} from "src/strategy/StrategyCallForwarderRegistry.sol";
import {FeaturePausable} from "src/utils/FeaturePausable.sol";

import {IMorpho, MarketParams, Id, Position} from "src/interfaces/morpho/IMorpho.sol";
import {IMorphoRepayCallback, IMorphoSupplyCallback} from "src/interfaces/morpho/IMorphoCallbacks.sol";
import {IWETH} from "src/interfaces/erc20/IWETH.sol";

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

    // ACL
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    struct LoopSupplyParams {
        uint256 targetLeverageBp; // Target leverage (10000-30000 = 1x-3x)
    }

    struct LoopExitParams {
        uint256 collateralToWithdraw; // Amount of wstETH collateral to withdraw
    }

    // Temporary storage for callback context
    struct CallbackContext {
        address callForwarder;
        uint256 borrowAmount;
        bool isRepayCallback;
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
    error ZeroArgument(string name);

    constructor(
        bytes32 _strategyId,
        address _strategyCallForwarderImpl,
        address _pool,
        address _morpho,
        address _weth,
        MarketParams memory _marketParams,
        uint256 _maxLeverageBp
    ) StrategyCallForwarderRegistry(_strategyId, _strategyCallForwarderImpl) {
        if (_pool == address(0)) revert ZeroArgument("_pool");
        if (_morpho == address(0)) revert ZeroArgument("_morpho");
        if (_weth == address(0)) revert ZeroArgument("_weth");
        if (_marketParams.loanToken != _weth) revert ZeroArgument("loan token must be WETH");

        POOL_ = StvStETHPool(payable(_pool));
        WSTETH = IWstETH(POOL_.WSTETH());
        STETH = IStETH(POOL_.STETH());
        MORPHO = IMorpho(_morpho);
        WETH = IWETH(_weth);

        // Store market params as individual immutables
        MARKET_LOAN_TOKEN = _marketParams.loanToken;
        MARKET_COLLATERAL_TOKEN = _marketParams.collateralToken;
        MARKET_ORACLE = _marketParams.oracle;
        MARKET_IRM = _marketParams.irm;
        MARKET_LLTV = _marketParams.lltv;
        MARKET_ID = Id.wrap(keccak256(abi.encode(_marketParams)));
        MAX_LEVERAGE_BP = _maxLeverageBp;

        require(_marketParams.collateralToken == address(WSTETH), "Collateral must be wstETH");

        _disableInitializers();
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
        uint256 _wstethToMint,
        bytes calldata _params
    ) external payable returns (uint256 stv) {
        _checkFeatureNotPaused(SUPPLY_FEATURE);

        LoopSupplyParams memory params = abi.decode(_params, (LoopSupplyParams));
        if (params.targetLeverageBp < 10000) revert InvalidLeverage();
        if (params.targetLeverageBp > MAX_LEVERAGE_BP) revert InvalidLeverage();

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        // 1. Deposit ETH to pool and get stvETH
        if (msg.value > 0) {
            stv = POOL_.depositETH{value: msg.value}(address(callForwarder), _referral);
        }

        // 2. Mint initial wstETH from pool
        callForwarder.doCall(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, _wstethToMint));

        // 3. Execute atomic leverage loop via Morpho callback
        _executeAtomicLoop(callForwarder, _wstethToMint, params);

        emit StrategySupplied(msg.sender, _referral, msg.value, stv, _wstethToMint, _params);
    }

    function _executeAtomicLoop(
        IStrategyCallForwarder callForwarder,
        uint256 initialWsteth,
        LoopSupplyParams memory params
    ) internal {
        // Calculate how much WETH to borrow based on target leverage
        // Formula: borrowAmount = initialValue * (targetLeverage - 1)
        // Example: For 2x leverage (20000 bp), borrow = initialValue * 1
        uint256 initialValueInEth = WSTETH.getStETHByWstETH(initialWsteth);
        uint256 targetBorrowAmount = (initialValueInEth * (params.targetLeverageBp - 10000)) / 10000;

        // Apply safety factor based on LLTV to avoid immediate liquidation
        // Leave some buffer for interest accrual and price movements
        uint256 safetyFactorBp = 9500; // 95% of theoretical max
        targetBorrowAmount = (targetBorrowAmount * safetyFactorBp) / 10000;

        // Set up callback context for the borrow callback
        _callbackContext = CallbackContext({
            callForwarder: address(callForwarder),
            borrowAmount: targetBorrowAmount,
            isRepayCallback: false
        });

        // Approve wstETH to Morpho for collateral supply
        callForwarder.doCall(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.approve.selector, address(MORPHO), type(uint256).max)
        );

        // Supply initial wstETH as collateral
        callForwarder.doCall(
            address(MORPHO),
            abi.encodeCall(
                MORPHO.supplyCollateral,
                (getMarketParams(), initialWsteth, address(callForwarder), new bytes(0))
            )
        );

        // Execute atomic borrow with callback
        // The callback will: receive WETH → unwrap to ETH → stake for stETH → wrap to wstETH → supply collateral
        // By the time borrow() returns, the position will be properly collateralized
        callForwarder.doCall(
            address(MORPHO),
            abi.encodeCall(
                MORPHO.borrow,
                (getMarketParams(), targetBorrowAmount, 0, address(callForwarder), address(this))
            )
        );

        // Clear callback context
        delete _callbackContext;

        // Get final position for event emission
        Position memory position = MORPHO.position(MARKET_ID, address(callForwarder));

        uint256 actualLeverageBp = (position.collateral * 10000) / initialWsteth;

        emit LoopExecuted(msg.sender, initialWsteth, position.collateral, position.borrowShares, actualLeverageBp);
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

    /**
     * @notice Morpho callback executed during repay
     * @dev This is the KEY callback for atomic leveraged looping
     * @dev Morpho calls this AFTER sending borrowed WETH but BEFORE checking collateral
     * @dev This allows us to:
     *      1. Receive borrowed WETH
     *      2. Convert WETH → ETH → stETH → wstETH
     *      3. Supply wstETH as collateral
     *      4. Return to Morpho with position now properly collateralized
     */
    function onMorphoRepay(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(MORPHO)) revert UnauthorizedCallback();

        CallbackContext memory ctx = _callbackContext;
        if (ctx.callForwarder == address(0)) revert NoActiveContext();
        if (ctx.isRepayCallback) return; // Only process during leverage, not deleverage

        // At this point, we have received WETH from the borrow
        uint256 wethBalance = WETH.balanceOf(address(this));

        // 1. Unwrap WETH to ETH
        WETH.withdraw(wethBalance);

        // 2. Stake ETH with Lido to get stETH
        uint256 stethReceived = STETH.submit{value: wethBalance}(address(0));

        // 3. Approve and wrap stETH to wstETH
        STETH.approve(address(WSTETH), stethReceived);
        uint256 wstethReceived = WSTETH.wrap(stethReceived);

        // 4. Supply the new wstETH as additional collateral to Morpho
        // This happens on behalf of the user's call forwarder
        WSTETH.approve(address(MORPHO), wstethReceived);
        MORPHO.supplyCollateral(getMarketParams(), wstethReceived, ctx.callForwarder, new bytes(0));

        // Position is now properly collateralized, the borrow will succeed when we return
    }

    // =================================================================================
    // EXIT STRATEGY (DELEVERAGE)
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function requestExitByWsteth(uint256 _wstethAmount, bytes calldata _params) external returns (bytes32 requestId) {
        LoopExitParams memory params = abi.decode(_params, (LoopExitParams));
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msg.sender);

        // Get current Morpho position
        Position memory position = MORPHO.position(MARKET_ID, address(callForwarder));
        uint256 currentCollateral = position.collateral;
        uint256 borrowShares = position.borrowShares;

        // Determine how much collateral to withdraw
        uint256 collateralToWithdraw = params.collateralToWithdraw > 0
            ? Math.min(params.collateralToWithdraw, currentCollateral)
            : Math.min(_wstethAmount, currentCollateral);

        // Calculate proportional debt to repay to maintain health factor
        // For full exit: repay all debt and withdraw all collateral
        uint256 debtToRepay;
        if (collateralToWithdraw == currentCollateral) {
            // Full exit - repay all debt
            debtToRepay = type(uint256).max; // Will repay all shares
        } else {
            // Partial exit - calculate proportional repayment
            // Need to maintain safe LTV after withdrawal
            uint256 remainingCollateral = currentCollateral - collateralToWithdraw;
            uint256 remainingCollateralValue = WSTETH.getStETHByWstETH(remainingCollateral);
            uint256 maxSafeBorrow = (((remainingCollateralValue * MARKET_LLTV) / 1e18) * 9000) / 10000; // 90% of max

            // Convert current borrow shares to assets
            // TODO: Need to get actual borrow amount from Morpho market state
            debtToRepay = 0; // Calculate based on market state
        }

        // Execute deleverage
        _executeDeleverage(callForwarder, collateralToWithdraw, debtToRepay);

        requestId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _wstethAmount));

        emit ExitRequested(msg.sender, requestId, collateralToWithdraw, debtToRepay);
        emit StrategyExitRequested(msg.sender, requestId, _wstethAmount, _params);
    }

    function _executeDeleverage(
        IStrategyCallForwarder callForwarder,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal {
        // 1. Withdraw wstETH collateral from Morpho
        if (collateralAmount > 0) {
            callForwarder.doCall(
                address(MORPHO),
                abi.encodeCall(
                    MORPHO.withdrawCollateral,
                    (getMarketParams(), collateralAmount, address(callForwarder), address(callForwarder))
                )
            );
        }

        // 2. Convert wstETH to WETH for debt repayment
        if (debtAmount > 0) {
            // Unwrap wstETH → stETH
            bytes memory unwrapResult = callForwarder.doCall(
                address(WSTETH),
                abi.encodeWithSelector(WSTETH.unwrap.selector, collateralAmount)
            );
            uint256 stethAmount = abi.decode(unwrapResult, (uint256));

            // For immediate repayment, we need ETH
            // Option 1: Use Curve to swap stETH → ETH (most liquid)
            // Option 2: Request withdrawal from Lido (requires waiting)
            // For now, assume we swap via Curve or similar
            // uint256 ethReceived = _swapStethToEth(stethAmount);

            // 3. Wrap ETH to WETH
            // callForwarder.doCallWithValue(
            //     address(WETH),
            //     abi.encodeWithSelector(WETH.deposit.selector),
            //     ethReceived
            // );

            // 4. Approve and repay debt to Morpho
            callForwarder.doCall(
                address(WETH),
                abi.encodeWithSelector(WETH.approve.selector, address(MORPHO), type(uint256).max)
            );

            callForwarder.doCall(
                address(MORPHO),
                abi.encodeCall(MORPHO.repay, (getMarketParams(), 0, debtAmount, address(callForwarder), new bytes(0)))
            );
        }
    }

    /**
     * @inheritdoc IStrategy
     */
    function finalizeRequestExit(bytes32 _requestId) external pure {
        // Exits are synchronous in this implementation
        // No async finalization needed
        revert("Exits are synchronous");
    }

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
