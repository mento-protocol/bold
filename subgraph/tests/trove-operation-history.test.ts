import { Address, BigInt, Bytes, DataSourceContext, ethereum } from "@graphprotocol/graph-ts";
import {
  afterEach,
  assert,
  beforeEach,
  clearStore,
  dataSourceMock,
  describe,
  newMockEvent,
  test,
} from "matchstick-as/assembly/index";
import { Trove } from "../generated/schema";
import { TroveOperation as TroveOperationEvent } from "../generated/templates/TroveManager/TroveManager";
import { handleTroveOperation } from "../src/TroveManager.mapping";

const COLL_ID = "0";
const TROVE_ID = BigInt.fromI32(1);
const TROVE_FULL_ID = COLL_ID + ":" + TROVE_ID.toHexString();

const REDEMPTION_TOPIC = Bytes.fromHexString(
  "0x84ec8e1674d62e3a8ff294b1a7f53527d2d10291765fadf94e0ce431b2334334",
);

const LIQUIDATION_TOPIC = Bytes.fromHexString(
  "0x7243af9a1cff94d3429b2ee00b78c1c10589259f20dc167cb67704f38f9e824e",
);

function createTrove(debt: BigInt, deposit: BigInt, interestRate: BigInt): Trove {
  let trove = new Trove(TROVE_FULL_ID);
  trove.borrower = Address.zero();
  trove.collateral = COLL_ID;
  trove.createdAt = BigInt.fromI32(1_700_000_000);
  trove.updatedAt = BigInt.fromI32(1_700_000_000);
  trove.lastUserActionAt = BigInt.fromI32(1_700_000_000);
  trove.mightBeLeveraged = false;
  trove.status = "active";
  trove.debt = debt;
  trove.deposit = deposit;
  trove.stake = deposit;
  trove.interestRate = interestRate;
  trove.troveId = TROVE_ID.toHexString();
  trove.previousOwner = Address.zero();
  trove.redemptionCount = 0;
  trove.redeemedColl = BigInt.zero();
  trove.redeemedDebt = BigInt.zero();
  trove.save();
  return trove;
}

// ABI-encode a sequence of uint256 values into a single big-endian byte
// blob: each value becomes one 32-byte left-padded word. Mirrors what
// solidity emits as the non-indexed `data` of an event with N uint256
// args. Used to build synthetic Redemption / Liquidation logs.
function packUint256s(values: BigInt[]): Bytes {
  let hex = "0x";
  for (let i = 0; i < values.length; i++) {
    let h = values[i].toHexString().slice(2); // strip "0x"
    while (h.length < 64) h = "0" + h;
    hex += h;
  }
  return Bytes.fromHexString(hex);
}

function buildReceiptWithLog(
  event: TroveOperationEvent,
  topic: Bytes,
  data: Bytes,
): ethereum.TransactionReceipt {
  // The mapping filters receipt logs by `log.address.equals(event.address)`,
  // so the synthetic log must claim to come from the same TroveManager that
  // emitted the TroveOperation. event.address is the matchstick default
  // address (0xA160...eC2A) unless overridden.
  let log = new ethereum.Log(
    event.address,
    [topic],
    data,
    event.block.hash,
    Bytes.fromUint8Array(new Uint8Array(0)),
    event.transaction.hash,
    BigInt.zero(),
    BigInt.zero(),
    BigInt.zero(),
    "default",
    null,
  );
  return new ethereum.TransactionReceipt(
    event.transaction.hash,
    BigInt.zero(),
    event.block.hash,
    event.block.number,
    BigInt.zero(),
    BigInt.zero(),
    Address.zero(),
    [log],
    BigInt.fromI32(1),
    Bytes.empty(),
    Bytes.empty(),
  );
}

function newTroveOperationEvent(
  operationKind: i32,
  annualInterestRate: BigInt,
  debtIncreaseFromRedist: BigInt,
  debtIncreaseFromUpfrontFee: BigInt,
  debtChangeFromOperation: BigInt,
  collIncreaseFromRedist: BigInt,
  collChangeFromOperation: BigInt,
): TroveOperationEvent {
  let event = changetype<TroveOperationEvent>(newMockEvent());
  event.parameters = new Array<ethereum.EventParam>();
  event.parameters.push(new ethereum.EventParam(
    "_troveId",
    ethereum.Value.fromUnsignedBigInt(TROVE_ID),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_operation",
    ethereum.Value.fromI32(operationKind),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_annualInterestRate",
    ethereum.Value.fromUnsignedBigInt(annualInterestRate),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_debtIncreaseFromRedist",
    ethereum.Value.fromUnsignedBigInt(debtIncreaseFromRedist),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_debtIncreaseFromUpfrontFee",
    ethereum.Value.fromUnsignedBigInt(debtIncreaseFromUpfrontFee),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_debtChangeFromOperation",
    ethereum.Value.fromSignedBigInt(debtChangeFromOperation),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_collIncreaseFromRedist",
    ethereum.Value.fromUnsignedBigInt(collIncreaseFromRedist),
  ));
  event.parameters.push(new ethereum.EventParam(
    "_collChangeFromOperation",
    ethereum.Value.fromSignedBigInt(collChangeFromOperation),
  ));
  event.block.timestamp = BigInt.fromI32(1_700_001_000);
  event.block.number = BigInt.fromI32(100);
  return event;
}

