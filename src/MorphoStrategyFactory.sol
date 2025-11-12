// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {MorphoLoopedStrategy} from "./MorphoLoopedStrategy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title MorphoStrategyFactory
/// @notice Factory contract that implements IStrategy and routes calls to per-user strategy proxies
/// @dev Uses ERC-1167 minimal proxies to give each user their own isolated Morpho position
///
/// Architecture:
///   Escrow → Factory (IStrategy) → User Proxy A (MorphoLoopedStrategy) → Morpho Position A
///                                → User Proxy B (MorphoLoopedStrategy) → Morpho Position B
///                                → User Proxy C (MorphoLoopedStrategy) → Morpho Position C
///
/// Benefits:
/// - Complete Morpho position isolation (no liquidation contagion)
/// - Individual risk profiles per user
/// - Gas efficient: ~50k gas per user proxy deployment
/// - Zero changes needed to Escrow contract
///
/// TODO PRODUCTION:
/// 1. ACCESS CONTROL: Add access control for admin functions
/// 2. PAUSE MECHANISM: Add ability to pause proxy creation
/// 3. UPGRADE PATH: Consider beacon proxy if upgrade capability needed
/// 4. MONITORING: Add events for tracking proxy creation and usage
/// 5. RESCUE FUNCTIONS: Add ability to rescue tokens sent to factory by mistake
contract MorphoStrategyFactory is IStrategy {
    using Clones for address;

    /* IMMUTABLES */

    /// @notice Address of the MorphoLoopedStrategy implementation contract
    /// @dev All user proxies delegate calls to this implementation
    address public immutable IMPLEMENTATION;

    /// @notice Default target leverage ratio in basis points
    /// @dev Can be overridden per user if needed (future enhancement)
    uint256 public immutable DEFAULT_TARGET_LEVERAGE_BPS;

    /// @notice Default minimum health factor
    /// @dev Can be overridden per user if needed (future enhancement)
    uint256 public immutable DEFAULT_MIN_HEALTH_FACTOR;

    /* STATE */

    /// @notice Mapping of user addresses to their strategy proxy addresses
    /// @dev Each user gets exactly one strategy proxy for position isolation
    mapping(address => address) public userStrategies;

    /* EVENTS */

    /// @notice Emitted when a new strategy proxy is created for a user
    /// @param user The user address who owns the strategy
    /// @param strategy The address of the deployed proxy contract
    /// @param implementation The implementation contract the proxy delegates to
    event StrategyCreated(
        address indexed user,
        address indexed strategy,
        address indexed implementation
    );

    /// @notice Emitted when a strategy operation is routed
    /// @param user The user whose strategy is being called
    /// @param strategy The proxy address receiving the call
    /// @param operation The operation being performed (execute, initiateExit, finalizeExit)
    event StrategyRouted(
        address indexed user,
        address indexed strategy,
        string operation
    );

    /* ERRORS */

    error StrategyNotFound(address user);
    error StrategyAlreadyExists(address user, address existingStrategy);
    error InvalidImplementation();
    error InvalidUser();
    error InitializationFailed();

    /* CONSTRUCTOR */

    /// @notice Initialize the factory with the implementation contract address and default parameters
    /// @param _implementation Address of the MorphoLoopedStrategy implementation
    /// @param _defaultTargetLeverageBps Default target leverage ratio (e.g., 50000 = 5x)
    /// @param _defaultMinHealthFactor Default minimum health factor (in WAD, e.g., 1.2e18)
    constructor(
        address _implementation,
        uint256 _defaultTargetLeverageBps,
        uint256 _defaultMinHealthFactor
    ) {
        if (_implementation == address(0)) revert InvalidImplementation();

        // TODO PRODUCTION: Verify implementation is a contract
        // require(_implementation.code.length > 0, "Implementation not a contract");

        // TODO PRODUCTION: Verify implementation implements IStrategy
        // Could use ERC165 or manual interface check

        // Validate default parameters
        require(
            _defaultTargetLeverageBps >= 10000 &&
                _defaultTargetLeverageBps <= 30000,
            "Invalid leverage"
        );
        require(_defaultMinHealthFactor >= 1e18, "Invalid health factor");

        IMPLEMENTATION = _implementation;
        DEFAULT_TARGET_LEVERAGE_BPS = _defaultTargetLeverageBps;
        DEFAULT_MIN_HEALTH_FACTOR = _defaultMinHealthFactor;
    }

    /* EXTERNAL FUNCTIONS - IStrategy Implementation */

    /// @notice Execute leveraged staking strategy for a user
    /// @dev Routes to user's strategy proxy, creating it if it doesn't exist
    /// @param user The user address
    /// @param stvTokenShares Amount of stv token shares to leverage
    function execute(address user, uint256 stvTokenShares) external override {
        // Get or create user's strategy proxy
        address userStrategy = _getOrCreateStrategy(user);

        emit StrategyRouted(user, userStrategy, "execute");

        // Delegate to user's strategy proxy
        IStrategy(userStrategy).execute(user, stvTokenShares);
    }

    /// @notice Initiate exit from leveraged position
    /// @dev Routes to user's existing strategy proxy
    /// @param user User address
    /// @param assets Amount of assets (passed through to strategy)
    function initiateExit(address user, uint256 assets) external override {
        address userStrategy = userStrategies[user];
        if (userStrategy == address(0)) revert StrategyNotFound(user);

        emit StrategyRouted(user, userStrategy, "initiateExit");

        // Delegate to user's strategy proxy
        IStrategy(userStrategy).initiateExit(user, assets);
    }

    /// @notice Finalize exit and close leveraged position
    /// @dev Routes to user's existing strategy proxy
    /// @param user User address
    /// @return assets Amount of assets returned
    function finalizeExit(
        address user
    ) external override returns (uint256 assets) {
        address userStrategy = userStrategies[user];
        if (userStrategy == address(0)) revert StrategyNotFound(user);

        emit StrategyRouted(user, userStrategy, "finalizeExit");

        // Delegate to user's strategy proxy
        return IStrategy(userStrategy).finalizeExit(user);
    }

    /// @notice Get borrow details for the caller
    /// @dev Routes to msg.sender's strategy proxy if it exists
    /// @return borrowAssets Borrowed asset amount
    /// @return userAssets User's own assets
    /// @return totalAssets Total assets in position
    function getBorrowDetails()
        external
        view
        override
        returns (uint256 borrowAssets, uint256 userAssets, uint256 totalAssets)
    {
        address userStrategy = userStrategies[msg.sender];

        // If user doesn't have a strategy yet, return zeros
        if (userStrategy == address(0)) {
            return (0, 0, 0);
        }

        // Delegate to user's strategy proxy
        return IStrategy(userStrategy).getBorrowDetails();
    }

    /// @notice Check if caller is exiting
    /// @dev Routes to msg.sender's strategy proxy if it exists
    /// @return True if user position is in exit state
    function isExiting() external view override returns (bool) {
        address userStrategy = userStrategies[msg.sender];

        // If user doesn't have a strategy yet, they're not exiting
        if (userStrategy == address(0)) {
            return false;
        }

        // Delegate to user's strategy proxy
        return IStrategy(userStrategy).isExiting();
    }

    /* PUBLIC FUNCTIONS - Factory Specific */

    /// @notice Get a user's strategy proxy address without creating one
    /// @param user The user address to query
    /// @return The user's strategy proxy address (address(0) if doesn't exist)
    function getUserStrategy(address user) external view returns (address) {
        return userStrategies[user];
    }

    /// @notice Check if a user has a strategy proxy deployed
    /// @param user The user address to check
    /// @return True if user has a strategy proxy
    function hasStrategy(address user) external view returns (bool) {
        return userStrategies[user] != address(0);
    }

    /// @notice Predict the address of a user's strategy proxy
    /// @dev Useful for front-end integration and gas estimation
    /// @param user The user address
    /// @return The predicted address (may not be deployed yet)
    function predictStrategyAddress(
        address user
    ) external view returns (address) {
        bytes32 salt = _getSalt(user);
        return
            Clones.predictDeterministicAddress(
                IMPLEMENTATION,
                salt,
                address(this)
            );
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Get or create a user's strategy proxy
    /// @dev Creates a new proxy if user doesn't have one, otherwise returns existing
    /// @param user The user address
    /// @return The user's strategy proxy address
    function _getOrCreateStrategy(address user) internal returns (address) {
        if (user == address(0)) revert InvalidUser();

        // Check if strategy already exists
        address existingStrategy = userStrategies[user];
        if (existingStrategy != address(0)) {
            return existingStrategy;
        }

        // Create new strategy proxy for user
        return _createStrategy(user);
    }

    /// @notice Create a new strategy proxy for a user
    /// @dev Uses deterministic deployment for predictable addresses
    /// @param user The user address
    /// @return strategy The deployed proxy address
    function _createStrategy(address user) internal returns (address strategy) {
        // Generate deterministic salt based on user address
        bytes32 salt = _getSalt(user);

        // Deploy minimal proxy using CREATE2 for deterministic address
        strategy = Clones.cloneDeterministic(IMPLEMENTATION, salt);

        // Initialize the proxy with user-specific parameters
        // Uses default leverage and health factor settings from factory
        // TODO FUTURE: Allow per-user custom leverage/health factor via additional function
        try
            MorphoLoopedStrategy(strategy).initialize(
                user,
                DEFAULT_TARGET_LEVERAGE_BPS,
                DEFAULT_MIN_HEALTH_FACTOR
            )
        {
            // Initialization successful
        } catch {
            revert InitializationFailed();
        }

        // Record the user's strategy
        userStrategies[user] = strategy;

        // Emit event for tracking
        emit StrategyCreated(user, strategy, IMPLEMENTATION);

        return strategy;
    }

    /// @notice Generate deterministic salt for user's proxy deployment
    /// @dev Using user address as salt ensures one proxy per user
    /// @param user The user address
    /// @return The salt for CREATE2 deployment
    function _getSalt(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user));
    }

    /* ADMIN FUNCTIONS */

    // TODO PRODUCTION: Add admin functions
    // - pause() / unpause() - Prevent new proxy creation in emergency
    // - rescueTokens() - Recover tokens sent to factory by mistake
    // - setImplementation() - Upgrade to new implementation (if using beacon pattern)
    // - Access control (Ownable or AccessControl)

    /* RESCUE FUNCTIONS */

    // TODO PRODUCTION: Add receive/fallback with rescue mechanism
    // Factory shouldn't receive ETH, but add safety mechanism just in case
    // receive() external payable {
    //     revert("Factory does not accept ETH");
    // }
}
