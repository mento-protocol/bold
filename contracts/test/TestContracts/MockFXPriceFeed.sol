// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./Interfaces/IMockFXPriceFeed.sol";

/*
* PriceFeed placeholder for testnet and development. The price is simply set manually and saved in a state 
* variable. The contract does not connect to a live Chainlink price feed. 
*/
contract MockFXPriceFeed is IMockFXPriceFeed {
    event LastGoodPriceUpdated(uint256 _lastGoodPrice);

    uint256 private _price = 200 * 1e18;

    // --- Functions ---

    // View price getter for simplicity in tests
    function getPrice() external view override returns (uint256) {
        return _price;
    }

    function lastGoodPrice() external view returns (uint256) {
        return _price;
    }

    function fetchPrice() external override returns (uint256, bool) {
        // Fire an event just like the mainnet version would.
        // This lets the subgraph rely on events to get the latest price even when developing locally.
        emit LastGoodPriceUpdated(_price);
        return (_price, false);
    }

    function fetchRedemptionPrice() external override returns (uint256, bool) {
        // Fire an event just like the mainnet version would.
        // This lets the subgraph rely on events to get the latest price even when developing locally.
        emit LastGoodPriceUpdated(_price);
        return (_price, false);
    }

    // Manual external price setter.
    function setPrice(uint256 price) external returns (bool) {
        _price = price;
        return true;
    }
}
