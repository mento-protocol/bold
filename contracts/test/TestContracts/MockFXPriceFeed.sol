// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./Interfaces/IMockFXPriceFeed.sol";

/*
* PriceFeed placeholder for testnet and development. The price is simply set manually and saved in a state 
* variable. The contract does not connect to a live Chainlink price feed. 
*/
contract MockFXPriceFeed is IMockFXPriceFeed {

    uint256 private _price = 200 * 1e18;
    bool isShutdown = false;

    function getPrice() external view override returns (uint256) {
        return _price;
    }

    function setPrice(uint256 price) external {
        _price = price;
    }

    function lastGoodPrice() external view returns (uint256) {
        revert("Not implemented");
        return _price;
    }

    function fetchPrice() external override returns (uint256, bool) {
        require(!isShutdown, "MockFXPriceFeed: shutdown");

        return (_price, false);
    }

    function fetchRedemptionPrice() external override returns (uint256, bool) {
        require(!isShutdown, "MockFXPriceFeed: shutdown");

        return (_price, false);
    }

    function shutdown() external {
        isShutdown = true;
    }
}
