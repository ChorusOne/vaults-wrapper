// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Wrapper} from "./Wrapper.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

/**
 * @title StandardDepositStrategy
 * @notice Simple non-leveraged strategy that deposits ETH into stVault and tracks user positions
 * @dev This strategy does NOT use stETH or wstETH tokens. It simply funds the vault with ETH
 *      and tracks user positions using stvToken shares. The vault's ETH is automatically staked
 *      on the beacon chain, and staking rewards accrue to the vault's totalValue.
 */
contract StandardDepositStrategy is IStrategy {
    /// @notice The wrapper's ERC4626 token (stvToken)
    IERC20 public immutable STV_TOKEN;

    /// @notice The DeFi wrapper contract
    Wrapper public immutable WRAPPER;

    /// @notice Lido v3 VaultHub contract
    IVaultHub public immutable VAULT_HUB;

    /// @notice The underlying staking vault address
    address public immutable STAKING_VAULT;

    /// @notice Dashboard contract for vault operations
    IDashboard public immutable DASHBOARD;

    /// @notice Tracks individual user positions
    struct UserPosition {
        address user; // User address
        uint256 shares; // stvToken shares deposited
        uint256 depositTimestamp; // When position was opened
        bool isExiting; // Whether user initiated exit
    }

    /// @notice Mapping of user address to their position
    mapping(address => UserPosition) public userPositions;

    /// @notice Emitted when a user opens a standard deposit position
    event PositionOpened(
        address indexed user,
        uint256 shares,
        uint256 timestamp
    );

    /// @notice Emitted when a user initiates position exit
    event ExitInitiated(address indexed user, uint256 shares);

    /// @notice Emitted when a position is finalized and closed
    event PositionClosed(address indexed user, uint256 shares);

    /**
     * @notice Constructor initializes the strategy with wrapper and vault references
     * @param _wrapper Address of the DeFi wrapper contract
     */
    constructor(address _wrapper) {
        require(_wrapper != address(0), "Invalid wrapper address");

        WRAPPER = Wrapper(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        DASHBOARD = WRAPPER.DASHBOARD();
        VAULT_HUB = WRAPPER.VAULT_HUB();
        STAKING_VAULT = WRAPPER.STAKING_VAULT();
    }

    /**
     * @notice Execute the standard deposit strategy
     * @dev For standard deposits, this simply records the user's position
     *      No leverage, no stETH minting - just track the shares
     * @param user Address of the user opening the position
     * @param stvTokenShares Number of stvToken shares the user is depositing
     */
    function execute(address user, uint256 stvTokenShares) external override {
        require(
            msg.sender == address(WRAPPER) ||
                msg.sender == address(WRAPPER.ESCROW()),
            "Only wrapper/escrow"
        );
        require(stvTokenShares > 0, "Zero shares");
        require(userPositions[user].shares == 0, "Position already exists");

        // Transfer stvToken shares from caller (Escrow) to this strategy
        require(
            STV_TOKEN.transferFrom(msg.sender, address(this), stvTokenShares),
            "Transfer failed"
        );

        // Record the user's position
        userPositions[user] = UserPosition({
            user: user,
            shares: stvTokenShares,
            depositTimestamp: block.timestamp,
            isExiting: false
        });

        emit PositionOpened(user, stvTokenShares, block.timestamp);
    }

    /**
     * @notice Initiate exit from the position
     * @dev Marks the position as exiting - actual withdrawal happens in finalizeExit
     * @param user Address of the user exiting
     * @param assets Amount of assets to withdraw (unused in standard strategy)
     */
    function initiateExit(address user, uint256 assets) external override {
        require(
            msg.sender == address(WRAPPER) ||
                msg.sender == address(WRAPPER.ESCROW()),
            "Only wrapper/escrow"
        );

        UserPosition storage position = userPositions[user];
        require(position.user == user, "Position not found");
        require(!position.isExiting, "Already exiting");

        position.isExiting = true;

        emit ExitInitiated(user, position.shares);
    }

    /**
     * @notice Finalize exit and return assets to user
     * @dev For standard strategy, simply return the stvToken shares to the caller
     *      The wrapper/escrow will handle converting to ETH
     * @param user Address of the user finalizing exit
     * @return assets Amount of stvToken shares returned
     */
    function finalizeExit(
        address user
    ) external override returns (uint256 assets) {
        require(
            msg.sender == address(WRAPPER) ||
                msg.sender == address(WRAPPER.ESCROW()),
            "Only wrapper/escrow"
        );

        UserPosition storage position = userPositions[user];
        require(position.isExiting, "Not exiting");

        // Get shares to return
        assets = position.shares;

        // Transfer stvToken shares back to caller
        require(STV_TOKEN.transfer(msg.sender, assets), "Transfer failed");

        emit PositionClosed(user, assets);

        // Clean up position
        delete userPositions[user];

        return assets;
    }

    /**
     * @notice Get borrowing details for a user's position
     * @dev For standard strategy, there is no borrowing - all values are zero or user's shares
     * @return borrowAssets Always 0 (no borrowing in standard strategy)
     * @return userAssets User's stvToken shares
     * @return totalAssets Same as userAssets (no leverage)
     */
    function getBorrowDetails()
        external
        view
        override
        returns (uint256 borrowAssets, uint256 userAssets, uint256 totalAssets)
    {
        UserPosition storage position = userPositions[msg.sender];
        return (
            0, // No borrowing in standard strategy
            position.shares, // User's actual shares
            position.shares // Total = user shares (no leverage)
        );
    }

    /**
     * @notice Check if a user's position is in exit mode
     * @return bool True if user has initiated exit
     */
    function isExiting() external view override returns (bool) {
        UserPosition storage position = userPositions[msg.sender];
        return position.isExiting;
    }

    /**
     * @notice Get a user's position details
     * @param user Address of the user
     * @return position The user's position struct
     */
    function getPosition(
        address user
    ) external view returns (UserPosition memory) {
        return userPositions[user];
    }

    /**
     * @notice Get the current value of the vault
     * @dev This includes all staking rewards that have accrued
     * @return uint256 Total vault value in ETH
     */
    function getVaultValue() external view returns (uint256) {
        return VAULT_HUB.totalValue(STAKING_VAULT);
    }

    /**
     * @notice Calculate the ETH value of a user's position
     * @param user Address of the user
     * @return uint256 ETH value of the user's shares
     */
    function getPositionValue(address user) external view returns (uint256) {
        UserPosition storage position = userPositions[user];
        if (position.shares == 0) return 0;

        // Use wrapper's conversion to get ETH value
        return WRAPPER.previewRedeem(position.shares);
    }
}
