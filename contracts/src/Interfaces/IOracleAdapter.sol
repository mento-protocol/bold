// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

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