import { Address, BigInt, Bytes, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { InterestBatch, InterestRateBracket, Trove, TroveOperation } from "../generated/schema";
import {
  BatchedTroveUpdated as BatchedTroveUpdatedEvent,
  BatchUpdated as BatchUpdatedEvent,
  TroveOperation as TroveOperationEvent,
  TroveUpdated as TroveUpdatedEvent,
} from "../generated/templates/TroveManager/TroveManager";

// see Operation enum in
// contracts/src/Interfaces/ITroveEvents.sol
//
const OP_OPEN_TROVE = 0;
const OP_CLOSE_TROVE = 1;
const OP_ADJUST_TROVE = 2;
const OP_ADJUST_TROVE_INTEREST_RATE = 3;
const OP_APPLY_PENDING_DEBT = 4;
const OP_LIQUIDATE = 5;
const OP_REDEEM_COLLATERAL = 6;
const OP_OPEN_TROVE_AND_JOIN_BATCH = 7;
const OP_SET_INTEREST_BATCH_MANAGER = 8;
const OP_REMOVE_FROM_BATCH = 9;

const FLASH_LOAN_TOPIC = Bytes.fromHexString(
  // keccak256("FlashLoan(address,address,uint256,uint256)")
  "0x0d7d75e01ab95780d3cd1c8ec0dd6c2ce19e3a20427eec8bf53283b6fb8e95f0",
);

const REDEMPTION_TOPIC = Bytes.fromHexString(
  // keccak256("Redemption(uint256,uint256,uint256,uint256,uint256,uint256)")
  "0x84ec8e1674d62e3a8ff294b1a7f53527d2d10291765fadf94e0ce431b2334334",
);

const LIQUIDATION_TOPIC = Bytes.fromHexString(
  // keccak256("Liquidation(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)")
  "0x7243af9a1cff94d3429b2ee00b78c1c10589259f20dc167cb67704f38f9e824e",
);

function decodeAddress(data: Bytes, i: i32 = 0): ethereum.Value {
  return ethereum.Value.fromAddress(
    Address.fromBytes(
      Bytes.fromUint8Array(
        data.subarray(i * 32 + 12, i * 32 + 32),
      ),
    ),
  );
}

function decodeUint8(data: Bytes, i: i32 = 0): ethereum.Value {
  return ethereum.Value.fromI32(
    data[i * 32 + 31],
  );
}

function decodeUint256(data: Bytes, i: i32 = 0): ethereum.Value {
  return ethereum.Value.fromUnsignedBigInt(
    BigInt.fromUnsignedBytes(
      Bytes.fromUint8Array(
        data.subarray(i * 32, i * 32 + 32).reverse(),
      ),
    ),
  );
}

function getBatchUpdatedEventFrom(batchedTroveUpdatedEvent: BatchedTroveUpdatedEvent): BatchUpdatedEvent {
  let receipt = batchedTroveUpdatedEvent.receipt;

  if (!receipt) {
    throw new Error("Missing TX receipt");
  }

  let batchUpdatedLogIndex = -1;

  for (let i = 0; i < receipt.logs.length; ++i) {
    if (receipt.logs[i].logIndex.equals(batchedTroveUpdatedEvent.logIndex.plus(BigInt.fromI32(2)))) {
      batchUpdatedLogIndex = i;
      break;
    }
  }

  if (batchUpdatedLogIndex < 0) {
    throw new Error("Missing BatchUpdated log");
  }

  let batchUpdatedLog = receipt.logs[batchUpdatedLogIndex];

  return new BatchUpdatedEvent(
    batchUpdatedLog.address,
    batchUpdatedLog.logIndex,
    batchUpdatedLog.transactionLogIndex,
    batchUpdatedLog.logType,
    batchedTroveUpdatedEvent.block,
    batchedTroveUpdatedEvent.transaction,
    [
      new ethereum.EventParam("_interestBatchManager", decodeAddress(batchUpdatedLog.topics[1])),
      new ethereum.EventParam("_operation", decodeUint8(batchUpdatedLog.data, 0)),
      new ethereum.EventParam("_debt", decodeUint256(batchUpdatedLog.data, 1)),
      new ethereum.EventParam("_coll", decodeUint256(batchUpdatedLog.data, 2)),
      new ethereum.EventParam("_annualInterestRate", decodeUint256(batchUpdatedLog.data, 3)),
      new ethereum.EventParam("_annualManagementFee", decodeUint256(batchUpdatedLog.data, 4)),
      new ethereum.EventParam("_totalDebtShares", decodeUint256(batchUpdatedLog.data, 5)),
      new ethereum.EventParam("_debtIncreaseFromUpfrontFee", decodeUint256(batchUpdatedLog.data, 6)),
    ],
    batchedTroveUpdatedEvent.receipt,
  );
}

export function handleTroveUpdated(event: TroveUpdatedEvent): void {
  let collId = dataSource.context().getString("collId");
  let troveId = event.params._troveId;
  let troveFullId = collId + ":" + troveId.toHexString();
  let trove = Trove.load(troveFullId);

  if (!trove) {
    throw new Error("Trove not found: " + troveFullId);
  }

  updateRateBracketDebt(
    collId,
    trove.interestRate,
    event.params._annualInterestRate,
    trove.debt,
    event.params._debt,
    trove.updatedAt,
    event.block.timestamp,
  );

  trove.debt = event.params._debt;
  trove.deposit = event.params._coll;
  trove.stake = event.params._stake;
  trove.interestRate = event.params._annualInterestRate;
  trove.interestBatch = null;
  trove.updatedAt = event.block.timestamp;
  trove.save();
}

export function handleBatchedTroveUpdated(batchedTroveUpdatedEvent: BatchedTroveUpdatedEvent): void {
  let batchUpdatedEvent = getBatchUpdatedEventFrom(batchedTroveUpdatedEvent);
  let collId = dataSource.context().getString("collId");
  let troveId = batchedTroveUpdatedEvent.params._troveId;
  let troveFullId = collId + ":" + troveId.toHexString();
  let trove = Trove.load(troveFullId);

  if (!trove) {
    throw new Error("Trove not found: " + troveFullId);
  }

  updateRateBracketDebt(
    collId,
    trove.interestRate,
    BigInt.zero(),
    trove.debt,
    BigInt.zero(), // batched debt handled at batch level
    trove.updatedAt,
    batchedTroveUpdatedEvent.block.timestamp,
  );

  trove.debt = batchUpdatedEvent.params._totalDebtShares.notEqual(BigInt.zero())
    ? batchUpdatedEvent.params._debt
      .times(batchedTroveUpdatedEvent.params._batchDebtShares)
      .div(batchUpdatedEvent.params._totalDebtShares)
    : BigInt.zero();
  trove.deposit = batchedTroveUpdatedEvent.params._coll;
  trove.stake = batchedTroveUpdatedEvent.params._stake;
  trove.interestRate = BigInt.zero();
  trove.interestBatch = collId + ":" + batchedTroveUpdatedEvent.params._interestBatchManager.toHexString();
  trove.updatedAt = batchedTroveUpdatedEvent.block.timestamp;
  trove.save();
}

export function handleTroveOperation(event: TroveOperationEvent): void {
  let collId = dataSource.context().getString("collId");
  let troveId = event.params._troveId;
  let troveFullId = collId + ":" + troveId.toHexString();
  let trove = Trove.load(troveFullId);

  if (!trove) {
    throw new Error("Trove not found: " + troveFullId);
  }

  let operation = event.params._operation;
  let timestamp = event.block.timestamp;

  // Opening
  if (operation === OP_OPEN_TROVE || operation === OP_OPEN_TROVE_AND_JOIN_BATCH) {
    trove.createdAt = timestamp;
  }

  // Closing
  if (operation === OP_CLOSE_TROVE || operation === OP_LIQUIDATE) {
    trove.closedAt = timestamp;
  }

  // User action
  if (operation !== OP_REDEEM_COLLATERAL && operation !== OP_LIQUIDATE && operation !== OP_APPLY_PENDING_DEBT) {
    trove.lastUserActionAt = timestamp;
    trove.redemptionCount = 0;
    trove.redeemedColl = BigInt.zero();
    trove.redeemedDebt = BigInt.zero();
    trove.status = operation === OP_CLOSE_TROVE ? "closed" : "active";
  }

  // Redemption
  if (operation === OP_REDEEM_COLLATERAL) {
    trove.status = "redeemed";
    trove.redemptionCount += 1;
    // increasing redemption accumulators by subtracting negative amounts
    trove.redeemedColl = trove.redeemedColl.minus(event.params._collChangeFromOperation);
    trove.redeemedDebt = trove.redeemedDebt.minus(event.params._debtChangeFromOperation);
  }

  // Liquidation
  if (operation === OP_LIQUIDATE) {
    trove.status = "liquidated";
  }

  // Infer leverage flag on opening & adjustment
  if (operation === OP_OPEN_TROVE || operation === OP_OPEN_TROVE_AND_JOIN_BATCH || operation === OP_ADJUST_TROVE) {
    trove.mightBeLeveraged = inferLeverage(event);
  }

  trove.save();

  recordTroveOperation(event, trove);
}

// Writes one immutable TroveOperation history row per event. The preceding
// TroveUpdated / BatchedTroveUpdated handlers have already moved `trove` to
// its post-op state, so trove.debt / trove.deposit / trove.interestRate /
// trove.interestBatch can be used directly as the snapshot.
function recordTroveOperation(event: TroveOperationEvent, trove: Trove): void {
  let op = new TroveOperation(
    event.transaction.hash.concatI32(event.logIndex.toI32()),
  );
  op.trove = trove.id;
  op.blockNumber = event.block.number;
  op.timestamp = event.block.timestamp;
  op.transactionHash = event.transaction.hash;
  op.logIndex = event.logIndex;
  op.operation = troveOperationKind(event.params._operation);
  op.initiator = event.transaction.from;
  op.collateralDelta = event.params._collChangeFromOperation;
  op.debtDelta = event.params._debtChangeFromOperation;
  op.newCollateral = trove.deposit;
  op.newDebt = trove.debt;
  op.newInterestRate = event.params._annualInterestRate;
  op.collIncreaseFromRedist = event.params._collIncreaseFromRedist;
  op.debtIncreaseFromRedist = event.params._debtIncreaseFromRedist;
  op.upfrontFee = event.params._debtIncreaseFromUpfrontFee;
  op.batch = trove.interestBatch;

  let kind = event.params._operation;
  if (kind === OP_REDEEM_COLLATERAL) {
    op.redemptionPrice = extractRedemptionPrice(event);
  } else if (kind === OP_LIQUIDATE) {
    op.liquidationPrice = extractLiquidationPrice(event);
  }

  op.save();
}

function troveOperationKind(opIndex: i32): string {
  // Order must match ITroveEvents.Operation and the TroveOperationKind enum
  // in schema.graphql.
  if (opIndex === OP_OPEN_TROVE) return "openTrove";
  if (opIndex === OP_CLOSE_TROVE) return "closeTrove";
  if (opIndex === OP_ADJUST_TROVE) return "adjustTrove";
  if (opIndex === OP_ADJUST_TROVE_INTEREST_RATE) return "adjustTroveInterestRate";
  if (opIndex === OP_APPLY_PENDING_DEBT) return "applyPendingDebt";
  if (opIndex === OP_LIQUIDATE) return "liquidate";
  if (opIndex === OP_REDEEM_COLLATERAL) return "redeemCollateral";
  if (opIndex === OP_OPEN_TROVE_AND_JOIN_BATCH) return "openTroveAndJoinBatch";
  if (opIndex === OP_SET_INTEREST_BATCH_MANAGER) return "setInterestBatchManager";
  if (opIndex === OP_REMOVE_FROM_BATCH) return "removeFromBatch";
  throw new Error("Unknown TroveOperation kind: " + opIndex.toString());
}

// Decode the Nth uint256 from a non-indexed event's data blob. ABI lays
// non-indexed args out as packed 32-byte words in order.
function decodeUint256At(data: Bytes, wordIndex: i32): BigInt {
  return BigInt.fromUnsignedBytes(
    Bytes.fromUint8Array(
      data.subarray(wordIndex * 32, wordIndex * 32 + 32).reverse(),
    ),
  );
}

// Redemption and Liquidation are emitted from the TroveManager that did the
// redemption / liquidation. Each Mento V3 branch (GBPm/CHFm/JPYm) has its own
// TroveManager emitting its own branch-priced events, so we must match the
// log's address to the TroveManager that emitted this TroveOperation —
// otherwise a tx touching multiple branches would attach the wrong branch's
// price.
function extractRedemptionPrice(event: TroveOperationEvent): BigInt | null {
  let receipt = event.receipt;
  if (!receipt) return null;

  for (let i = 0; i < receipt.logs.length; ++i) {
    let log = receipt.logs[i];
    if (
      log.address.equals(event.address)
      && log.topics.length > 0
      && log.topics[0].equals(REDEMPTION_TOPIC)
    ) {
      // Redemption(_attemptedBoldAmount, _actualBoldAmount, _ETHSent, _ETHFee,
      //            _price, _redemptionPrice) — _redemptionPrice is word 5.
      return decodeUint256At(log.data, 5);
    }
  }
  return null;
}

function extractLiquidationPrice(event: TroveOperationEvent): BigInt | null {
  let receipt = event.receipt;
  if (!receipt) return null;

  for (let i = 0; i < receipt.logs.length; ++i) {
    let log = receipt.logs[i];
    if (
      log.address.equals(event.address)
      && log.topics.length > 0
      && log.topics[0].equals(LIQUIDATION_TOPIC)
    ) {
      // Liquidation(_debtOffsetBySP, _debtRedistributed, _boldGasCompensation,
      //             _collGasCompensation, _collSentToSP, _collRedistributed,
      //             _collSurplus, _L_ETH, _L_boldDebt, _price)
      // _price is word 9.
      return decodeUint256At(log.data, 9);
    }
  }
  return null;
}

function inferLeverage(event: TroveOperationEvent): boolean {
  let receipt = event.receipt;

  if (!receipt) {
    throw new Error("Missing TX receipt");
  }

  return !!receipt.logs.some(
    (log) => (
      log.topics.length > 0
      && log.topics[0].equals(FLASH_LOAN_TOPIC)
    ),
  );
}

function floorToDecimals(value: BigInt, decimals: u8): BigInt {
  let factor = BigInt.fromI32(10).pow(18 - decimals);
  return value.div(factor).times(factor);
}

function getRateFloored(rate: BigInt): BigInt {
  return floorToDecimals(rate, 3);
}

function updateRateBracketDebt(
  collId: string,
  prevRate: BigInt,
  newRate: BigInt,
  prevDebt: BigInt,
  newDebt: BigInt,
  prevTime: BigInt,
  newTime: BigInt,
): void {
  let rateBracket: InterestRateBracket | null = null;

  // remove debt from prev bracket
  if (prevRate.notEqual(BigInt.zero())) {
    let rateFloored = getRateFloored(prevRate);
    let rateBracketId = collId + ":" + rateFloored.toString();

    if (!(rateBracket = InterestRateBracket.load(rateBracketId))) {
      throw new Error("InterestRateBracket not found: " + rateBracketId);
    }

    rateBracket.totalDebt = rateBracket.totalDebt
      .minus(prevDebt);
    rateBracket.pendingDebtTimesOneYearD36 = rateBracket.pendingDebtTimesOneYearD36
      .plus(newTime.minus(rateBracket.updatedAt).times(rateBracket.sumDebtTimesRateD36))
      .minus(newTime.minus(prevTime).times(prevDebt).times(prevRate));
    rateBracket.sumDebtTimesRateD36 = rateBracket.sumDebtTimesRateD36
      .minus(prevDebt.times(prevRate));
    rateBracket.updatedAt = newTime;
  }

  // add debt to new bracket
  if (newRate.notEqual(BigInt.zero())) {
    let rateFloored = getRateFloored(newRate);
    let rateBracketId = collId + ":" + rateFloored.toString();

    if (!rateBracket || rateBracket.id !== rateBracketId) {
      if (rateBracket) rateBracket.save();

      if (!(rateBracket = InterestRateBracket.load(rateBracketId))) {
        rateBracket = new InterestRateBracket(rateBracketId);
        rateBracket.collateral = collId;
        rateBracket.rate = rateFloored;
        rateBracket.totalDebt = BigInt.zero();
        rateBracket.sumDebtTimesRateD36 = BigInt.zero();
        rateBracket.pendingDebtTimesOneYearD36 = BigInt.zero();
        rateBracket.updatedAt = newTime;
      }
    }

    rateBracket.totalDebt = rateBracket.totalDebt
      .plus(newDebt);
    rateBracket.pendingDebtTimesOneYearD36 = rateBracket.pendingDebtTimesOneYearD36
      .plus(newTime.minus(rateBracket.updatedAt).times(rateBracket.sumDebtTimesRateD36));
    rateBracket.sumDebtTimesRateD36 = rateBracket.sumDebtTimesRateD36
      .plus(newDebt.times(newRate));
    rateBracket.updatedAt = newTime;
  }

  if (rateBracket) rateBracket.save();
}

export function handleBatchUpdated(event: BatchUpdatedEvent): void {
  let collId = dataSource.context().getString("collId");
  let batchId = collId + ":" + event.params._interestBatchManager.toHexString();
  let batch = InterestBatch.load(batchId);

  if (!batch) {
    batch = new InterestBatch(batchId);
    batch.collateral = collId;
    batch.batchManager = event.params._interestBatchManager;
    batch.annualInterestRate = BigInt.zero();
    batch.debt = BigInt.zero();
    batch.updatedAt = event.block.timestamp;
  }

  updateRateBracketDebt(
    collId,
    batch.annualInterestRate,
    event.params._annualInterestRate,
    batch.debt,
    event.params._debt,
    batch.updatedAt,
    event.block.timestamp,
  );

  batch.debt = event.params._debt;
  batch.coll = event.params._coll;
  batch.annualInterestRate = event.params._annualInterestRate;
  batch.annualManagementFee = event.params._annualManagementFee;
  batch.updatedAt = event.block.timestamp;
  batch.save();
}
