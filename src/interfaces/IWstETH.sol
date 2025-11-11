// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWstETH
/// @notice Interface for Wrapped Staked ETH (wstETH) token
/// @dev wstETH is a non-rebasing version of stETH that wraps stETH 1:1 on a share basis
interface IWstETH is IERC20 {
    /// @notice Exchanges stETH to wstETH
    /// @param _stETHAmount amount of stETH to wrap in exchange for wstETH
    /// @return Amount of wstETH user receives after wrap
    function wrap(uint256 _stETHAmount) external returns (uint256);

    /// @notice Exchanges wstETH to stETH
    /// @param _wstETHAmount amount of wstETH to unwrap in exchange for stETH
    /// @return Amount of stETH user receives after unwrap
    function unwrap(uint256 _wstETHAmount) external returns (uint256);

    /// @notice Get amount of wstETH for a given amount of stETH
    /// @param _stETHAmount amount of stETH
    /// @return Amount of wstETH for a given stETH amount
    function getWstETHByStETH(
        uint256 _stETHAmount
    ) external view returns (uint256);

    /// @notice Get amount of stETH for a given amount of wstETH
    /// @param _wstETHAmount amount of wstETH
    /// @return Amount of stETH for a given wstETH amount
    function getStETHByWstETH(
        uint256 _wstETHAmount
    ) external view returns (uint256);

    /// @notice Get amount of stETH for a one wstETH
    /// @return Amount of stETH for 1 wstETH
    function stEthPerToken() external view returns (uint256);

    /// @notice Get amount of wstETH for a one stETH
    /// @return Amount of wstETH for a 1 stETH
    function tokensPerStEth() external view returns (uint256);
}
