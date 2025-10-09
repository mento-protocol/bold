// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFXPriceFeed {
    function fetchPrice() external returns (uint256, bool);
}
