// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IActivePool.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITroveNFT.sol";
import "./Interfaces/ISystemParams.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/Constants.sol";
import "./Types/LatestTroveData.sol";
import "./Types/LatestBatchData.sol";

/**
 * @title BorrowerOperationsBatchManager
 * @notice Handles complex batch manager operations for BorrowerOperations
 * @dev This contract is extracted to reduce the size of the main BorrowerOperations contract.
 *      It contains the largest batch management functions. BorrowerOperations forwards calls here.
 */
contract BorrowerOperationsBatchManager is LiquityBase {
    ITroveManager public immutable troveManager;
    ISortedTroves public immutable sortedTroves;
    ITroveNFT public immutable troveNFT;
    ISystemParams public immutable systemParams;
    IBorrowerOperations public immutable borrowerOperations;

    error IsShutDown();
    error InterestNotInRange();
    error BatchInterestRateChangePeriodNotPassed();
    error InvalidInterestBatchManager();
    error BatchManagerExists();
    error NewFeeNotLower();
    error AnnualManagementFeeTooHigh();
    error MinInterestRateChangePeriodTooLow();
    error MinGeMax();
    error NotBorrower();
    error TroveNotActive();
    error TroveNotInBatch();
    error TroveNotOpen();
    error ICRBelowMCRPlusBCR();
    error TCRBelowCCR();
    error UpfrontFeeTooHigh();
    error InterestRateTooLow();
    error InterestRateTooHigh();
    error BatchSharesRatioTooLow();

    struct LocalVariables_setInterestBatchManager {
        ITroveManager troveManager;
        IActivePool activePool;
        ISortedTroves sortedTroves;
        LatestTroveData trove;
        LatestBatchData newBatch;
    }

    struct LocalVariables_removeFromBatch {
        ITroveManager troveManager;
        ISortedTroves sortedTroves;
        address batchManager;
        LatestTroveData trove;
        LatestBatchData batch;
        uint256 batchFutureDebt;
        TroveChange batchChange;
    }

    constructor(
        IAddressesRegistry _addressesRegistry,
        ISystemParams _systemParams
    ) LiquityBase(_addressesRegistry) {
        borrowerOperations = _addressesRegistry.borrowerOperations();
        troveManager = _addressesRegistry.troveManager();
        sortedTroves = _addressesRegistry.sortedTroves();
        troveNFT = _addressesRegistry.troveNFT();
        systemParams = _systemParams;
    }

    // --- Batch Manager Operations ---

    function registerBatchManager(
        uint128 _minInterestRate,
        uint128 _maxInterestRate,
        uint128 _currentInterestRate,
        uint128 _annualManagementFee,
        uint128 _minInterestRateChangePeriod
    ) external {
        _requireIsNotShutDown();
        _requireNonExistentInterestBatchManager(msg.sender);
        _requireValidAnnualInterestRate(_minInterestRate);
        _requireValidAnnualInterestRate(_maxInterestRate);
        _requireOrderedRange(_minInterestRate, _maxInterestRate);
        _requireInterestRateInRange(
            _currentInterestRate,
            _minInterestRate,
            _maxInterestRate
        );
        if (_annualManagementFee > MAX_ANNUAL_BATCH_MANAGEMENT_FEE) {
            revert AnnualManagementFeeTooHigh();
        }
        if (_minInterestRateChangePeriod < MIN_INTEREST_RATE_CHANGE_PERIOD) {
            revert MinInterestRateChangePeriodTooLow();
        }

        // Call back to BorrowerOperations to store the batch manager
        borrowerOperations.setBatchManagerData(
            msg.sender,
            _minInterestRate,
            _maxInterestRate,
            _minInterestRateChangePeriod
        );

        troveManager.onRegisterBatchManager(
            msg.sender,
            _currentInterestRate,
            _annualManagementFee
        );
    }

    function lowerBatchManagementFee(uint256 _newAnnualManagementFee) external {
        _requireIsNotShutDown();
        _requireValidInterestBatchManager(msg.sender);

        LatestBatchData memory batch = troveManager.getLatestBatchData(msg.sender);
        if (_newAnnualManagementFee >= batch.annualManagementFee) {
            revert NewFeeNotLower();
        }

        // Lower batch fee on TM
        troveManager.onLowerBatchManagerAnnualFee(
            msg.sender,
            batch.entireCollWithoutRedistribution,
            batch.entireDebtWithoutRedistribution,
            _newAnnualManagementFee
        );

        // active pool mint
        TroveChange memory batchChange;
        batchChange.batchAccruedManagementFee = batch.accruedManagementFee;
        batchChange.oldWeightedRecordedDebt = batch.weightedRecordedDebt;
        batchChange.newWeightedRecordedDebt =
            batch.entireDebtWithoutRedistribution *
            batch.annualInterestRate;
        batchChange.oldWeightedRecordedBatchManagementFee = batch
            .weightedRecordedBatchManagementFee;
        batchChange.newWeightedRecordedBatchManagementFee =
            batch.entireDebtWithoutRedistribution *
            _newAnnualManagementFee;

        activePool.mintAggInterestAndAccountForTroveChange(
            batchChange,
            msg.sender
        );
    }

    function setBatchManagerAnnualInterestRate(
        uint128 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {
        _requireIsNotShutDown();
        _requireValidInterestBatchManager(msg.sender);
        _requireInterestRateInBatchManagerRange(
            msg.sender,
            _newAnnualInterestRate
        );

        LatestBatchData memory batch = troveManager.getLatestBatchData(msg.sender);
        _requireBatchInterestRateChangePeriodPassed(
            msg.sender,
            uint256(batch.lastInterestRateAdjTime)
        );

        uint256 newDebt = batch.entireDebtWithoutRedistribution;

        TroveChange memory batchChange;
        batchChange.batchAccruedManagementFee = batch.accruedManagementFee;
        batchChange.oldWeightedRecordedDebt = batch.weightedRecordedDebt;
        batchChange.newWeightedRecordedDebt = newDebt * _newAnnualInterestRate;
        batchChange.oldWeightedRecordedBatchManagementFee = batch
            .weightedRecordedBatchManagementFee;
        batchChange.newWeightedRecordedBatchManagementFee =
            newDebt *
            batch.annualManagementFee;

        // Apply upfront fee on premature adjustments
        if (
            batch.annualInterestRate != _newAnnualInterestRate &&
            block.timestamp <
            batch.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN
        ) {
            (uint256 price, ) = priceFeed.fetchPrice();

            uint256 avgInterestRate = activePool
                .getNewApproxAvgInterestRateFromTroveChange(batchChange);
            batchChange.upfrontFee = _calcUpfrontFee(newDebt, avgInterestRate);
            _requireUserAcceptsUpfrontFee(
                batchChange.upfrontFee,
                _maxUpfrontFee
            );

            newDebt += batchChange.upfrontFee;

            // Recalculate the batch's weighted terms, now taking into account the upfront fee
            batchChange.newWeightedRecordedDebt =
                newDebt *
                _newAnnualInterestRate;
            batchChange.newWeightedRecordedBatchManagementFee =
                newDebt *
                batch.annualManagementFee;

            // Disallow a premature adjustment if it would result in TCR < CCR
            uint256 newTCR = _getNewTCRFromTroveChange(batchChange, price);
            _requireNewTCRisAboveCCR(newTCR);
        }

        activePool.mintAggInterestAndAccountForTroveChange(
            batchChange,
            msg.sender
        );

        // Check batch is not empty, and then reinsert in sorted list
        if (!sortedTroves.isEmptyBatch(BatchId.wrap(msg.sender))) {
            sortedTroves.reInsertBatch(
                BatchId.wrap(msg.sender),
                _newAnnualInterestRate,
                _upperHint,
                _lowerHint
            );
        }

        troveManager.onSetBatchManagerAnnualInterestRate(
            msg.sender,
            batch.entireCollWithoutRedistribution,
            newDebt,
            _newAnnualInterestRate,
            batchChange.upfrontFee
        );
    }

    function setInterestBatchManager(
        uint256 _troveId,
        address _newBatchManager,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {
        _requireIsNotShutDown();
        LocalVariables_setInterestBatchManager memory vars;
        vars.troveManager = troveManager;
        vars.activePool = activePool;
        vars.sortedTroves = sortedTroves;

        _requireTroveIsActive(vars.troveManager, _troveId);
        _requireCallerIsBorrower(_troveId);
        _requireValidInterestBatchManager(_newBatchManager);
        _requireIsNotInBatch(_troveId);

        // Update state in BorrowerOperations
        borrowerOperations.setTroveBatchManager(_troveId, _newBatchManager);

        vars.trove = vars.troveManager.getLatestTroveData(_troveId);
        vars.newBatch = vars.troveManager.getLatestBatchData(_newBatchManager);

        TroveChange memory newBatchTroveChange;
        newBatchTroveChange.appliedRedistBoldDebtGain = vars
            .trove
            .redistBoldDebtGain;
        newBatchTroveChange.appliedRedistCollGain = vars.trove.redistCollGain;
        newBatchTroveChange.batchAccruedManagementFee = vars
            .newBatch
            .accruedManagementFee;
        newBatchTroveChange.oldWeightedRecordedDebt =
            vars.newBatch.weightedRecordedDebt +
            vars.trove.weightedRecordedDebt;
        newBatchTroveChange.newWeightedRecordedDebt =
            (vars.newBatch.entireDebtWithoutRedistribution +
                vars.trove.entireDebt) *
            vars.newBatch.annualInterestRate;

        // An upfront fee is always charged upon joining a batch
        vars.trove.entireDebt = _applyUpfrontFeeViaBorrowerOps(
            _troveId,
            vars.trove.entireColl,
            vars.trove.entireDebt,
            newBatchTroveChange,
            _maxUpfrontFee,
            true
        );

        // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee
        newBatchTroveChange.newWeightedRecordedDebt =
            (vars.newBatch.entireDebtWithoutRedistribution +
                vars.trove.entireDebt) *
            vars.newBatch.annualInterestRate;

        // Add batch fees
        newBatchTroveChange.oldWeightedRecordedBatchManagementFee = vars
            .newBatch
            .weightedRecordedBatchManagementFee;
        newBatchTroveChange.newWeightedRecordedBatchManagementFee =
            (vars.newBatch.entireDebtWithoutRedistribution +
                vars.trove.entireDebt) *
            vars.newBatch.annualManagementFee;
        vars.activePool.mintAggInterestAndAccountForTroveChange(
            newBatchTroveChange,
            _newBatchManager
        );

        vars.troveManager.onSetInterestBatchManager(
            ITroveManager.OnSetInterestBatchManagerParams({
                troveId: _troveId,
                troveColl: vars.trove.entireColl,
                troveDebt: vars.trove.entireDebt,
                troveChange: newBatchTroveChange,
                newBatchAddress: _newBatchManager,
                newBatchColl: vars.newBatch.entireCollWithoutRedistribution,
                newBatchDebt: vars.newBatch.entireDebtWithoutRedistribution
            })
        );

        vars.sortedTroves.remove(_troveId);
        vars.sortedTroves.insertIntoBatch(
            _troveId,
            BatchId.wrap(_newBatchManager),
            vars.newBatch.annualInterestRate,
            _upperHint,
            _lowerHint
        );
    }

    function removeFromBatch(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {
        _removeFromBatchInternal(
            _troveId,
            _newAnnualInterestRate,
            _upperHint,
            _lowerHint,
            _maxUpfrontFee,
            false
        );
    }

    function kickFromBatch(
        uint256 _troveId,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external {
        _removeFromBatchInternal(
            _troveId,
            0, // ignored when kicking
            _upperHint,
            _lowerHint,
            0, // will use the batch's existing interest rate, so no fee
            true
        );
    }

    function _removeFromBatchInternal(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee,
        bool _kick
    ) internal {
        _requireIsNotShutDown();

        LocalVariables_removeFromBatch memory vars;
        vars.troveManager = troveManager;
        vars.sortedTroves = sortedTroves;

        if (_kick) {
            _requireTroveIsOpen(vars.troveManager, _troveId);
        } else {
            _requireTroveIsActive(vars.troveManager, _troveId);
            _requireCallerIsBorrower(_troveId);
            _requireValidAnnualInterestRate(_newAnnualInterestRate);
        }

        vars.batchManager = _requireIsInBatch(_troveId);
        vars.trove = vars.troveManager.getLatestTroveData(_troveId);
        vars.batch = vars.troveManager.getLatestBatchData(vars.batchManager);

        if (_kick) {
            if (
                vars.batch.totalDebtShares * MAX_BATCH_SHARES_RATIO >=
                vars.batch.entireDebtWithoutRedistribution
            ) {
                revert BatchSharesRatioTooLow();
            }
            _newAnnualInterestRate = vars.batch.annualInterestRate;
        }

        // Update state in BorrowerOperations
        borrowerOperations.removeTroveFromBatch(_troveId);

        if (!_checkTroveIsZombie(vars.troveManager, _troveId)) {
            // Remove trove from Batch in SortedTroves
            vars.sortedTroves.removeFromBatch(_troveId);
            // Reinsert as single trove
            vars.sortedTroves.insert(
                _troveId,
                _newAnnualInterestRate,
                _upperHint,
                _lowerHint
            );
        }

        vars.batchFutureDebt =
            vars.batch.entireDebtWithoutRedistribution -
            (vars.trove.entireDebt - vars.trove.redistBoldDebtGain);

        vars.batchChange.appliedRedistBoldDebtGain = vars
            .trove
            .redistBoldDebtGain;
        vars.batchChange.appliedRedistCollGain = vars.trove.redistCollGain;
        vars.batchChange.batchAccruedManagementFee = vars
            .batch
            .accruedManagementFee;
        vars.batchChange.oldWeightedRecordedDebt = vars
            .batch
            .weightedRecordedDebt;
        vars.batchChange.newWeightedRecordedDebt =
            vars.batchFutureDebt *
            vars.batch.annualInterestRate +
            vars.trove.entireDebt *
            _newAnnualInterestRate;

        // Apply upfront fee on premature adjustments
        if (
            vars.batch.annualInterestRate != _newAnnualInterestRate &&
            block.timestamp <
            vars.trove.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN
        ) {
            vars.trove.entireDebt = _applyUpfrontFeeViaBorrowerOps(
                _troveId,
                vars.trove.entireColl,
                vars.trove.entireDebt,
                vars.batchChange,
                _maxUpfrontFee,
                false
            );
        }

        // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee
        vars.batchChange.newWeightedRecordedDebt =
            vars.batchFutureDebt *
            vars.batch.annualInterestRate +
            vars.trove.entireDebt *
            _newAnnualInterestRate;
        // Add batch fees
        vars.batchChange.oldWeightedRecordedBatchManagementFee = vars
            .batch
            .weightedRecordedBatchManagementFee;
        vars.batchChange.newWeightedRecordedBatchManagementFee =
            vars.batchFutureDebt *
            vars.batch.annualManagementFee;

        activePool.mintAggInterestAndAccountForTroveChange(
            vars.batchChange,
            vars.batchManager
        );

        vars.troveManager.onRemoveFromBatch(
            _troveId,
            vars.trove.entireColl,
            vars.trove.entireDebt,
            vars.batchChange,
            vars.batchManager,
            vars.batch.entireCollWithoutRedistribution,
            vars.batch.entireDebtWithoutRedistribution,
            _newAnnualInterestRate
        );
    }

    // --- Helper Functions ---

    function _calcUpfrontFee(
        uint256 _debt,
        uint256 _avgInterestRate
    ) internal pure returns (uint256) {
        return _calcInterest(_debt * _avgInterestRate, UPFRONT_INTEREST_PERIOD);
    }

    function _getNewTCRFromTroveChange(
        TroveChange memory _troveChange,
        uint256 _price
    ) internal view returns (uint256 newTCR) {
        uint256 totalColl = getEntireBranchColl();
        totalColl += _troveChange.collIncrease;
        totalColl -= _troveChange.collDecrease;

        uint256 totalDebt = getEntireBranchDebt();
        totalDebt += _troveChange.debtIncrease;
        totalDebt += _troveChange.upfrontFee;
        totalDebt -= _troveChange.debtDecrease;

        newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price);
    }

    function _applyUpfrontFeeViaBorrowerOps(
        uint256 _troveId,
        uint256 _troveEntireColl,
        uint256 _troveEntireDebt,
        TroveChange memory _troveChange,
        uint256 _maxUpfrontFee,
        bool _isTroveInBatch
    ) internal returns (uint256) {
        // Delegate to BorrowerOperations for this calculation
        return borrowerOperations.applyUpfrontFee(
            _troveId,
            _troveEntireColl,
            _troveEntireDebt,
            _troveChange,
            _maxUpfrontFee,
            _isTroveInBatch
        );
    }

    function _checkTroveIsZombie(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view returns (bool) {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        return status == ITroveManager.Status.zombie;
    }

    // --- Validation Functions ---

    function _requireIsNotShutDown() internal view {
        if (borrowerOperations.hasBeenShutDown()) {
            revert IsShutDown();
        }
    }

    function _requireValidAnnualInterestRate(
        uint256 _annualInterestRate
    ) internal view {
        if (_annualInterestRate < systemParams.MIN_ANNUAL_INTEREST_RATE()) {
            revert InterestRateTooLow();
        }
        if (_annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert InterestRateTooHigh();
        }
    }

    function _requireOrderedRange(
        uint256 _minInterestRate,
        uint256 _maxInterestRate
    ) internal pure {
        if (_minInterestRate >= _maxInterestRate) revert MinGeMax();
    }

    function _requireInterestRateInRange(
        uint256 _annualInterestRate,
        uint256 _minInterestRate,
        uint256 _maxInterestRate
    ) internal pure {
        if (
            _minInterestRate > _annualInterestRate ||
            _annualInterestRate > _maxInterestRate
        ) {
            revert InterestNotInRange();
        }
    }

    function _requireInterestRateInBatchManagerRange(
        address _interestBatchManagerAddress,
        uint256 _annualInterestRate
    ) internal view {
        IBorrowerOperations.InterestBatchManager
            memory interestBatchManager = borrowerOperations.getInterestBatchManager(_interestBatchManagerAddress);
        _requireInterestRateInRange(
            _annualInterestRate,
            interestBatchManager.minInterestRate,
            interestBatchManager.maxInterestRate
        );
    }

    function _requireBatchInterestRateChangePeriodPassed(
        address _interestBatchManagerAddress,
        uint256 _lastInterestRateAdjTime
    ) internal view {
        IBorrowerOperations.InterestBatchManager
            memory interestBatchManager = borrowerOperations.getInterestBatchManager(_interestBatchManagerAddress);
        if (
            block.timestamp <
            _lastInterestRateAdjTime +
                uint256(interestBatchManager.minInterestRateChangePeriod)
        ) {
            revert BatchInterestRateChangePeriodNotPassed();
        }
    }

    function _requireValidInterestBatchManager(
        address _interestBatchManagerAddress
    ) internal view {
        if (!borrowerOperations.checkBatchManagerExists(_interestBatchManagerAddress)) {
            revert InvalidInterestBatchManager();
        }
    }

    function _requireNonExistentInterestBatchManager(
        address _interestBatchManagerAddress
    ) internal view {
        if (borrowerOperations.checkBatchManagerExists(_interestBatchManagerAddress)) {
            revert BatchManagerExists();
        }
    }

    function _requireUserAcceptsUpfrontFee(
        uint256 _fee,
        uint256 _maxFee
    ) internal pure {
        if (_fee > _maxFee) {
            revert UpfrontFeeTooHigh();
        }
    }

    function _requireNewTCRisAboveCCR(uint256 _newTCR) internal view {
        if (_newTCR < systemParams.CCR()) {
            revert TCRBelowCCR();
        }
    }

    function _requireTroveIsActive(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.active) {
            revert TroveNotActive();
        }
    }

    function _requireTroveIsOpen(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (
            status != ITroveManager.Status.active &&
            status != ITroveManager.Status.zombie
        ) {
            revert TroveNotOpen();
        }
    }

    function _requireCallerIsBorrower(uint256 _troveId) internal view {
        if (msg.sender != troveNFT.ownerOf(_troveId)) {
            revert NotBorrower();
        }
    }

    function _requireIsNotInBatch(uint256 _troveId) internal view {
        if (borrowerOperations.interestBatchManagerOf(_troveId) != address(0)) {
            revert();
        }
    }

    function _requireIsInBatch(
        uint256 _troveId
    ) internal view returns (address) {
        address batchManager = borrowerOperations.interestBatchManagerOf(_troveId);
        if (batchManager == address(0)) {
            revert TroveNotInBatch();
        }
        return batchManager;
    }
}
