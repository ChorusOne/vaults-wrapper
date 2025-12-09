// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IDexRouter
 * @notice Interface for DEX router with exact output swap functionality
 * @dev Used for swapping wstETH to WETH during leveraged position unwinding
 */
interface IDexRouter {
    /**
     * @notice Buy exact amount of toToken using fromToken
     * @param _fromToken Token to sell (e.g., wstETH)
     * @param _toToken Token to buy (e.g., WETH)
     * @param _toAmount Exact amount of toToken to receive
     * @param _maxFromAmount Maximum fromToken willing to spend (slippage protection)
     * @return fromAmountUsed Actual amount of fromToken spent
     */
    function buy(address _fromToken, address _toToken, uint256 _toAmount, uint256 _maxFromAmount)
        external
        returns (uint256 fromAmountUsed);
}
