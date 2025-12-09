// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexRouter} from "src/interfaces/IDexRouter.sol";

/**
 * @title MockDexRouter
 * @notice Mock DEX router for testing wstETH -> WETH swaps
 * @dev Simulates exact-output swaps with configurable exchange rate
 */
contract MockDexRouter is IDexRouter {
    /// @notice Exchange rate in 1e18 scale (1e18 = 1:1, 1.1e18 = need 10% more fromToken)
    uint256 public exchangeRate = 1e18;

    /// @notice Slippage check failed
    error SlippageExceeded(uint256 required, uint256 maxAllowed);

    /// @notice Insufficient balance to fulfill swap
    error InsufficientBalance(address token, uint256 required, uint256 available);

    /**
     * @notice Set the exchange rate for testing
     * @param _rate Rate in 1e18 scale. Higher = worse rate for user
     *              1e18 = 1:1 (1 fromToken for 1 toToken)
     *              1.1e18 = 1.1 fromToken for 1 toToken (10% worse)
     *              0.9e18 = 0.9 fromToken for 1 toToken (10% better)
     */
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

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
        override
        returns (uint256 fromAmountUsed)
    {
        // Calculate how much fromToken is needed based on exchange rate
        fromAmountUsed = (_toAmount * exchangeRate) / 1e18;

        // Check slippage
        if (fromAmountUsed > _maxFromAmount) {
            revert SlippageExceeded(fromAmountUsed, _maxFromAmount);
        }

        // Check this contract has enough toToken to send
        uint256 toBalance = IERC20(_toToken).balanceOf(address(this));
        if (toBalance < _toAmount) {
            revert InsufficientBalance(_toToken, _toAmount, toBalance);
        }

        // Transfer fromToken from caller to this contract
        bool success = IERC20(_fromToken).transferFrom(msg.sender, address(this), fromAmountUsed);
        require(success, "fromToken transfer failed");

        // Transfer toToken to caller
        success = IERC20(_toToken).transfer(msg.sender, _toAmount);
        require(success, "toToken transfer failed");

        return fromAmountUsed;
    }

    /**
     * @notice Receive ETH and wrap it
     */
    receive() external payable {}
}
