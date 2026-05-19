import { Address, BigInt, DataSourceContext } from "@graphprotocol/graph-ts";
import {
  CollateralRegistryAddressChanged as CollateralRegistryAddressChangedEvent,
} from "../generated/BoldToken/BoldToken";
import { BorrowerOperations as BorrowerOperationsContract } from "../generated/BoldToken/BorrowerOperations";
import { CollateralRegistry as CollateralRegistryContract } from "../generated/BoldToken/CollateralRegistry";
import { TroveManager as TroveManagerContract } from "../generated/BoldToken/TroveManager";
import { Collateral, CollateralAddresses } from "../generated/schema";
import { TroveManager as TroveManagerTemplate, TroveNFT as TroveNFTTemplate } from "../generated/templates";

// Mento V3 runs one independent CDP instance per FX-pegged stable (GBPm, CHFm,
// JPYm, ...). Each instance has its own CollateralRegistry, and each registry
// starts numbering its collaterals at index 0. Naming entities by `collIndex`
// alone collides across branches — every branch would write to Collateral
// id="0", Trove id="0:<troveId>", etc.
//
// We namespace every entity ID by the branch's TroveManager address (each
// branch's TroveManager is unique, and it's the address that emits the
// CollateralRegistryAddressChanged event we're handling, so it's already in
// `event.address`). The resulting collId looks like
// "0x<troveManager>:<collIndex>" and flows through DataSourceContext into
// every downstream entity ID (Trove, InterestRateBracket, InterestBatch,
// CollateralAddresses).
function addCollateral(
  branchPrefix: string,
  collIndex: i32,
  totalCollaterals: i32,
  tokenAddress: Address,
  troveManagerAddress: Address,
): void {
  let collId = branchPrefix + ":" + collIndex.toString();

  let collateral = new Collateral(collId);
  collateral.collIndex = collIndex;

  let troveManagerContract = TroveManagerContract.bind(troveManagerAddress);

  let addresses = new CollateralAddresses(collId);
  addresses.collateral = collId;
  addresses.borrowerOperations = troveManagerContract.borrowerOperations();
  addresses.sortedTroves = troveManagerContract.sortedTroves();
  addresses.stabilityPool = troveManagerContract.stabilityPool();
  addresses.token = tokenAddress;
  addresses.troveManager = troveManagerAddress;
  addresses.troveNft = troveManagerContract.troveNFT();

  collateral.minCollRatio = BorrowerOperationsContract.bind(
    Address.fromBytes(addresses.borrowerOperations),
  ).MCR();

  collateral.save();
  addresses.save();

  let context = new DataSourceContext();
  context.setBytes("address:borrowerOperations", addresses.borrowerOperations);
  context.setBytes("address:sortedTroves", addresses.sortedTroves);
  context.setBytes("address:stabilityPool", addresses.stabilityPool);
  context.setBytes("address:token", addresses.token);
  context.setBytes("address:troveManager", addresses.troveManager);
  context.setBytes("address:troveNft", addresses.troveNft);
  context.setString("collId", collId);
  context.setI32("collIndex", collIndex);
  context.setI32("totalCollaterals", totalCollaterals);

  TroveManagerTemplate.createWithContext(troveManagerAddress, context);
  TroveNFTTemplate.createWithContext(Address.fromBytes(addresses.troveNft), context);
}

export function handleCollateralRegistryAddressChanged(event: CollateralRegistryAddressChangedEvent): void {
  let branchPrefix = event.address.toHexString();
  let registry = CollateralRegistryContract.bind(event.params._newCollateralRegistryAddress);
  let totalCollaterals = registry.totalCollaterals().toI32();

  for (let index = 0; index < totalCollaterals; index++) {
    let tokenAddress = Address.fromBytes(registry.getToken(BigInt.fromI32(index)));
    let troveManagerAddress = Address.fromBytes(registry.getTroveManager(BigInt.fromI32(index)));

    if (tokenAddress.toHex() === Address.zero().toHex() || troveManagerAddress.toHex() === Address.zero().toHex()) {
      break;
    }

    let collId = branchPrefix + ":" + index.toString();
    if (!Collateral.load(collId)) {
      addCollateral(
        branchPrefix,
        index,
        totalCollaterals,
        tokenAddress,
        troveManagerAddress,
      );
    }
  }
}