// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import "./FullMath.sol";
import "./SqrtPriceMath.sol";

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee

    /**
     * this function is called from a while loop that continues to execute
     *  until input/output have not breached the slippage limit (sqrtRatioTargetX96)
     */
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        /**
         * price = token1 / token0
         * if price is decreased, token is token0
         * if price is increased, token is token1
         */
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;

        /**
         * check if amount remaining after swap is positive or zero
         * - if slippage limit (sqrtRatioTargetX96) is hit, but there is still input remaining; positive amountRemaining
         * - if slippage limit exact to the input; amountRemaining is zero
         */
        bool exactIn = amountRemaining >= 0;

        // statement sets return values sqrtRatioNextX96, amountIn, amountOut
        // This section of the if statement activates while amountRemaining is a positive number
        // Amount is going in
        if (exactIn) {
            // amountRemaining * (1,000,000 - feePips) / 1,000,000
            // 1e6 is fixed point math that sets a token limit of 1,000,000
            // amountRemaining is cast to unint256 for the FullMath function
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);

            // amountIn = token 1 or 0 required to cover position
            amountIn = zeroForOne
                /**
                 * if zeroForOne is true, calculate the amount0 delta between the two prices
                 * liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
                 * returns amount of token0 required to cover a position of size liquidity between the two passed prices
                 */
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                /**
                 * else, get the amount1 delta between the 2 prices
                 * calculates liquidity * (sqrt(upper) - sqrt(lower))
                 * returns amount of token1 required to cover a position of size liquidity between the two passed prices
                 */
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            if (amountRemainingLessFee >= amountIn) {
                // if swap will continue to execute from the while loop, set the next price to the target
                // OR
                //
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                // calculate new sqrtRatio for last swap with formula; liquidity / (liquidity / sqrtPX96 +- amount)
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                );
            }
        // else activates when amountRemaing >= 0 is false
        // Amount going out
        } else {
            // reverse the above logic in terms of the reversal of the tokens
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96, liquidity, uint256(-amountRemaining), zeroForOne
                );
            }
        }

        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) { 
            amountIn = max && exactIn 
                ? amountIn // true && true, then no amount adjustment
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true); // if false, adjust amountIn based on price delta, rounds up
            amountOut = max && !exactIn
                ? amountOut // if true, no amount adjustment
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false); // if false, adjust amountOut based on price delta, rounds down
        } else { // same as above just for the other direction of the trade
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
