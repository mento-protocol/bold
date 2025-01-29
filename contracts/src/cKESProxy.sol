// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract cKESProxy is TransparentUpgradeableProxy {
    /**
     * @dev Initializes the proxy with the implementation address and admin address
     * @param _logic Initial implementation address
     * @param admin_ Address of the proxy admin
     * @param _data Initialization call data
     */
    constructor(
        address _logic,
        address admin_,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, admin_, _data) {}
    
}