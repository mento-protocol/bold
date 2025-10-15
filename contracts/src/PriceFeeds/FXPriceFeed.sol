// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../Interfaces/IPriceFeed.sol";
import "../BorrowerOperations.sol";

import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

/**
 * @title IOracleAdapter
 * @notice Interface for the Oracle Adapter contract that provides FX rate data
 */
interface IOracleAdapter {
    /**
     * @notice Retrieves the FX rate if it's valid
     * @param rateFeedID The address identifier for the specific rate feed
     * @return numerator The numerator of the FX rate fraction
     * @return denominator The denominator of the FX rate fraction
     */
    function getFXRateIfValid(address rateFeedID) external view returns (uint256 numerator, uint256 denominator);
}

/**
 * @title FXPriceFeed
 * @author Mento Labs
 * @notice A contract that fetches the price of an FX rate from an OracleAdapter.
 *         Implements emergency shutdown functionality to handle oracle failures.
 */
contract FXPriceFeed is IPriceFeed, OwnableUpgradeable {

    /// @notice The OracleAdapter contract that provides FX rate data
    IOracleAdapter public oracleAdapter;

    /// @notice The identifier address for the specific rate feed to query
    address public rateFeedID;

    /// @notice The watchdog contract address authorized to trigger emergency shutdown
    address public watchdogAddress;

    /// @notice The BorrowerOperations contract
    IBorrowerOperations public borrowerOperations;

    /// @notice The last valid price returned by the OracleAdapter
    uint256 public lastValidPrice;

    /// @notice Whether the contract has been shutdown due to an oracle failure
    bool public isShutdown;

    /// @notice Emitted when the watchdog address is updated
    /// @param _oldWatchdogAddress The previous watchdog address
    /// @param _newWatchdogAddress The new watchdog address
    event WatchdogAddressUpdated(address indexed _oldWatchdogAddress, address indexed _newWatchdogAddress);

    /// @notice Emitted when the contract is shutdown due to oracle failure
    event FXPriceFeedShutdown();

    /**
     * @notice Contract constructor
     * @param disableInitializers Boolean to disable initializers for implementation contract
     */
    constructor(bool disableInitializers) {
      if (disableInitializers) {
        _disableInitializers();
      }
    }

    /**
    * @notice Initializes the FXPriceFeed contract
    * @param _oracleAdapterAddress The address of the OracleAdapter contract
    * @param _rateFeedID The address of the rate feed ID
    * @param _borrowerOperationsAddress The address of the BorrowerOperations contract
    * @param _watchdogAddress The address of the watchdog contract
    * @param _initialOwner The address of the initial owner
    */
    function initialize(
        address _oracleAdapterAddress,
        address _rateFeedID,
        address _borrowerOperationsAddress,
        address _watchdogAddress,
        address _initialOwner
    ) external initializer {
        require(_oracleAdapterAddress != address(0), "FXPriceFeed: ZERO_ADDRESS");
        require(_rateFeedID != address(0), "FXPriceFeed: ZERO_ADDRESS");
        require(_borrowerOperationsAddress != address(0), "FXPriceFeed: ZERO_ADDRESS");
        require(_watchdogAddress != address(0), "FXPriceFeed: ZERO_ADDRESS");
        require(_initialOwner != address(0), "FXPriceFeed: ZERO_ADDRESS");

        oracleAdapter = IOracleAdapter(_oracleAdapterAddress);
        rateFeedID = _rateFeedID;
        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        watchdogAddress = _watchdogAddress;

        _transferOwnership(_initialOwner);
    }

    /**
    * @notice Sets the watchdog address
    * @param _watchdogAddress The address of the new watchdog contract
    */
    function setWatchdogAddress(address _watchdogAddress) external onlyOwner {
        require(_watchdogAddress != address(0), "FXPriceFeed: ZERO_ADDRESS");

        address oldWatchdogAddress = watchdogAddress;
        watchdogAddress = _watchdogAddress;

        emit WatchdogAddressUpdated(oldWatchdogAddress, _watchdogAddress);
    }

    /**
    * @notice Fetches the price of the FX rate, if valid
    * @dev If the contract is shutdown due to oracle failure, the last valid price is returned
    * @return The price of the FX rate
    */
    function fetchPrice() public returns (uint256) {
        if (isShutdown) {
            return lastValidPrice;
        }

        (uint256 price, ) = oracleAdapter.getFXRateIfValid(rateFeedID);

        lastValidPrice = price;

        return price;
    }

    /**
     * @notice Shuts down the price feed contract due to oracle failure
     * @dev Can only be called by the authorized watchdog address.
     *      Once shutdown:
     *      - The contract will only return the last valid price
     *      - The BorrowerOperations contract is notified to shut down the collateral branch
     *      - The shutdown state is permanent and cannot be reversed
     */
    function shutdown() external {
        require(!isShutdown, "FXPriceFeed: already shutdown");
        require(msg.sender == watchdogAddress, "FXPriceFeed: not authorized");

        isShutdown = true;
        borrowerOperations.shutdownFromOracleFailure();

        emit FXPriceFeedShutdown();
    }
}