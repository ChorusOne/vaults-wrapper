// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IMorpho, IMorphoBase, MarketParams, Id, Position, Market} from "./interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "./interfaces/IMorphoCallbacks.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Wrapper} from "./Wrapper.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

/// @title MorphoLoopedStrategy
/// @notice Leveraged staking strategy using Morpho Blue flash loans
/// @dev Implements IStrategy and IMorphoFlashLoanCallback for atomic leverage operations
///
/// TODO PRODUCTION: Critical items before mainnet deployment
/// 1. ACCESS CONTROL: Add OpenZeppelin Ownable/AccessControl to admin functions
/// 2. DEX INTEGRATION: Implement stETH<->WETH swapping for exit flow (Curve, Uniswap)
/// 3. ORACLE INTEGRATION: Use Morpho's oracle for accurate price feeds in health checks
/// 4. SLIPPAGE PROTECTION: Add min/max amount checks on all swaps and conversions
/// 5. REENTRANCY GUARDS: Add ReentrancyGuard to all external functions
/// 6. PAUSE MECHANISM: Add circuit breaker for emergency situations
/// 7. COMPREHENSIVE TESTING: Unit tests, integration tests, fuzzing, formal verification
/// 8. GAS OPTIMIZATION: Optimize storage layout and function calls
/// 9. LIQUIDATION PROTECTION: Add monitoring and keeper system for position health
/// 10. AUDIT: Complete security audit by reputable firm
contract MorphoLoopedStrategy is IStrategy, IMorphoFlashLoanCallback {
    /* CONSTANTS */
    uint256 private constant WAD = 1e18;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint256 private constant BASIS_POINTS = 10000;

    // TODO PRODUCTION: Add slippage tolerance constants
    // uint256 private constant MAX_SLIPPAGE_BPS = 50; // 0.5%
    // uint256 private constant STALE_PRICE_THRESHOLD = 1 hours;

    /* IMMUTABLES */
    IMorpho public immutable MORPHO;
    IERC20 public immutable STV_TOKEN;
    IERC20 public immutable STETH;
    IWstETH public immutable WSTETH;
    IERC20 public immutable LOAN_TOKEN; // WETH or similar
    Wrapper public immutable WRAPPER;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;
    MarketParams public immutable MARKET_PARAMS;
    Id public immutable MARKET_ID;

    /* STATE */
    /// @notice Target leverage ratio in basis points (e.g., 20000 = 2x leverage)
    uint256 public targetLeverageBps;

    /// @notice Minimum health factor to maintain (in WAD, e.g., 1.2e18 = 1.2)
    uint256 public minHealthFactor;

    /// @notice User positions mapping
    mapping(address => UserPosition) public userPositions;

    /// @notice Callback context for flash loans
    CallbackContext private _callbackContext;

    /* STRUCTS */
    struct UserPosition {
        address user;
        uint256 collateralAmount; // wstETH collateral in Morpho
        uint256 borrowedAmount; // Borrowed loan token amount
        uint256 initialStvShares; // Initial stv token shares deposited
        bool isExiting;
        uint256 timestamp;
        // TODO PRODUCTION: Add fields for better position tracking
        // uint256 entryPrice; // Entry price for PnL calculations
        // uint256 lastHealthCheck; // Last time position health was verified
        // uint256 accruedRewards; // Track staking rewards
    }

    struct CallbackContext {
        address user;
        uint256 stvTokenShares;
        bool isDeposit; // true for deposit, false for exit
    }

    /* EVENTS */
    event StrategyExecuted(
        address indexed user,
        uint256 stvTokenShares,
        uint256 collateralAmount,
        uint256 borrowedAmount,
        uint256 leverage
    );

    event PositionClosed(
        address indexed user,
        uint256 collateralReturned,
        uint256 debtRepaid
    );

    event LeverageUpdated(uint256 newLeverageBps);
    event MinHealthFactorUpdated(uint256 newMinHealthFactor);
    event DebugLog(string message, uint256 value1, uint256 value2);

    /* ERRORS */
    error UnauthorizedCallback();
    error InvalidLeverage();
    error InsufficientCollateral();
    error PositionNotFound();
    error PositionNotExiting();
    error UnhealthyPosition();
    error InvalidMarket();

    // TODO PRODUCTION: Add more specific errors
    // error Paused();
    // error Unauthorized();
    // error SlippageExceeded();
    // error StalePrice();
    // error InvalidAddress();
    // error PositionLiquidatable();
    // error InsufficientLiquidity();

    /* CONSTRUCTOR */
    constructor(
        address _morpho,
        address _stETH,
        address _wstETH,
        address _wrapper,
        address _loanToken,
        MarketParams memory _marketParams,
        uint256 _targetLeverageBps,
        uint256 _minHealthFactor
    ) {
        require(_morpho != address(0), "Invalid Morpho address");
        require(
            _targetLeverageBps >= BASIS_POINTS && _targetLeverageBps <= 30000,
            "Invalid leverage"
        );
        require(_minHealthFactor >= WAD, "Invalid health factor");

        MORPHO = IMorpho(_morpho);
        STETH = IERC20(_stETH);
        WSTETH = IWstETH(_wstETH);
        LOAN_TOKEN = IERC20(_loanToken);
        WRAPPER = Wrapper(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);
        VAULT_HUB = WRAPPER.VAULT_HUB();
        STAKING_VAULT = WRAPPER.STAKING_VAULT();

        MARKET_PARAMS = _marketParams;
        MARKET_ID = _computeMarketId(_marketParams);

        // Verify market exists
        Market memory marketState = MORPHO.market(MARKET_ID);
        if (marketState.lastUpdate == 0) {
            revert InvalidMarket();
        }

        targetLeverageBps = _targetLeverageBps;
        minHealthFactor = _minHealthFactor;

        // Approve tokens for Morpho operations
        STETH.approve(_wstETH, type(uint256).max);
        WSTETH.approve(_morpho, type(uint256).max);
        LOAN_TOKEN.approve(_morpho, type(uint256).max);

        // TODO PRODUCTION: Initialize owner and additional state
        // owner = msg.sender;
        // paused = false;

        // TODO PRODUCTION: Verify all addresses are valid contracts
        // require(_stETH.code.length > 0, "Invalid stETH");
        // require(_wstETH.code.length > 0, "Invalid wstETH");

        // TODO PRODUCTION: Verify market parameters
        // require(_marketParams.collateralToken == _wstETH, "Market collateral mismatch");
        // require(_marketParams.loanToken == _loanToken, "Market loan token mismatch");
        // require(_marketParams.lltv > 0 && _marketParams.lltv < WAD, "Invalid LLTV");

        emit LeverageUpdated(_targetLeverageBps);
        emit MinHealthFactorUpdated(_minHealthFactor);
    }

    /* EXTERNAL FUNCTIONS - IStrategy Implementation */

    /// @notice Execute leveraged staking strategy using flash loans
    /// @param user The user address
    /// @param stvTokenShares Amount of stv token shares to leverage
    function execute(address user, uint256 stvTokenShares) external override {
        // TODO PRODUCTION: Add reentrancy guard
        // TODO PRODUCTION: Add pause check: require(!paused, Paused());
        // TODO PRODUCTION: Add authorized caller check (only Escrow)
        require(stvTokenShares > 0, "Zero shares");

        // TODO PRODUCTION: Check if user already has an active position
        // require(!userPositions[user].isActive, "Position already exists");

        // TODO PRODUCTION: Validate user is not blacklisted/sanctioned

        // Transfer stv tokens from caller (Escrow)
        STV_TOKEN.transferFrom(msg.sender, address(this), stvTokenShares);

        // Calculate flash loan amount needed for target leverage
        // For 2x leverage: we need to borrow roughly equal to initial collateral value
        uint256 flashLoanAmount = _calculateFlashLoanAmount(stvTokenShares);

        // TODO PRODUCTION: Add flash loan amount validation
        // require(flashLoanAmount > 0 && flashLoanAmount < maxFlashLoanAmount, "Invalid flash loan");

        // Set callback context
        _callbackContext = CallbackContext({
            user: user,
            stvTokenShares: stvTokenShares,
            isDeposit: true
        });

        // Execute flash loan - callback will handle the leverage logic
        MORPHO.flashLoan(address(LOAN_TOKEN), flashLoanAmount, "");

        // Clear callback context
        delete _callbackContext;

        // Verify position health
        if (!_checkPositionHealth(user)) {
            revert UnhealthyPosition();
        }

        UserPosition memory position = userPositions[user];
        uint256 actualLeverage = (position.collateralAmount * BASIS_POINTS) /
            _getCollateralValueFromStvShares(stvTokenShares);

        emit StrategyExecuted(
            user,
            stvTokenShares,
            position.collateralAmount,
            position.borrowedAmount,
            actualLeverage
        );
    }

    /// @notice Initiate position exit
    /// @param user User address
    /// @param assets Amount of assets (unused in this implementation)
    function initiateExit(address user, uint256 assets) external override {
        UserPosition storage position = userPositions[user];
        require(position.user == user, "Position not found");
        position.isExiting = true;
    }

    /// @notice Finalize exit and close leveraged position
    /// @param user User address
    /// @return assets Amount of assets returned
    function finalizeExit(
        address user
    ) external override returns (uint256 assets) {
        // TODO PRODUCTION: Add reentrancy guard
        // TODO PRODUCTION: Add authorized caller check
        UserPosition storage position = userPositions[user];
        require(position.isExiting, "Not exiting");
        require(position.user == user, "Position not found");

        uint256 debtToRepay = position.borrowedAmount;
        uint256 collateralToWithdraw = position.collateralAmount;

        // TODO PRODUCTION: Check if position can be safely exited
        // - Verify no pending liquidation
        // - Check withdrawal queue availability
        // - Validate minimum output amounts

        // Set callback context for exit
        _callbackContext = CallbackContext({
            user: user,
            stvTokenShares: position.initialStvShares,
            isDeposit: false
        });

        // Flash loan to repay debt and unwind position
        MORPHO.flashLoan(address(LOAN_TOKEN), debtToRepay, "");

        // Clear callback context
        delete _callbackContext;

        emit PositionClosed(user, collateralToWithdraw, debtToRepay);

        // TODO PRODUCTION: Calculate actual return value considering:
        // - Accrued staking rewards
        // - Interest paid
        // - Fees
        // - Price impact from unwinding
        // Return initial shares (simplified - in production, calculate actual value)
        assets = position.initialStvShares;

        // Clean up position
        delete userPositions[user];

        return assets;
    }

    /// @notice Get borrow details for a user
    /// @return borrowAssets Borrowed asset amount
    /// @return userAssets User's own assets
    /// @return totalAssets Total assets in position
    function getBorrowDetails()
        external
        view
        override
        returns (uint256 borrowAssets, uint256 userAssets, uint256 totalAssets)
    {
        UserPosition storage position = userPositions[msg.sender];

        // Convert wstETH collateral to stETH value
        uint256 collateralValue = WSTETH.getStETHByWstETH(
            position.collateralAmount
        );

        return (
            position.borrowedAmount,
            collateralValue - position.borrowedAmount, // Net user assets
            collateralValue // Total position value
        );
    }

    /// @notice Check if user is exiting
    /// @return True if user position is in exit state
    function isExiting() external view override returns (bool) {
        return userPositions[msg.sender].isExiting;
    }

    /* MORPHO CALLBACK */

    /// @notice Callback function for Morpho flash loans
    /// @param assets Amount of assets flash loaned
    /// @param data Additional data (unused)
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(MORPHO), "Unauthorized callback");

        // TODO PRODUCTION: Add reentrancy protection
        // TODO PRODUCTION: Verify callback context is valid
        // require(_callbackContext.user != address(0), "Invalid callback context");

        CallbackContext memory ctx = _callbackContext;

        if (ctx.isDeposit) {
            _handleDepositCallback(ctx.user, ctx.stvTokenShares, assets);
        } else {
            _handleExitCallback(ctx.user, assets);
        }

        // TODO PRODUCTION: Verify all tokens were properly transferred
        // TODO PRODUCTION: Emit detailed callback execution event
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Compute market ID from market parameters
    /// @param marketParams The market parameters
    /// @return The market ID
    function _computeMarketId(
        MarketParams memory marketParams
    ) internal pure returns (Id) {
        return
            Id.wrap(
                keccak256(
                    abi.encode(
                        marketParams.loanToken,
                        marketParams.collateralToken,
                        marketParams.oracle,
                        marketParams.irm,
                        marketParams.lltv
                    )
                )
            );
    }

    /// @notice Handle flash loan callback for deposit (leveraging up)
    /// @param user User address
    /// @param stvTokenShares Initial stv token shares
    /// @param flashLoanAmount Flash loan amount received
    function _handleDepositCallback(
        address user,
        uint256 stvTokenShares,
        uint256 flashLoanAmount
    ) internal {
        // TODO PRODUCTION: Add try-catch blocks for each step with proper error handling
        // TODO PRODUCTION: Track gas usage and optimize

        // Step 1: Mint stETH from stv shares
        uint256 stETHAmount = _mintStETHFromStvShares(stvTokenShares);

        // TODO PRODUCTION: Validate stETH amount is reasonable
        // require(stETHAmount >= minExpectedStETH, "Insufficient stETH minted");

        emit DebugLog("stETH minted", stETHAmount, 0);

        // Step 2: Wrap stETH to wstETH (Morpho requires non-rebasing collateral)
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);

        // TODO PRODUCTION: Add slippage check on wrapping
        // uint256 expectedWstETH = WSTETH.getWstETHByStETH(stETHAmount);
        // require(wstETHAmount >= expectedWstETH * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS, SlippageExceeded());

        emit DebugLog("wstETH wrapped", wstETHAmount, 0);

        // Step 3: Supply wstETH as collateral to Morpho
        MORPHO.supplyCollateral(MARKET_PARAMS, wstETHAmount, address(this), "");

        // TODO PRODUCTION: Verify collateral was successfully supplied
        // Position memory pos = MORPHO.position(MARKET_ID, address(this));
        // require(pos.collateral >= wstETHAmount, "Collateral supply failed");

        emit DebugLog("Collateral supplied", wstETHAmount, 0);

        // Step 4: Borrow loan tokens against the collateral
        // Borrow the flash loan amount so we can repay it
        (uint256 assetsBorrowed, ) = MORPHO.borrow(
            MARKET_PARAMS,
            flashLoanAmount,
            0, // shares (0 means use assets)
            address(this),
            address(this)
        );

        // TODO PRODUCTION: Validate borrowed amount matches expected
        // require(assetsBorrowed >= flashLoanAmount, "Insufficient borrow");

        emit DebugLog("Borrowed from Morpho", assetsBorrowed, 0);

        // Step 5: Repay flash loan (assets already transferred to this contract)
        // The flash loan will be automatically repaid when this callback completes
        // TODO PRODUCTION: Verify contract has enough balance to repay
        // require(LOAN_TOKEN.balanceOf(address(this)) >= flashLoanAmount, "Insufficient balance for repayment");

        // Step 6: Record user position
        userPositions[user] = UserPosition({
            user: user,
            collateralAmount: wstETHAmount,
            borrowedAmount: assetsBorrowed,
            initialStvShares: stvTokenShares,
            isExiting: false,
            timestamp: block.timestamp
        });

        // TODO PRODUCTION: Emit detailed position opened event with all parameters
    }

    /// @notice Handle flash loan callback for exit (deleveraging)
    /// @param user User address
    /// @param flashLoanAmount Flash loan amount for repaying debt
    function _handleExitCallback(
        address user,
        uint256 flashLoanAmount
    ) internal {
        UserPosition storage position = userPositions[user];

        // TODO PRODUCTION: Add comprehensive checks before unwinding
        // TODO PRODUCTION: Add try-catch for each step with fallback logic

        // Step 1: Repay Morpho debt
        MORPHO.repay(
            MARKET_PARAMS,
            flashLoanAmount,
            0, // shares (0 means use assets)
            address(this),
            ""
        );

        // TODO PRODUCTION: Verify debt was fully repaid
        // Position memory pos = MORPHO.position(MARKET_ID, address(this));
        // require(pos.borrowShares == 0 || pos.borrowShares < minDust, "Debt repayment incomplete");

        // Step 2: Withdraw wstETH collateral
        MORPHO.withdrawCollateral(
            MARKET_PARAMS,
            position.collateralAmount,
            address(this),
            address(this)
        );

        // TODO PRODUCTION: Verify collateral was withdrawn
        // require(WSTETH.balanceOf(address(this)) >= position.collateralAmount, "Collateral withdrawal failed");

        // Step 3: Unwrap wstETH to stETH
        uint256 stETHAmount = WSTETH.unwrap(position.collateralAmount);

        // TODO PRODUCTION: Add slippage check on unwrapping
        // uint256 expectedStETH = WSTETH.getStETHByWstETH(position.collateralAmount);
        // require(stETHAmount >= expectedStETH * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS, SlippageExceeded());

        // TODO PRODUCTION CRITICAL: Implement DEX swap for stETH -> WETH/loan token
        // Step 4: Swap stETH to loan token (WETH) to repay flash loan
        // Example using Curve stETH/ETH pool:
        // uint256 minOut = _calculateMinOutput(stETHAmount);
        // uint256 wethReceived = ICurvePool(CURVE_STETH_POOL).exchange(
        //     1, // stETH index
        //     0, // ETH index
        //     stETHAmount,
        //     minOut
        // );
        // IWETH(LOAN_TOKEN).deposit{value: wethReceived}();
        //
        // Alternative: Use Uniswap V3 router
        // ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        //     tokenIn: address(STETH),
        //     tokenOut: address(LOAN_TOKEN),
        //     fee: 500, // 0.05%
        //     recipient: address(this),
        //     deadline: block.timestamp,
        //     amountIn: stETHAmount,
        //     amountOutMinimum: minOut,
        //     sqrtPriceLimitX96: 0
        // });
        // uint256 amountOut = swapRouter.exactInputSingle(params);

        // TODO PRODUCTION: Verify we have enough to repay flash loan
        // require(LOAN_TOKEN.balanceOf(address(this)) >= flashLoanAmount, "Insufficient funds for flash loan repayment");

        // TODO PRODUCTION: Calculate and return any excess to user
        // uint256 excess = LOAN_TOKEN.balanceOf(address(this)) - flashLoanAmount;
        // if (excess > 0) {
        //     LOAN_TOKEN.transfer(user, excess);
        // }

        // Flash loan will be automatically repaid when callback completes
    }

    /// @notice Mint stETH from stv token shares via Escrow
    /// @param stvShares Amount of stv shares
    /// @return stETHAmount Amount of stETH minted
    function _mintStETHFromStvShares(
        uint256 stvShares
    ) internal returns (uint256 stETHAmount) {
        // TODO PRODUCTION: Review this minting logic with Lido team
        // TODO PRODUCTION: Verify this is the correct way to mint from STV shares
        // TODO PRODUCTION: Add checks for minting capacity limits

        // Approve Escrow to spend stv tokens
        address escrow = address(WRAPPER.ESCROW());
        STV_TOKEN.approve(escrow, stvShares);

        // Get stETH balance before
        uint256 stETHBefore = STETH.balanceOf(address(this));

        // Mint stETH through the Wrapper's Dashboard
        uint256 remainingCapacity = IDashboard(
            payable(address(WRAPPER.DASHBOARD()))
        ).remainingMintingCapacityShares(0);

        // TODO PRODUCTION: Validate remaining capacity
        // require(remainingCapacity >= expectedMintAmount, "Insufficient minting capacity");

        // TODO PRODUCTION: Use actual conversion rate instead of full capacity
        // uint256 sharesToMint = _convertStvSharesToStethShares(stvShares);
        // require(sharesToMint <= remainingCapacity, "Exceeds minting capacity");

        // Mint stETH shares
        IDashboard(payable(address(WRAPPER.DASHBOARD()))).mintShares(
            address(this),
            remainingCapacity
        );

        // Get stETH balance after
        uint256 stETHAfter = STETH.balanceOf(address(this));
        stETHAmount = stETHAfter - stETHBefore;

        require(stETHAmount > 0, "No stETH minted");

        // TODO PRODUCTION: Add maximum deviation check
        // uint256 expectedAmount = _getExpectedStETHFromStvShares(stvShares);
        // require(
        //     stETHAmount >= expectedAmount * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS &&
        //     stETHAmount <= expectedAmount * (BASIS_POINTS + MAX_SLIPPAGE_BPS) / BASIS_POINTS,
        //     "Mint amount out of bounds"
        // );

        return stETHAmount;
    }

    /// @notice Calculate flash loan amount needed for target leverage
    /// @param stvTokenShares Initial stv token shares
    /// @return Flash loan amount needed
    function _calculateFlashLoanAmount(
        uint256 stvTokenShares
    ) internal view returns (uint256) {
        // TODO PRODUCTION: Use accurate price feeds from Chainlink/Morpho oracle
        // TODO PRODUCTION: Account for price impact of large positions
        // TODO PRODUCTION: Add safety margin to prevent liquidation immediately after opening

        // Estimate collateral value from stv shares
        uint256 estimatedCollateralValue = _getCollateralValueFromStvShares(
            stvTokenShares
        );

        // For target leverage of 2x, we need to borrow ~50% of collateral value
        // leverage = totalCollateral / initialCollateral
        // For 2x: we double the collateral, so borrow = initialCollateral
        // Formula: borrowAmount = initialValue * (leverageRatio - 1)

        uint256 borrowMultiplier = targetLeverageBps - BASIS_POINTS; // e.g., 20000 - 10000 = 10000
        uint256 flashLoanAmount = (estimatedCollateralValue *
            borrowMultiplier) / BASIS_POINTS;

        // TODO PRODUCTION: Apply safety factor to prevent immediate liquidation
        // Account for:
        // - Oracle price deviation
        // - Market volatility buffer
        // - Gas costs for potential liquidation
        // uint256 safetyFactor = 9500; // 95% to leave 5% buffer
        // flashLoanAmount = (flashLoanAmount * safetyFactor) / BASIS_POINTS;

        // TODO PRODUCTION: Validate against market liquidity
        // require(flashLoanAmount <= getMaxBorrowFromMarket(), "Exceeds market liquidity");

        return flashLoanAmount;
    }

    /// @notice Estimate collateral value from stv shares
    /// @param stvShares Amount of stv shares
    /// @return Estimated value
    function _getCollateralValueFromStvShares(
        uint256 stvShares
    ) internal view returns (uint256) {
        // TODO PRODUCTION CRITICAL: Implement proper conversion logic
        // This needs to account for:
        // 1. STV shares -> ETH value (via totalAssets/totalSupply)
        // 2. stETH -> wstETH conversion rate
        // 3. wstETH -> WETH price (should be ~1:1 but check oracle)
        // 4. Any fees or slippage in the conversion process

        // Example implementation:
        // uint256 ethValue = WRAPPER.convertToAssets(stvShares);
        // uint256 stethAmount = ethValue; // Assuming 1:1 for stETH minting
        // uint256 wstethAmount = WSTETH.getWstETHByStETH(stethAmount);
        // uint256 wethValue = _getWethValueOfWsteth(wstethAmount);
        // return wethValue;

        // Simplified: assume 1:1 conversion for estimation
        // In production, use proper conversion rates
        return stvShares;
    }

    /// @notice Check position health
    /// @param user User address
    /// @return True if position is healthy
    function _checkPositionHealth(address user) internal view returns (bool) {
        UserPosition storage position = userPositions[user];

        if (position.collateralAmount == 0) {
            return true; // No position yet
        }

        // TODO PRODUCTION CRITICAL: Use Morpho's oracle for accurate price feeds
        // IOracle oracle = IOracle(MARKET_PARAMS.oracle);
        // uint256 collateralPrice = oracle.price();
        // TODO PRODUCTION: Check oracle freshness
        // require(block.timestamp - oracle.lastUpdate() < STALE_PRICE_THRESHOLD, StalePrice());

        // Get position from Morpho
        Position memory morphoPosition = MORPHO.position(
            MARKET_ID,
            address(this)
        );

        // TODO PRODUCTION: Validate Morpho position matches our records
        // This helps detect any discrepancies or external interactions

        // Calculate health factor
        // healthFactor = (collateral * price * lltv) / debt
        // Simplified check - in production, use oracle prices

        uint256 collateralValue = position.collateralAmount;
        uint256 debtValue = position.borrowedAmount;

        if (debtValue == 0) {
            return true;
        }

        // TODO PRODUCTION: Use proper price calculation
        // uint256 collateralValueInLoanToken = (collateralValue * collateralPrice) / ORACLE_PRICE_SCALE;
        // uint256 maxBorrow = (collateralValueInLoanToken * MARKET_PARAMS.lltv) / WAD;
        // uint256 healthFactor = (maxBorrow * WAD) / debtValue;

        uint256 healthFactor = (collateralValue * WAD * MARKET_PARAMS.lltv) /
            (debtValue * WAD);

        // TODO PRODUCTION: Add more granular health checks
        // - Check if position is near liquidation threshold
        // - Emit warning events if health is degrading
        // - Implement auto-rebalancing if health factor drops below safe level

        return healthFactor >= minHealthFactor;
    }

    /* ADMIN FUNCTIONS */

    // TODO PRODUCTION: Add access control modifiers
    // modifier onlyOwner() {
    //     require(msg.sender == owner, Unauthorized());
    //     _;
    // }

    // modifier onlyKeeper() {
    //     require(msg.sender == keeper || msg.sender == owner, Unauthorized());
    //     _;
    // }

    /// @notice Update target leverage ratio
    /// @param newLeverageBps New leverage in basis points
    function setTargetLeverage(uint256 newLeverageBps) external {
        // TODO PRODUCTION: Add onlyOwner modifier
        // TODO PRODUCTION: Add timelock for parameter changes
        require(
            newLeverageBps >= BASIS_POINTS && newLeverageBps <= 30000,
            "Invalid leverage"
        );

        // TODO PRODUCTION: Validate new leverage is safe given current market conditions
        // TODO PRODUCTION: Consider adding a delay before new leverage takes effect

        targetLeverageBps = newLeverageBps;
        emit LeverageUpdated(newLeverageBps);
    }

    /// @notice Update minimum health factor
    /// @param newMinHealthFactor New minimum health factor in WAD
    function setMinHealthFactor(uint256 newMinHealthFactor) external {
        // TODO PRODUCTION: Add onlyOwner modifier
        // TODO PRODUCTION: Add timelock for parameter changes
        require(newMinHealthFactor >= WAD, "Invalid health factor");

        // TODO PRODUCTION: Ensure new health factor doesn't put existing positions at risk

        minHealthFactor = newMinHealthFactor;
        emit MinHealthFactorUpdated(newMinHealthFactor);
    }

    // TODO PRODUCTION: Add more admin functions:
    // - pause() / unpause()
    // - setDexRouter(address)
    // - setKeeper(address)
    // - setFeeRecipient(address)
    // - withdrawFees()
    // - transferOwnership(address)
    // - acceptOwnership() (2-step transfer)
    // - setEmergencyWithdrawalDelay(uint256)
    // - updateMarketParams(MarketParams) with safety checks

    /* VIEW FUNCTIONS */

    /// @notice Get user position details
    /// @param user User address
    /// @return User position struct
    function getUserPosition(
        address user
    ) external view returns (UserPosition memory) {
        return userPositions[user];
    }

    /// @notice Get current health factor for a user
    /// @param user User address
    /// @return Health factor in WAD
    function getHealthFactor(address user) external view returns (uint256) {
        UserPosition storage position = userPositions[user];

        if (position.borrowedAmount == 0) {
            return type(uint256).max;
        }

        // TODO PRODUCTION: Use oracle prices for accurate health factor
        // IOracle oracle = IOracle(MARKET_PARAMS.oracle);
        // uint256 collateralPrice = oracle.price();
        // uint256 collateralValueInLoanToken = (position.collateralAmount * collateralPrice) / ORACLE_PRICE_SCALE;

        uint256 collateralValue = position.collateralAmount;
        uint256 healthFactor = (collateralValue * WAD * MARKET_PARAMS.lltv) /
            (position.borrowedAmount * WAD);

        return healthFactor;
    }

    // TODO PRODUCTION: Add more view functions
    // - getCurrentLeverage(address user)
    // - getPositionValue(address user) returns (uint256 collateral, uint256 debt, uint256 equity)
    // - getLiquidationPrice(address user)
    // - getMaxWithdrawable(address user)
    // - getAccruedInterest(address user)
    // - getTotalValueLocked()
    // - getMarketUtilization()
    // - isPositionLiquidatable(address user)

    /* EMERGENCY */

    /// @notice Emergency function to rescue tokens
    /// @param token Token address
    /// @param amount Amount to rescue
    /// @param to Recipient address
    function emergencyRescue(
        address token,
        uint256 amount,
        address to
    ) external {
        // TODO PRODUCTION CRITICAL: Add proper access control
        // TODO PRODUCTION: Add timelock with delay
        // TODO PRODUCTION: Add checks to prevent rescuing user funds
        // TODO PRODUCTION: Emit event for transparency

        // In production, add proper access control (onlyOwner, timelock, etc.)
        // require(msg.sender == owner, Unauthorized());
        // require(block.timestamp >= emergencyWithdrawalDelay + lastEmergencyWithdrawal, "Timelock active");
        // require(token != address(LOAN_TOKEN) && token != address(WSTETH), "Cannot rescue active tokens");
        // require(to != address(0), InvalidAddress());

        IERC20(token).transfer(to, amount);

        // emit EmergencyRescue(token, amount, to);
    }

    // TODO PRODUCTION: Add more emergency functions
    // - emergencyExit(address user) - Force close position in emergency
    // - pauseContract() - Circuit breaker
    // - updateEmergencyAdmin(address) - Change emergency admin
    // - migratePosition(address user, address newStrategy) - Migrate to new version

    // TODO PRODUCTION: Add keeper functions for position management
    // - rebalancePosition(address user) - Auto-rebalance to maintain health
    // - liquidatePosition(address user) - Liquidate unhealthy position before Morpho does
    // - harvestRewards(address user) - Claim and compound staking rewards
    // - batchRebalance(address[] users) - Gas-efficient batch operations

    /// @notice Receive ETH (for WETH unwrapping if needed)
    receive() external payable {
        // TODO PRODUCTION: Add restrictions on who can send ETH
        // Only allow WETH contract or specific authorized addresses
    }
}
