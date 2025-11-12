// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IMorpho, IMorphoBase, MarketParams, Id, Position, Market} from "./interfaces/IMorpho.sol";
import {IMorphoSupplyCollateralCallback} from "./interfaces/IMorphoCallbacks.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Wrapper} from "./Wrapper.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

/// @title MorphoLoopedStrategy
/// @notice Leveraged staking strategy using Morpho Blue supply collateral callbacks
/// @dev Implements IStrategy and IMorphoSupplyCollateralCallback for atomic leverage operations
///
/// TODO PRODUCTION: Critical items before mainnet deployment
/// 1. ACCESS CONTROL: Add OpenZeppelin Ownable/AccessControl to admin functions
/// 2. EXIT FLOW: Implement exit using IMorphoRepayCallback for atomic unwinding
/// 3. ORACLE INTEGRATION: Use Morpho's oracle for accurate price feeds in health checks
/// 4. SLIPPAGE PROTECTION: Add min/max amount checks on wstETH minting
/// 5. REENTRANCY GUARDS: Add ReentrancyGuard to all external functions
/// 6. PAUSE MECHANISM: Add circuit breaker for emergency situations
/// 7. COMPREHENSIVE TESTING: Unit tests, integration tests, fuzzing, formal verification
/// 8. GAS OPTIMIZATION: Optimize storage layout and function calls
/// 9. LIQUIDATION PROTECTION: Add monitoring and keeper system for position health
/// 10. AUDIT: Complete security audit by reputable firm
contract MorphoLoopedStrategy is IStrategy, IMorphoSupplyCollateralCallback {
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

    /// @notice Callback context for supply collateral callbacks
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
        uint256 borrowAmount; // Amount to borrow in callback
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

    /// @notice Execute leveraged staking strategy using supply collateral callback
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

        // Calculate total collateral needed and initial/borrow split for target leverage
        // For 5x leverage: initialCollateral = 1/5 total, borrowAmount = 4/5 total
        uint256 totalCollateralValue = _getCollateralValueFromStvShares(
            stvTokenShares
        );
        uint256 leverageMultiplier = targetLeverageBps / BASIS_POINTS; // e.g., 5 for 50000 bps
        uint256 initialCollateralValue = totalCollateralValue /
            leverageMultiplier;
        uint256 borrowAmount = totalCollateralValue - initialCollateralValue;

        // TODO PRODUCTION: Validate borrow amount is within safe limits
        // require(borrowAmount > 0 && borrowAmount < maxBorrowAmount, "Invalid borrow amount");

        // Mint INITIAL wstETH directly from Lido v3 Dashboard (no wrapping needed!)
        uint256 initialWstETH = IDashboard(
            payable(address(WRAPPER.DASHBOARD()))
        ).mintWstETH{value: initialCollateralValue}(
            address(this),
            initialCollateralValue
        );

        emit DebugLog(
            "Initial wstETH minted",
            initialWstETH,
            initialCollateralValue
        );

        // Set callback context
        _callbackContext = CallbackContext({
            user: user,
            stvTokenShares: stvTokenShares,
            borrowAmount: borrowAmount,
            isDeposit: true
        });

        // Supply initial collateral WITH callback
        // Morpho will record this collateral, THEN call onMorphoSupplyCollateral
        // where we borrow against it and add more collateral
        bytes memory data = abi.encode(user, borrowAmount);
        MORPHO.supplyCollateral(
            MARKET_PARAMS,
            initialWstETH,
            address(this),
            data
        );

        // Clear callback context
        delete _callbackContext;

        // Verify position health
        if (!_checkPositionHealth(user)) {
            revert UnhealthyPosition();
        }

        UserPosition memory position = userPositions[user];
        uint256 actualLeverage = (position.collateralAmount * BASIS_POINTS) /
            initialWstETH;

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

        // TODO PRODUCTION: Implement exit flow using Morpho repay callback
        // Flow should be:
        // 1. Call MORPHO.repay() with callback
        // 2. In onMorphoRepay callback:
        //    - Withdraw collateral (debt already reduced)
        //    - Unwrap wstETH to get ETH
        //    - Swap ETH to WETH if needed
        //    - Approve WETH for Morpho to pull for repayment
        // 3. Position unwound atomically

        // For now, revert until exit flow is implemented
        revert("Exit flow not implemented yet");

        // emit PositionClosed(user, collateralToWithdraw, debtToRepay);

        // // TODO PRODUCTION: Calculate actual return value considering:
        // // - Accrued staking rewards
        // // - Interest paid
        // // - Fees
        // // - Price impact from unwinding
        // // Return initial shares (simplified - in production, calculate actual value)
        // assets = position.initialStvShares;

        // // Clean up position
        // delete userPositions[user];

        // return assets;
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

    /// @notice Callback function for Morpho supply collateral
    /// @param assets Amount of collateral being supplied
    /// @param data Encoded callback data
    function onMorphoSupplyCollateral(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(MORPHO), "Unauthorized callback");

        // TODO PRODUCTION: Add reentrancy protection
        // TODO PRODUCTION: Verify callback context is valid
        // require(_callbackContext.user != address(0), "Invalid callback context");

        (address user, uint256 borrowAmount) = abi.decode(data, (address, uint256));

        // At this point: Morpho has ALREADY recorded our initial collateral (assets)
        // We can now borrow the FULL amount for our target leverage!

        // Step 1: Borrow FULL WETH amount from Morpho
        (uint256 borrowed, ) = MORPHO.borrow(
            MARKET_PARAMS,
            borrowAmount,
            0, // use assets not shares
            address(this),
            address(this)
        );

        emit DebugLog("Borrowed from Morpho", borrowed, borrowAmount);

        // Step 2: Unwrap WETH → ETH
        IWETH(address(LOAN_TOKEN)).withdraw(borrowed);

        emit DebugLog("WETH unwrapped to ETH", borrowed, 0);

        // Step 3: Mint wstETH DIRECTLY from Lido v3 (no wrapping needed!)
        uint256 additionalWstETH = IDashboard(payable(address(WRAPPER.DASHBOARD()))).mintWstETH{value: borrowed}(
            address(this),
            borrowed // amount of wstETH to mint
        );

        emit DebugLog("Additional wstETH minted", additionalWstETH, borrowed);

        // Step 4: Approve Morpho to pull this additional wstETH as collateral
        // When this callback completes, Morpho will transfer the approved wstETH
        WSTETH.approve(address(MORPHO), additionalWstETH);

        // Step 5: Record the position
        userPositions[user] = UserPosition({
            user: user,
            collateralAmount: assets + additionalWstETH, // total collateral
            borrowedAmount: borrowed,
            initialStvShares: _callbackContext.stvTokenShares,
            isExiting: false,
            timestamp: block.timestamp
        });

        // TODO PRODUCTION: Verify all tokens were properly transferred
        // TODO PRODUCTION: Emit detailed callback execution event
    }

    /// @notice Interface for WETH unwrapping
    interface IWETH {
        function withdraw(uint256 amount) external;
        function deposit() external payable;
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
