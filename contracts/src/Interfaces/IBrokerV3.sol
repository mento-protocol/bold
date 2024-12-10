// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * Interface for the BrokerV3 contract that allows users to swap between different stable tokens.
 */
interface IBrokerV3 {
    /**
     * @notice Emitted when a swap occurs.
     * @param from The address of the input token.
     * @param to The address of the output token.
     * @param amountIn The amount of input token swapped.
     * @param amountOut The amount of output token received.
     */
    event Swapped(
        address indexed from,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );

    /**
     * @notice Swaps from one stable token to another.
     * @param from The address of the input token.
     * @param to The address of the output token.
     * @param amountIn The amount of input token to swap.
     */
    function swap(
        address from,
        address to,
        uint256 amountIn
    ) external returns (uint256);
}
