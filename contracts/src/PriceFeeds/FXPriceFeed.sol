// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Interfaces/IPriceFeed.sol";
import "../BorrowerOperations.sol";

import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

interface IOracleAdapter {
    function getFXRateIfValid(address rateFeedID) external view returns (uint256 numerator, uint256 denominator);
}

contract FXPriceFeed is IPriceFeed, OwnableUpgradeable {

    IOracleAdapter public oracleAdapter;
    address public rateFeedID;
    address public watchdogAddress;
    IBorrowerOperations public borrowerOperations;

    uint256 public lastGoodPrice;
    bool public isShutdown;

    constructor(bool disableInitializers) {
      if (disableInitializers) {
        _disableInitializers();
      }
    }

    function initialize(
        address _oracleAdapterAddress,
        address _rateFeedID,
        address _borrowerOperationsAddress,
        address _watchdogAddress,
        address _initialOwner
    ) external initializer {
        oracleAdapter = IOracleAdapter(_oracleAdapterAddress);
        rateFeedID = _rateFeedID;
        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        watchdogAddress = _watchdogAddress;

        _transferOwnership(_initialOwner);
    }

    function setWatchdogAddress(address _watchdogAddress) external onlyOwner {
        watchdogAddress = _watchdogAddress;
    }

    function fetchPrice() public returns (uint256, bool) {
        if (isShutdown) {
            return (lastGoodPrice, false);
        }

        (uint256 numerator, ) = oracleAdapter.getFXRateIfValid(rateFeedID);

        lastGoodPrice = numerator;

        return (numerator, false);
    }

    function fetchRedemptionPrice() external returns (uint256, bool) {
        return fetchPrice();
    }

    function shutdown() external {
        require(!isShutdown, "MentoPriceFeed: already shutdown");
        require(msg.sender == watchdogAddress, "MentoPriceFeed: not authorized");

        isShutdown = true;
        borrowerOperations.shutdownFromOracleFailure();
    }
}
