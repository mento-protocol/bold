// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./Interfaces/IMockFXPriceFeed.sol";

/*
* Mock FXPriceFeed contract for testing purposes.
* The price is simply set manually and saved in a state variable.
*/
contract MockFXPriceFeed is IMockFXPriceFeed {

    uint256 private _price = 200 * 1e18;
    bool private _isShutdown = false;

    function getPrice() external view override returns (uint256) {
        return _price;
    }

    function setPrice(uint256 price) external {
        _price = price;
    }

    function fetchPrice() external override returns (uint256) {
        require(!_isShutdown, "MockFXPriceFeed: shutdown");

        return _price;
    }

    function shutdown() external {
        _isShutdown = true;
    }
}