describe("handleTroveOperation history rows", () => {
  beforeEach(() => {
    let ctx = new DataSourceContext();
    ctx.setString("collId", COLL_ID);
    dataSourceMock.setContext(ctx);
  });

  afterEach(() => {
    clearStore();
    dataSourceMock.resetValues();
  });

  test("adjustTroveInterestRate writes a history row with post-state snapshot", () => {
    // Simulate the post-state that handleTroveUpdated would have left.
    let postDebt = BigInt.fromString("1000000000000000000000"); // 1000e18
    let postColl = BigInt.fromString("2000000000000000000000"); // 2000e18
    let postRate = BigInt.fromString("60000000000000000"); // 6%
    createTrove(postDebt, postColl, postRate);

    let event = newTroveOperationEvent(
      3, // adjustTroveInterestRate
      postRate,
      BigInt.zero(),
      BigInt.zero(),
      BigInt.zero(),
      BigInt.zero(),
      BigInt.zero(),
    );
    handleTroveOperation(event);

    assert.entityCount("TroveOperation", 1);
    let opId = event.transaction.hash.concatI32(event.logIndex.toI32()).toHexString();
    assert.fieldEquals("TroveOperation", opId, "operation", "adjustTroveInterestRate");
    assert.fieldEquals("TroveOperation", opId, "trove", TROVE_FULL_ID);
    assert.fieldEquals("TroveOperation", opId, "newDebt", postDebt.toString());
    assert.fieldEquals("TroveOperation", opId, "newCollateral", postColl.toString());
    assert.fieldEquals("TroveOperation", opId, "newInterestRate", postRate.toString());
    assert.fieldEquals("TroveOperation", opId, "collateralDelta", "0");
    assert.fieldEquals("TroveOperation", opId, "debtDelta", "0");
  });

  test("applyPendingDebt records redistribution gains without zeroing user state", () => {
    let postDebt = BigInt.fromString("1100000000000000000000");
    let postColl = BigInt.fromString("2050000000000000000000");
    let postRate = BigInt.fromString("60000000000000000");
    createTrove(postDebt, postColl, postRate);

    let debtRedist = BigInt.fromString("100000000000000000000"); // +100e18 from redist
    let collRedist = BigInt.fromString("50000000000000000000"); // +50e18 from redist

    let event = newTroveOperationEvent(
      4, // applyPendingDebt
      postRate,
      debtRedist,
      BigInt.zero(),
      BigInt.zero(),
      collRedist,
      BigInt.zero(),
    );
    handleTroveOperation(event);

    let opId = event.transaction.hash.concatI32(event.logIndex.toI32()).toHexString();
    assert.fieldEquals("TroveOperation", opId, "operation", "applyPendingDebt");
    assert.fieldEquals("TroveOperation", opId, "debtIncreaseFromRedist", debtRedist.toString());
    assert.fieldEquals("TroveOperation", opId, "collIncreaseFromRedist", collRedist.toString());
    assert.fieldEquals("TroveOperation", opId, "newDebt", postDebt.toString());
  });

  test("redeemCollateral extracts redemptionPrice from same-tx Redemption log", () => {
    let postDebt = BigInt.fromString("900000000000000000000");
    let postColl = BigInt.fromString("1800000000000000000000");
    let postRate = BigInt.fromString("60000000000000000");
    createTrove(postDebt, postColl, postRate);

    let collChange = BigInt.fromString("-200000000000000000000"); // -200e18 coll
    let debtChange = BigInt.fromString("-100000000000000000000"); // -100e18 debt

    let event = newTroveOperationEvent(
      6, // redeemCollateral
      postRate,
      BigInt.zero(),
      BigInt.zero(),
      debtChange,
      BigInt.zero(),
      collChange,
    );

    // Build a synthetic Redemption log alongside the TroveOperation in the receipt.
    // Redemption(_attemptedBoldAmount, _actualBoldAmount, _ETHSent, _ETHFee, _price, _redemptionPrice)
    let expectedRedemptionPrice = BigInt.fromString("1250000000000000000"); // 1.25
    let redemptionData = packUint256s([
      BigInt.fromI32(100),
      BigInt.fromI32(90),
      BigInt.fromI32(200),
      BigInt.fromI32(5),
      BigInt.fromString("1200000000000000000"),
      expectedRedemptionPrice,
    ]);

    event.receipt = buildReceiptWithLog(event, REDEMPTION_TOPIC, redemptionData);

    handleTroveOperation(event);

    let opId = event.transaction.hash.concatI32(event.logIndex.toI32()).toHexString();
    assert.fieldEquals("TroveOperation", opId, "operation", "redeemCollateral");
    assert.fieldEquals("TroveOperation", opId, "redemptionPrice", expectedRedemptionPrice.toString());
    assert.fieldEquals("TroveOperation", opId, "collateralDelta", collChange.toString());
    assert.fieldEquals("TroveOperation", opId, "debtDelta", debtChange.toString());
  });

  test("redeemCollateral ignores Redemption logs emitted by a different branch's TroveManager", () => {
    let postDebt = BigInt.fromString("900000000000000000000");
    let postColl = BigInt.fromString("1800000000000000000000");
    let postRate = BigInt.fromString("60000000000000000");
    createTrove(postDebt, postColl, postRate);

    let event = newTroveOperationEvent(
      6, // redeemCollateral
      postRate,
      BigInt.zero(),
      BigInt.zero(),
      BigInt.fromString("-100000000000000000000"),
      BigInt.zero(),
      BigInt.fromString("-200000000000000000000"),
    );

    // Stuff a Redemption log from a different TroveManager into the receipt.
    // The filter must reject it; redemptionPrice should remain null.
    let foreignBranchPrice = BigInt.fromString("999000000000000000000");
    let foreignData = packUint256s([
      BigInt.fromI32(1),
      BigInt.fromI32(1),
      BigInt.fromI32(1),
      BigInt.fromI32(1),
      BigInt.fromI32(1),
      foreignBranchPrice,
    ]);
    let foreignAddress = Address.fromString("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    let foreignLog = new ethereum.Log(
      foreignAddress,
      [REDEMPTION_TOPIC],
      foreignData,
      event.block.hash,
      Bytes.fromUint8Array(new Uint8Array(0)),
      event.transaction.hash,
      BigInt.zero(),
      BigInt.zero(),
      BigInt.zero(),
      "default",
      null,
    );
    event.receipt = new ethereum.TransactionReceipt(
      event.transaction.hash,
      BigInt.zero(),
      event.block.hash,
      event.block.number,
      BigInt.zero(),
      BigInt.zero(),
      Address.zero(),
      [foreignLog],
      BigInt.fromI32(1),
      Bytes.empty(),
      Bytes.empty(),
    );

    handleTroveOperation(event);

    let opId = event.transaction.hash.concatI32(event.logIndex.toI32()).toHexString();
    assert.fieldEquals("TroveOperation", opId, "operation", "redeemCollateral");
    // redemptionPrice should be unset (the foreign log was rejected).
    assert.fieldEquals("TroveOperation", opId, "redemptionPrice", "null");
  });

  test("liquidate extracts liquidationPrice from same-tx Liquidation log", () => {
    let postDebt = BigInt.zero();
    let postColl = BigInt.zero();
    let postRate = BigInt.zero();
    createTrove(postDebt, postColl, postRate);

    let event = newTroveOperationEvent(
      5, // liquidate
      BigInt.zero(),
      BigInt.fromString("10000000000000000000"),
      BigInt.zero(),
      BigInt.fromString("-1000000000000000000000"),
      BigInt.zero(),
      BigInt.fromString("-2000000000000000000000"),
    );

    // Liquidation has 10 uint256 fields; _price is word 9 (zero-indexed).
    let expectedLiqPrice = BigInt.fromString("1850000000000000000"); // 1.85
    let liqData = packUint256s([
      BigInt.fromI32(100), // _debtOffsetBySP
      BigInt.fromI32(200), // _debtRedistributed
      BigInt.fromI32(1),   // _boldGasCompensation
      BigInt.fromI32(2),   // _collGasCompensation
      BigInt.fromI32(150), // _collSentToSP
      BigInt.fromI32(50),  // _collRedistributed
      BigInt.fromI32(10),  // _collSurplus
      BigInt.fromI32(0),   // _L_ETH
      BigInt.fromI32(0),   // _L_boldDebt
      expectedLiqPrice,    // _price (word 9)
    ]);

    event.receipt = buildReceiptWithLog(event, LIQUIDATION_TOPIC, liqData);

    handleTroveOperation(event);

    let opId = event.transaction.hash.concatI32(event.logIndex.toI32()).toHexString();
    assert.fieldEquals("TroveOperation", opId, "operation", "liquidate");
    assert.fieldEquals("TroveOperation", opId, "liquidationPrice", expectedLiqPrice.toString());
  });
});
