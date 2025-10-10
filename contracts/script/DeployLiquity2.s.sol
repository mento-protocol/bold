// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC20 as IERC20_GOV} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from
    "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IFPMMFactory} from "src/Interfaces/IFPMMFactory.sol";
import {SystemParams} from "src/SystemParams.sol";
import {ISystemParams} from "src/Interfaces/ISystemParams.sol";
import {
    INTEREST_RATE_ADJ_COOLDOWN,
    MAX_ANNUAL_INTEREST_RATE,
    UPFRONT_INTEREST_PERIOD
} from "src/Dependencies/Constants.sol";

import {IBorrowerOperations} from "src/Interfaces/IBorrowerOperations.sol";
import {StringFormatting} from "test/Utils/StringFormatting.sol";
import {Accounts} from "test/TestContracts/Accounts.sol";
import {ERC20Faucet} from "test/TestContracts/ERC20Faucet.sol";
import {WETHTester} from "test/TestContracts/WETHTester.sol";
import "src/Interfaces/IHintHelpers.sol";
import "src/AddressesRegistry.sol";
import "src/ActivePool.sol";
import { BoldToken } from "src/BoldToken.sol";
import "src/BorrowerOperations.sol";
import "src/TroveManager.sol";
import "src/TroveNFT.sol";
import "src/CollSurplusPool.sol";
import "src/DefaultPool.sol";
import "src/GasPool.sol";
import "src/HintHelpers.sol";
import "src/MultiTroveGetter.sol";
import "src/SortedTroves.sol";
import "src/StabilityPool.sol";

import "src/CollateralRegistry.sol";
import "src/tokens/StableTokenV3.sol";
import "src/Interfaces/IStableTokenV3.sol";
import "test/TestContracts/PriceFeedTestnet.sol";
import "test/TestContracts/MetadataDeployment.sol";
import "test/Utils/Logging.sol";
import "test/Utils/StringEquality.sol";
import "forge-std/console2.sol";

