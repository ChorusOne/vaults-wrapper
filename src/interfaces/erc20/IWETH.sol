// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @notice Interface for Wrapped Ether (WETH) contract
 * @dev Extends ERC20 with deposit/withdraw functionality
 */
interface IWETH is IERC20 {
    /**
     * @notice Deposit ETH and receive WETH
     */
    function deposit() external payable;

    /**
     * @notice Withdraw ETH by burning WETH
     * @param wad Amount of WETH to burn
     */
    function withdraw(uint256 wad) external;

    function totalSupply() external view returns (uint256);

    function approve(address guy, uint256 wad) external returns (bool);

    function transfer(address dst, uint256 wad) external returns (bool);

    function transferFrom(address src, address dst, uint256 wad) external returns (bool);
}