contract DeployLiquity2Script is StdCheats, MetadataDeployment, Logging {
    using Strings for *;
    using StringFormatting for *;
    using StringEquality for string;

    bytes32 SALT;
    address deployer;

    struct LiquityContracts {
        IAddressesRegistry addressesRegistry;
        IActivePool activePool;
        IBorrowerOperations borrowerOperations;
        ICollSurplusPool collSurplusPool;
        IDefaultPool defaultPool;
        ISortedTroves sortedTroves;
        IStabilityPool stabilityPool;
        ITroveManager troveManager;
        ITroveNFT troveNFT;
        MetadataNFT metadataNFT;
        IPriceFeed priceFeed;
        GasPool gasPool;
        IInterestRouter interestRouter;
        IERC20Metadata collToken;
        ISystemParams systemParams;
    }

    struct LiquityContractAddresses {
        address activePool;
        address borrowerOperations;
        address collSurplusPool;
        address defaultPool;
        address sortedTroves;
        address stabilityPool;
        address troveManager;
        address troveNFT;
        address metadataNFT;
        address priceFeed;
        address gasPool;
        address interestRouter;
    }

    struct DeploymentVars {
        uint256 numCollaterals;
        IERC20Metadata[] collaterals;
        IAddressesRegistry[] addressesRegistries;
        ITroveManager[] troveManagers;
        LiquityContracts contracts;
        bytes bytecode;
        address boldTokenAddress;
        uint256 i;
    }

    struct DemoTroveParams {
        uint256 collIndex;
        uint256 owner;
        uint256 ownerIndex;
        uint256 coll;
        uint256 debt;
        uint256 annualInterestRate;
    }

    struct DeploymentResult {
        IStabilityPool stabilityPool;
        LiquityContracts contracts;
        ICollateralRegistry collateralRegistry;
        IHintHelpers hintHelpers;
        MultiTroveGetter multiTroveGetter;
        ProxyAdmin proxyAdmin;
        IStableTokenV3 stableToken;
        ISystemParams systemParams;
        address fpmm;
        address systemParamsImpl;
        address collateralRegistryImpl;
        address stableTokenV3Impl;
        address collSurplusPoolImpl;
        address defaultPoolImpl;
        address stabilityPoolImpl;
        address borrowerOperationsImpl;
        address activePoolImpl;
        address hintHelpersImpl;
        address troveManagerImpl;
    }

    struct DeploymentConfig {
        address USDm_ALFAJORES_ADDRESS;
        address proxyAdmin;
        address fpmmFactory;
        address fpmmImplementation;
        address referenceRateFeedID;
        string stableTokenName;
        string stableTokenSymbol;
    }

    DeploymentConfig internal CONFIG = DeploymentConfig({
        USDm_ALFAJORES_ADDRESS: 0x9E2d4412d0f434cC85500b79447d9323a7416f09,
        proxyAdmin: 0xe4DdacCAdb64114215FCe8251B57B2AEB5C2C0E2,
        fpmmFactory: 0xd8098494a749a3fDAD2D2e7Fa5272D8f274D8FF6,
        fpmmImplementation: 0x0292efcB331C6603eaa29D570d12eB336D6c01d6,
        referenceRateFeedID: 0x206B25Ea01E188Ee243131aFdE526bA6E131a016,
        stableTokenName: "EUR.v2 Test",
        stableTokenSymbol: "EUR.v2"
    });

    function run() external {
        string memory saltStr = vm.envOr("SALT", block.timestamp.toString());
        SALT = keccak256(bytes(saltStr));

        uint256 privateKey = vm.envUint("DEPLOYER");
        deployer = vm.addr(privateKey);
        vm.startBroadcast(privateKey);

        _log("Deployer:               ", deployer.toHexString());
        _log("Deployer balance:       ", deployer.balance.decimal());
        _log("CREATE2 salt:           ", 'keccak256(bytes("', saltStr, '")) = ', uint256(SALT).toHexString());
        _log("Chain ID:               ", block.chainid.toString());

        DeploymentResult memory deployed = _deployAndConnectContracts();

        vm.stopBroadcast();

        vm.writeFile("script/deployment-manifest.json", _getManifestJson(deployed));
    }

    // See: https://solidity-by-example.org/app/create2/
    function getBytecode(bytes memory _creationCode, address _addressesRegistry) public pure returns (bytes memory) {
        return abi.encodePacked(_creationCode, abi.encode(_addressesRegistry));
    }

    function getBytecode(bytes memory _creationCode, address _addressesRegistry, address _systemParams)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(_creationCode, abi.encode(_addressesRegistry, _systemParams));
    }

    function _deployAndConnectContracts() internal returns (DeploymentResult memory r) {
        r.proxyAdmin = ProxyAdmin(CONFIG.proxyAdmin);
        _deployAddressesRegistry(r);
        _deploySystemParams(r);
        _deployStableToken(r);
        _deployStabilityPool(r);
        _deployCollSurplusPool(r);
        _deployDefaultPool(r);
        _deployCollateralRegistry(r);
        _deployHintHelpers(r);
        // _deployFPMM(r);
        r.multiTroveGetter = new MultiTroveGetter(r.collateralRegistry);
        r.contracts.priceFeed = new PriceFeedTestnet();

        _deployAndConnectCollateralContracts(r);
    }

    function _deployAddressesRegistry(DeploymentResult memory r) internal {
        address addressesRegistry = address(new AddressesRegistry{salt: SALT}(deployer));
        assert(addressesRegistry == vm.computeCreate2Address(
            SALT, keccak256(bytes.concat(type(AddressesRegistry).creationCode, abi.encode(deployer)))
        ));
        r.contracts.addressesRegistry = IAddressesRegistry(addressesRegistry);
    }

    function _deploySystemParams(DeploymentResult memory r) internal {
        ISystemParams.DebtParams memory debtParams = ISystemParams.DebtParams({minDebt: 2000e18});

        ISystemParams.LiquidationParams memory liquidationParams =
            ISystemParams.LiquidationParams({liquidationPenaltySP: 5e16, liquidationPenaltyRedistribution: 10e16});

        ISystemParams.GasCompParams memory gasCompParams = ISystemParams.GasCompParams({
            collGasCompensationDivisor: 200,
            collGasCompensationCap: 2 ether,
            ethGasCompensation: 0.0375 ether
        });

        ISystemParams.CollateralParams memory collateralParams =
            ISystemParams.CollateralParams({ccr: 150 * 1e16, scr: 110 * 1e16, mcr: 110 * 1e16, bcr: 10 * 1e16});

        ISystemParams.InterestParams memory interestParams = ISystemParams.InterestParams({
            minAnnualInterestRate: 1e18 / 200
        });

        ISystemParams.RedemptionParams memory redemptionParams = ISystemParams.RedemptionParams({
            redemptionFeeFloor: 1e18 / 200,
            initialBaseRate: 1e18,
            redemptionMinuteDecayFactor: 998076443575628800,
            redemptionBeta: 1
        });

        ISystemParams.StabilityPoolParams memory poolParams =
            ISystemParams.StabilityPoolParams({spYieldSplit: 75 * (1e18 / 100), minBoldInSP: 1e18});

        r.systemParamsImpl = address(
            new SystemParams{salt: SALT}(
                true, // disableInitializers for implementation
                debtParams,
                liquidationParams,
                gasCompParams,
                collateralParams,
                interestParams,
                redemptionParams,
                poolParams
            )
        );

        r.systemParams = ISystemParams(
            address(new TransparentUpgradeableProxy(r.systemParamsImpl, address(r.proxyAdmin), ""))
        );
        r.systemParams.initialize();
    }

    function _deployStableToken(DeploymentResult memory r) internal {
        r.stableTokenV3Impl = address(new StableTokenV3{salt: SALT}(true));

        assert(r.stableTokenV3Impl == vm.computeCreate2Address(
            SALT, keccak256(bytes.concat(type(StableTokenV3).creationCode, abi.encode(true)))
        ));

        r.stableToken = IStableTokenV3(
            address(new TransparentUpgradeableProxy(r.stableTokenV3Impl, address(r.proxyAdmin), ""))
        );
    }

    function _deployStabilityPool(DeploymentResult memory r) internal {
        r.stabilityPoolImpl = address(new StabilityPool{salt: SALT}(true, r.contracts.addressesRegistry, r.systemParams));
        assert(r.stabilityPoolImpl == vm.computeCreate2Address(
            SALT, keccak256(bytes.concat(type(StabilityPool).creationCode, abi.encode(true, r.contracts.addressesRegistry, r.systemParams)))
        ));
        r.stabilityPool = IStabilityPool(
            address(new TransparentUpgradeableProxy(r.stabilityPoolImpl, address(r.proxyAdmin), ""))
        );
        r.stabilityPool.initialize();
    }

    function _deployCollSurplusPool(DeploymentResult memory r) internal {
        r.collSurplusPoolImpl = address(new CollSurplusPool{salt: SALT}(true, r.contracts.addressesRegistry));

        assert(r.collSurplusPoolImpl == vm.computeCreate2Address(
          SALT, keccak256(bytes.concat(type(CollSurplusPool).creationCode, abi.encode(true, address(r.contracts.addressesRegistry))))
        ));

        r.contracts.collSurplusPool = ICollSurplusPool(
            address(new TransparentUpgradeableProxy(r.collSurplusPoolImpl, address(r.proxyAdmin), ""))
        );
    }

    function _deployDefaultPool(DeploymentResult memory r) internal {
        r.defaultPoolImpl = address(new DefaultPool{salt: SALT}(true, r.contracts.addressesRegistry));
        assert(r.defaultPoolImpl == vm.computeCreate2Address(
          SALT, keccak256(bytes.concat(type(DefaultPool).creationCode, abi.encode(true, address(r.contracts.addressesRegistry))))
        ));
        r.contracts.defaultPool = IDefaultPool(
            address(new TransparentUpgradeableProxy(r.defaultPoolImpl, address(r.proxyAdmin), ""))
        );
    }

    function _deployCollateralRegistry(DeploymentResult memory r) internal {
        address troveManagerAddress =
            _computeCreate2Address(type(TroveManager).creationCode, address(r.contracts.addressesRegistry), address(r.systemParams));

        r.contracts.collToken = IERC20Metadata(CONFIG.USDm_ALFAJORES_ADDRESS);

        IERC20Metadata[] memory collaterals = new IERC20Metadata[](1);
        collaterals[0] = r.contracts.collToken;

        ITroveManager[] memory troveManagers = new ITroveManager[](1);
        troveManagers[0] = ITroveManager(troveManagerAddress);

        r.collateralRegistryImpl = address(
          new CollateralRegistry(true, IBoldToken(address(r.stableToken)), collaterals, troveManagers, r.systemParams)
        );
        r.collateralRegistry = ICollateralRegistry(
            address(new TransparentUpgradeableProxy(r.collateralRegistryImpl, address(r.proxyAdmin), ""))
        );
    }

    function _deployHintHelpers(DeploymentResult memory r) internal {
        r.hintHelpersImpl = address(new HintHelpers(true, r.collateralRegistry, r.systemParams));
        r.hintHelpers = IHintHelpers(
            address(new TransparentUpgradeableProxy(r.hintHelpersImpl, address(r.proxyAdmin), ""))
        );
    }

    function _deployFPMM(DeploymentResult memory r) internal {
        r.fpmm = IFPMMFactory(CONFIG.fpmmFactory).deployFPMM(
            CONFIG.fpmmImplementation, address(r.stableToken), CONFIG.USDm_ALFAJORES_ADDRESS, CONFIG.referenceRateFeedID
        );
    }

    function _deployAndConnectCollateralContracts(DeploymentResult memory r) internal {
        LiquityContractAddresses memory addresses;
        // TODO: replace with governance timelock on mainnet
        r.contracts.interestRouter = IInterestRouter(0x56fD3F2bEE130e9867942D0F463a16fBE49B8d81);

        addresses.troveManager = address(r.contracts.troveManager);

        r.contracts.metadataNFT = deployMetadata(SALT);
        addresses.metadataNFT = vm.computeCreate2Address(
            SALT, keccak256(getBytecode(type(MetadataNFT).creationCode, address(initializedFixedAssetReader)))
        );
        assert(address(r.contracts.metadataNFT) == addresses.metadataNFT);

        addresses.borrowerOperations = _computeCreate2Address(
            type(BorrowerOperations).creationCode, address(r.contracts.addressesRegistry), address(r.contracts.systemParams)
        );
        addresses.troveNFT = _computeCreate2Address(type(TroveNFT).creationCode, address(r.contracts.addressesRegistry));
        addresses.activePool = _computeCreate2Address(
            type(ActivePool).creationCode, address(r.contracts.addressesRegistry), address(r.contracts.systemParams)
        );
        addresses.gasPool = _computeCreate2Address(type(GasPool).creationCode, address(r.contracts.addressesRegistry));
        addresses.sortedTroves =
            _computeCreate2Address(type(SortedTroves).creationCode, address(r.contracts.addressesRegistry));

        // Set up addresses in registry
        _setupAddressesRegistry(r.contracts, addresses, r);

        // Deploy core protocol contracts
        _deployProtocolContracts(r, addresses);

        r.contracts.troveManager.initialize();
        r.contracts.defaultPool.initialize();
        r.contracts.collSurplusPool.initialize();

        address[] memory minters = new address[](2);
        minters[0] = address(r.contracts.borrowerOperations);
        minters[1] = address(r.contracts.activePool);

        address[] memory burners = new address[](4);
        burners[0] = address(r.contracts.troveManager);
        burners[1] = address(r.collateralRegistry);
        burners[2] = address(r.contracts.borrowerOperations);
        burners[3] = address(r.contracts.stabilityPool);

        address[] memory operators = new address[](1);
        operators[0] = address(r.contracts.stabilityPool);

        r.stableToken.initialize(
            CONFIG.stableTokenName,
            CONFIG.stableTokenSymbol,
            new address[](0),
            new uint256[](0),
            minters,
            burners,
            operators
        );
    }

    function _setupAddressesRegistry(
        LiquityContracts memory contracts,
        LiquityContractAddresses memory addresses,
        DeploymentResult memory r
    ) internal {
        IAddressesRegistry.AddressVars memory addressVars = IAddressesRegistry.AddressVars({
            collToken: contracts.collToken,
            borrowerOperations: IBorrowerOperations(addresses.borrowerOperations),
            troveManager: ITroveManager(addresses.troveManager),
            troveNFT: ITroveNFT(addresses.troveNFT),
            metadataNFT: IMetadataNFT(addresses.metadataNFT),
            stabilityPool: contracts.stabilityPool,
            priceFeed: contracts.priceFeed,
            activePool: IActivePool(addresses.activePool),
            defaultPool: contracts.defaultPool,
            gasPoolAddress: addresses.gasPool,
            collSurplusPool: contracts.collSurplusPool,
            sortedTroves: ISortedTroves(addresses.sortedTroves),
            interestRouter: contracts.interestRouter,
            hintHelpers: r.hintHelpers,
            multiTroveGetter: r.multiTroveGetter,
            collateralRegistry: r.collateralRegistry,
            boldToken: IBoldToken(address(r.stableToken)),
            gasToken: IERC20Metadata(CONFIG.USDm_ALFAJORES_ADDRESS),
            // TODO: set liquidity strategy
            liquidityStrategy: address(0),
            watchdogAddress: address(0)
        });

        contracts.addressesRegistry.setAddresses(addressVars);
    }

    function _deployBorrowerOperations(DeploymentResult memory r) internal {
        r.borrowerOperationsImpl = address(
            new BorrowerOperations{salt: SALT}(true, r.contracts.addressesRegistry, r.contracts.systemParams)
        );

        r.contracts.borrowerOperations = IBorrowerOperations(
            address(new TransparentUpgradeableProxy(r.borrowerOperationsImpl, address(r.proxyAdmin), ""))
        );
        r.contracts.borrowerOperations.initialize();
    }

    function _deployTroveManager(DeploymentResult memory r) internal {
        r.troveManagerImpl = address(
            new TroveManager{salt: SALT}(true, r.contracts.addressesRegistry, r.contracts.systemParams)
        );

        r.contracts.troveManager = ITroveManager(
            address(new TransparentUpgradeableProxy(r.troveManagerImpl, address(r.proxyAdmin), ""))
        );
        r.contracts.troveManager.initialize();
    }

    function _deployActivePool(DeploymentResult memory r) internal {
        r.activePoolImpl = address(
            new ActivePool{salt: SALT}(true, r.contracts.addressesRegistry, r.contracts.systemParams)
        );

        r.contracts.activePool = IActivePool(
            address(new TransparentUpgradeableProxy(r.activePoolImpl, address(r.proxyAdmin), ""))
        );
        r.contracts.activePool.initialize();
    }

    function _deployProtocolContracts(DeploymentResult memory r, LiquityContractAddresses memory addresses)
        internal
    {
        _deployBorrowerOperations(r);
        _deployTroveManager(r);
        r.contracts.troveNFT = new TroveNFT{salt: SALT}(r.contracts.addressesRegistry);
        _deployActivePool(r);
        r.contracts.gasPool = new GasPool{salt: SALT}(r.contracts.addressesRegistry);
        r.contracts.sortedTroves = new SortedTroves{salt: SALT}(r.contracts.addressesRegistry);

        assert(address(r.contracts.borrowerOperations) == addresses.borrowerOperations);
        assert(address(r.contracts.troveManager) == addresses.troveManager);
        assert(address(r.contracts.troveNFT) == addresses.troveNFT);
        assert(address(r.contracts.activePool) == addresses.activePool);
        assert(address(r.contracts.gasPool) == addresses.gasPool);
        assert(address(r.contracts.sortedTroves) == addresses.sortedTroves);
    }

    function _computeCreate2Address(bytes memory creationCode, address _addressesRegistry)
        internal
        view
        returns (address)
    {
        return vm.computeCreate2Address(SALT, keccak256(getBytecode(creationCode, _addressesRegistry)));
    }

    function _computeCreate2Address(bytes memory creationCode, address _addressesRegistry, address _systemParams)
        internal
        view
        returns (address)
    {
        return vm.computeCreate2Address(SALT, keccak256(getBytecode(creationCode, _addressesRegistry, _systemParams)));
    }

    function _getBranchContractsJson(LiquityContracts memory c) internal view returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                // Avoid stack too deep by chunking concats
                string.concat(
                    string.concat('"collSymbol":"', c.collToken.symbol(), '",'), // purely for human-readability
                    string.concat('"collToken":"', address(c.collToken).toHexString(), '",'),
                    string.concat('"addressesRegistry":"', address(c.addressesRegistry).toHexString(), '",'),
                    string.concat('"activePool":"', address(c.activePool).toHexString(), '",'),
                    string.concat('"borrowerOperations":"', address(c.borrowerOperations).toHexString(), '",'),
                    string.concat('"collSurplusPool":"', address(c.collSurplusPool).toHexString(), '",'),
                    string.concat('"defaultPool":"', address(c.defaultPool).toHexString(), '",'),
                    string.concat('"sortedTroves":"', address(c.sortedTroves).toHexString(), '",'),
                    string.concat('"systemParams":"', address(c.systemParams).toHexString(), '",')
                ),
                string.concat(
                    string.concat('"stabilityPool":"', address(c.stabilityPool).toHexString(), '",'),
                    string.concat('"troveManager":"', address(c.troveManager).toHexString(), '",'),
                    string.concat('"troveNFT":"', address(c.troveNFT).toHexString(), '",'),
                    string.concat('"metadataNFT":"', address(c.metadataNFT).toHexString(), '",'),
                    string.concat('"priceFeed":"', address(c.priceFeed).toHexString(), '",'),
                    string.concat('"gasPool":"', address(c.gasPool).toHexString(), '",'),
                    string.concat('"interestRouter":"', address(c.interestRouter).toHexString(), '",')
                )
            ),
            "}"
        );
    }

    function _getDeploymentConstants(ISystemParams params) internal view returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                string.concat('"ETH_GAS_COMPENSATION":"', params.ETH_GAS_COMPENSATION().toString(), '",'),
                string.concat('"INTEREST_RATE_ADJ_COOLDOWN":"', INTEREST_RATE_ADJ_COOLDOWN.toString(), '",'),
                string.concat('"MAX_ANNUAL_INTEREST_RATE":"', MAX_ANNUAL_INTEREST_RATE.toString(), '",'),
                string.concat('"MIN_ANNUAL_INTEREST_RATE":"', params.MIN_ANNUAL_INTEREST_RATE().toString(), '",'),
                string.concat('"MIN_DEBT":"', params.MIN_DEBT().toString(), '",'),
                string.concat('"SP_YIELD_SPLIT":"', params.SP_YIELD_SPLIT().toString(), '",'),
                string.concat('"UPFRONT_INTEREST_PERIOD":"', UPFRONT_INTEREST_PERIOD.toString(), '"') // no comma
            ),
            "}"
        );
    }

    function _getManifestJson(DeploymentResult memory deployed) internal view returns (string memory) {
        string[] memory branches = new string[](1);

        branches[0] = _getBranchContractsJson(deployed.contracts);

        string memory part1 = string.concat(
            "{",
            string.concat('"constants":', _getDeploymentConstants(deployed.contracts.systemParams), ","),
            string.concat('"collateralRegistry":"', address(deployed.collateralRegistry).toHexString(), '",'),
            string.concat('"boldToken":"', address(deployed.stableToken).toHexString(), '",'),
            string.concat('"hintHelpers":"', address(deployed.hintHelpers).toHexString(), '",')
        );

        string memory part2 = string.concat(
            string.concat('"stableTokenV3Impl":"', deployed.stableTokenV3Impl.toHexString(), '",'),
            string.concat('"stabilityPoolImpl":"', deployed.stabilityPoolImpl.toHexString(), '",'),
            string.concat('"collSurplusPoolImpl":"', deployed.collSurplusPoolImpl.toHexString(), '",'),
            string.concat('"defaultPoolImpl":"', deployed.defaultPoolImpl.toHexString(), '",'),
            string.concat('"systemParamsImpl":"', deployed.systemParamsImpl.toHexString(), '",'),
            string.concat('"systemParams":"', address(deployed.systemParams).toHexString(), '",'),
            string.concat('"multiTroveGetter":"', address(deployed.multiTroveGetter).toHexString(), '",')
        );

        string memory part3 = string.concat(
            string.concat('"fpmm":"', address(deployed.fpmm).toHexString(), '",'),
            string.concat('"branches":[', branches.join(","), "]"),
            "}"
        );

        return string.concat(part1, part2, part3);
    }
}
