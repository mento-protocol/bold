// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC20 as IERC20_GOV} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StringFormatting} from "test/Utils/StringFormatting.sol";
import {Accounts} from "test/TestContracts/Accounts.sol";
import {ERC20Faucet} from "test/TestContracts/ERC20Faucet.sol";
import {ETH_GAS_COMPENSATION} from "src/Dependencies/Constants.sol";
import {IBorrowerOperations} from "src/Interfaces/IBorrowerOperations.sol";
import "src/AddressesRegistry.sol";
import "src/ActivePool.sol";
import "src/BoldToken.sol";
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
import "src/PriceFeeds/WETHPriceFeed.sol";
import "src/PriceFeeds/WSTETHPriceFeed.sol";
import "src/PriceFeeds/RETHPriceFeed.sol";
import "src/CollateralRegistry.sol";
import "test/TestContracts/PriceFeedTestnet.sol";
import "test/TestContracts/MetadataDeployment.sol";
import "test/Utils/Logging.sol";
import "test/Utils/StringEquality.sol";
import {WETHTester} from "test/TestContracts/WETHTester.sol";
import "forge-std/console2.sol";
import {IRateProvider, IWeightedPool, IWeightedPoolFactory} from "./Interfaces/Balancer/IWeightedPool.sol";
import {IVault} from "./Interfaces/Balancer/IVault.sol";
import {MockStakingV1} from "V2-gov/test/mocks/MockStakingV1.sol";

contract DeployLiquity2Script is StdCheats, MetadataDeployment, Logging {
    using Strings for *;
    using StringFormatting for *;
    using StringEquality for string;

    string constant DEPLOYMENT_MODE_COMPLETE = "complete";
    string constant DEPLOYMENT_MODE_BOLD_ONLY = "bold-only";
    string constant DEPLOYMENT_MODE_USE_EXISTING_BOLD = "use-existing-bold";

    address WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // used for gas compensation and as collateral of the first branch
    // tapping disallowed
    IWETH WETH;
    IERC20Metadata USDC;
    address ETH_ORACLE_ADDRESS = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 ETH_USD_STALENESS_THRESHOLD = 24 hours;

    bytes32 SALT;
    address deployer;
    bool useTestnetPriceFeeds;

    uint256 lastTroveIndex;

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

 

    struct TroveManagerParams {
        uint256 CCR;
        uint256 MCR;
        uint256 SCR;
        uint256 LIQUIDATION_PENALTY_SP;
        uint256 LIQUIDATION_PENALTY_REDISTRIBUTION;
    }

    struct DeploymentVars {
        uint256 numCollaterals;
        IERC20Metadata[] collaterals;
        IPriceFeed[] priceFeeds;
        IAddressesRegistry[] addressesRegistries;
        ITroveManager[] troveManagers;
        LiquityContracts contracts;
        bytes bytecode;
        address boldTokenAddress;
        uint256 i;
    }


    struct DeploymentResult {
        LiquityContracts[] contractsArray;
        ICollateralRegistry collateralRegistry;
        IBoldToken boldToken;
        HintHelpers hintHelpers;
        MultiTroveGetter multiTroveGetter;
    }

    function run() external {
        string memory saltStr = vm.envOr("SALT", block.timestamp.toString());
        SALT = keccak256(bytes(saltStr));

        if (vm.envBytes("DEPLOYER").length == 20) {
            // address
            deployer = vm.envAddress("DEPLOYER");
            vm.startBroadcast(deployer);
        } else {
            // private key
            uint256 privateKey = vm.envUint("DEPLOYER");
            deployer = vm.addr(privateKey);
            vm.startBroadcast(privateKey);
        }

        string memory deploymentMode = vm.envOr(
            "DEPLOYMENT_MODE",
            DEPLOYMENT_MODE_COMPLETE
        );
        require(
            deploymentMode.eq(DEPLOYMENT_MODE_COMPLETE) ||
                deploymentMode.eq(DEPLOYMENT_MODE_BOLD_ONLY) ||
                deploymentMode.eq(DEPLOYMENT_MODE_USE_EXISTING_BOLD),
            string.concat("Bad deployment mode: ", deploymentMode)
        );

        useTestnetPriceFeeds = vm.envOr("USE_TESTNET_PRICEFEEDS", false);

        _log("Deployer:               ", deployer.toHexString());
        _log("Deployer balance:       ", deployer.balance.decimal());
        _log("Deployment mode:        ", deploymentMode);
        _log(
            "CREATE2 salt:           ",
            'keccak256(bytes("',
            saltStr,
            '")) = ',
            uint256(SALT).toHexString()
        );

        _log("Use testnet PriceFeeds: ", useTestnetPriceFeeds ? "yes" : "no");

        // Deploy Bold or pick up existing deployment
        bytes memory boldBytecode = bytes.concat(
            type(BoldToken).creationCode,
            abi.encode(deployer)
        );
        address boldAddress = vm.computeCreate2Address(
            SALT,
            keccak256(boldBytecode)
        );
        BoldToken boldToken;

        if (deploymentMode.eq(DEPLOYMENT_MODE_USE_EXISTING_BOLD)) {
            require(
                boldAddress.code.length > 0,
                string.concat("BOLD not found at ", boldAddress.toHexString())
            );
            boldToken = BoldToken(boldAddress);

            // Check BOLD is untouched
            require(boldToken.totalSupply() == 0, "Some BOLD has been minted!");
            require(
                boldToken.collateralRegistryAddress() == address(0),
                "Collateral registry already set"
            );
            require(boldToken.owner() == deployer, "Not BOLD owner");
        } else {
            boldToken = new BoldToken{salt: SALT}(deployer);
            assert(address(boldToken) == boldAddress);
        }

        if (deploymentMode.eq(DEPLOYMENT_MODE_BOLD_ONLY)) {
            vm.writeFile(
                "deployment-manifest.json",
                string.concat('{"boldToken":"', boldAddress.toHexString(), '"}')
            );
            return;
        }

        // sepolia, local
        if (block.chainid == 31337) {
            // local
            WETH = new WETHTester({_tapAmount: 100 ether, _tapPeriod: 1 days});
        } else {
            // sepolia
            WETH = new WETHTester({
                _tapAmount: 0,
                _tapPeriod: type(uint256).max
            });
        }
        USDC = new ERC20Faucet("USDC", "USDC", 0, type(uint256).max);

        TroveManagerParams[]
            memory troveManagerParamsArray = new TroveManagerParams[](1);
        // TODO: move params out of here
        troveManagerParamsArray[0] = TroveManagerParams(
            150e16,
            110e16,
            110e16,
            5e16,
            10e16
        ); // WETH

        string[] memory collNames = new string[](0);
        string[] memory collSymbols = new string[](0);

        DeploymentResult memory deployed = _deployAndConnectContracts(
            troveManagerParamsArray,
            collNames,
            collSymbols,
            address(boldToken)
        );

        vm.stopBroadcast();

        vm.writeFile(
            "deployment-manifest.json",
            _getManifestJson(deployed)
        );
       
    }

    function tapFaucet(
        uint256[] memory accounts,
        LiquityContracts memory contracts
    ) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            ERC20Faucet token = ERC20Faucet(address(contracts.collToken));

            vm.startBroadcast(accounts[i]);
            token.tap();
            vm.stopBroadcast();

            console2.log(
                "%s.tap() => %s (balance: %s)",
                token.symbol(),
                vm.addr(accounts[i]),
                string.concat(
                    formatAmount(token.balanceOf(vm.addr(accounts[i])), 18, 2),
                    " ",
                    token.symbol()
                )
            );
        }
    }

 

    // See: https://solidity-by-example.org/app/create2/
    function getBytecode(
        bytes memory _creationCode,
        address _addressesRegistry
    ) public pure returns (bytes memory) {
        return abi.encodePacked(_creationCode, abi.encode(_addressesRegistry));
    }

    function _deployAndConnectContracts(
        TroveManagerParams[] memory troveManagerParamsArray,
        string[] memory _collNames,
        string[] memory _collSymbols,
        address _boldToken
    ) internal returns (DeploymentResult memory r) {
        assert(_collNames.length == troveManagerParamsArray.length - 1);
        assert(_collSymbols.length == troveManagerParamsArray.length - 1);

        DeploymentVars memory vars;
        vars.numCollaterals = troveManagerParamsArray.length;
        r.boldToken = BoldToken(_boldToken);


        r.contractsArray = new LiquityContracts[](vars.numCollaterals);
        vars.collaterals = new IERC20Metadata[](vars.numCollaterals);
        vars.priceFeeds = new IPriceFeed[](vars.numCollaterals);
        vars.addressesRegistries = new IAddressesRegistry[](
            vars.numCollaterals
        );
        vars.troveManagers = new ITroveManager[](vars.numCollaterals);

        if (block.chainid == 1 && !useTestnetPriceFeeds) {
            // mainnet
            // ETH
            vars.collaterals[0] = IERC20Metadata(WETH);
            vars.priceFeeds[0] = new WETHPriceFeed(
                deployer,
                ETH_ORACLE_ADDRESS,
                ETH_USD_STALENESS_THRESHOLD
            );

        } else {
            // Sepolia
            // Use WETH as collateral for the first branch
            vars.collaterals[0] = WETH;
            vars.priceFeeds[0] = new PriceFeedTestnet();

            // Deploy plain ERC20Faucets for the rest of the branches
            for (vars.i = 1; vars.i < vars.numCollaterals; vars.i++) {
                vars.collaterals[vars.i] = new ERC20Faucet(
                    _collNames[vars.i - 1], //   _name
                    _collSymbols[vars.i - 1], // _symbol
                    100 ether, //     _tapAmount
                    1 days //         _tapPeriod
                );
                vars.priceFeeds[vars.i] = new PriceFeedTestnet();
            }
        }

        // Deploy AddressesRegistries and get TroveManager addresses
        for (vars.i = 0; vars.i < vars.numCollaterals; vars.i++) {
            (
                IAddressesRegistry addressesRegistry,
                address troveManagerAddress
            ) = _deployAddressesRegistry(troveManagerParamsArray[vars.i]);
            vars.addressesRegistries[vars.i] = addressesRegistry;
            vars.troveManagers[vars.i] = ITroveManager(troveManagerAddress);
        }

        r.collateralRegistry = new CollateralRegistry(
            r.boldToken,
            vars.collaterals,
            vars.troveManagers
        );
        r.hintHelpers = new HintHelpers(r.collateralRegistry);
        r.multiTroveGetter = new MultiTroveGetter(r.collateralRegistry);

        // Deploy per-branch contracts for each branch
        for (vars.i = 0; vars.i < vars.numCollaterals; vars.i++) {
            vars.contracts = _deployAndConnectCollateralContracts(
                vars.collaterals[vars.i],
                vars.priceFeeds[vars.i],
                r.boldToken,
                r.collateralRegistry,
                vars.addressesRegistries[vars.i],
                address(vars.troveManagers[vars.i]),
                r.hintHelpers,
                r.multiTroveGetter
            );
            r.contractsArray[vars.i] = vars.contracts;
        }

        r.boldToken.setCollateralRegistry(address(r.collateralRegistry));

    }

    function _deployAddressesRegistry(
        TroveManagerParams memory _troveManagerParams
    ) internal returns (IAddressesRegistry, address) {
        IAddressesRegistry addressesRegistry = new AddressesRegistry(
            deployer,
            _troveManagerParams.CCR,
            _troveManagerParams.MCR,
            _troveManagerParams.SCR,
            _troveManagerParams.LIQUIDATION_PENALTY_SP,
            _troveManagerParams.LIQUIDATION_PENALTY_REDISTRIBUTION
        );
        address troveManagerAddress = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(TroveManager).creationCode,
                    address(addressesRegistry)
                )
            )
        );

        return (addressesRegistry, troveManagerAddress);
    }

    function _deployAndConnectCollateralContracts(
        IERC20Metadata _collToken,
        IPriceFeed _priceFeed,
        IBoldToken _boldToken,
        ICollateralRegistry _collateralRegistry,
        IAddressesRegistry _addressesRegistry,
        address _troveManagerAddress,
        IHintHelpers _hintHelpers,
        IMultiTroveGetter _multiTroveGetter
    ) internal returns (LiquityContracts memory contracts) {
        LiquityContractAddresses memory addresses;
        contracts.collToken = _collToken;

        // Deploy all contracts, using testers for TM and PriceFeed
        contracts.addressesRegistry = _addressesRegistry;

        // Deploy Metadata
        contracts.metadataNFT = deployMetadata(SALT);
        addresses.metadataNFT = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(MetadataNFT).creationCode,
                    address(initializedFixedAssetReader)
                )
            )
        );
        assert(address(contracts.metadataNFT) == addresses.metadataNFT);

        contracts.priceFeed = _priceFeed;
        contracts.interestRouter = IInterestRouter(0x56fD3F2bEE130e9867942D0F463a16fBE49B8d81);
        addresses.borrowerOperations = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(BorrowerOperations).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.troveManager = _troveManagerAddress;
        addresses.troveNFT = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(TroveNFT).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.stabilityPool = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(StabilityPool).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.activePool = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(ActivePool).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.defaultPool = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(DefaultPool).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.gasPool = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(GasPool).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.collSurplusPool = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(CollSurplusPool).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );
        addresses.sortedTroves = vm.computeCreate2Address(
            SALT,
            keccak256(
                getBytecode(
                    type(SortedTroves).creationCode,
                    address(contracts.addressesRegistry)
                )
            )
        );

        IAddressesRegistry.AddressVars memory addressVars = IAddressesRegistry
            .AddressVars({
                collToken: _collToken,
                borrowerOperations: IBorrowerOperations(
                    addresses.borrowerOperations
                ),
                troveManager: ITroveManager(addresses.troveManager),
                troveNFT: ITroveNFT(addresses.troveNFT),
                metadataNFT: IMetadataNFT(addresses.metadataNFT),
                stabilityPool: IStabilityPool(addresses.stabilityPool),
                priceFeed: contracts.priceFeed,
                activePool: IActivePool(addresses.activePool),
                defaultPool: IDefaultPool(addresses.defaultPool),
                gasPoolAddress: addresses.gasPool,
                collSurplusPool: ICollSurplusPool(addresses.collSurplusPool),
                sortedTroves: ISortedTroves(addresses.sortedTroves),
                interestRouter: contracts.interestRouter,
                hintHelpers: _hintHelpers,
                multiTroveGetter: _multiTroveGetter,
                collateralRegistry: _collateralRegistry,
                boldToken: _boldToken,
                WETH: WETH
            });
        contracts.addressesRegistry.setAddresses(addressVars);
        contracts.priceFeed.setAddresses(addresses.borrowerOperations);

        contracts.borrowerOperations = new BorrowerOperations{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.troveManager = new TroveManager{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.troveNFT = new TroveNFT{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.stabilityPool = new StabilityPool{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.activePool = new ActivePool{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.defaultPool = new DefaultPool{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.gasPool = new GasPool{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.collSurplusPool = new CollSurplusPool{salt: SALT}(
            contracts.addressesRegistry
        );
        contracts.sortedTroves = new SortedTroves{salt: SALT}(
            contracts.addressesRegistry
        );

        assert(
            address(contracts.borrowerOperations) ==
                addresses.borrowerOperations
        );
        assert(address(contracts.troveManager) == addresses.troveManager);
        assert(address(contracts.troveNFT) == addresses.troveNFT);
        assert(address(contracts.stabilityPool) == addresses.stabilityPool);
        assert(address(contracts.activePool) == addresses.activePool);
        assert(address(contracts.defaultPool) == addresses.defaultPool);
        assert(address(contracts.gasPool) == addresses.gasPool);
        assert(address(contracts.collSurplusPool) == addresses.collSurplusPool);
        assert(address(contracts.sortedTroves) == addresses.sortedTroves);

        // Connect contracts
        _boldToken.setBranchAddresses(
            address(contracts.troveManager),
            address(contracts.stabilityPool),
            address(contracts.borrowerOperations),
            address(contracts.activePool)
        );

    }

 

    function _mintBold(
        uint256 _boldAmount,
        uint256 _price,
        LiquityContracts memory _contracts
    ) internal {
        uint256 collAmount = (_boldAmount * 2 ether) / _price; // CR of ~200%

        ERC20Faucet(address(_contracts.collToken)).mint(deployer, collAmount);
        WETHTester(payable(address(WETH))).mint(deployer, ETH_GAS_COMPENSATION);

        if (_contracts.collToken == WETH) {
            WETH.approve(
                address(_contracts.borrowerOperations),
                collAmount + ETH_GAS_COMPENSATION
            );
        } else {
            _contracts.collToken.approve(
                address(_contracts.borrowerOperations),
                collAmount
            );
            WETH.approve(
                address(_contracts.borrowerOperations),
                ETH_GAS_COMPENSATION
            );
        }

        _contracts.borrowerOperations.openTrove({
            _owner: deployer,
            _ownerIndex: lastTroveIndex++,
            _ETHAmount: collAmount,
            _boldAmount: _boldAmount,
            _upperHint: 0,
            _lowerHint: 0,
            _annualInterestRate: 0.05 ether,
            _maxUpfrontFee: type(uint256).max,
            _addManager: address(0),
            _removeManager: address(0),
            _receiver: address(0)
        });
    }

function formatAmount(
        uint256 amount,
        uint256 decimals,
        uint256 digits
    ) internal pure returns (string memory) {
        if (digits > decimals) {
            digits = decimals;
        }

        uint256 scaled = amount / (10 ** (decimals - digits));
        string memory whole = Strings.toString(scaled / (10 ** digits));

        if (digits == 0) {
            return whole;
        }

        string memory fractional = Strings.toString(scaled % (10 ** digits));
        for (uint256 i = bytes(fractional).length; i < digits; i++) {
            fractional = string.concat("0", fractional);
        }
        return string.concat(whole, ".", fractional);
    }

    function _getBranchContractsJson(
        LiquityContracts memory c
    ) internal view returns (string memory) {
        return
            string.concat(
                "{",
                string.concat(
                    // Avoid stack too deep by chunking concats
                    string.concat(
                        string.concat(
                            '"collSymbol":"',
                            c.collToken.symbol(),
                            '",'
                        ), // purely for human-readability
                        string.concat(
                            '"collToken":"',
                            address(c.collToken).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"addressesRegistry":"',
                            address(c.addressesRegistry).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"activePool":"',
                            address(c.activePool).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"borrowerOperations":"',
                            address(c.borrowerOperations).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"collSurplusPool":"',
                            address(c.collSurplusPool).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"defaultPool":"',
                            address(c.defaultPool).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"sortedTroves":"',
                            address(c.sortedTroves).toHexString(),
                            '",'
                        )
                    ),
                    string.concat(
                        string.concat(
                            '"stabilityPool":"',
                            address(c.stabilityPool).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"troveManager":"',
                            address(c.troveManager).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"troveNFT":"',
                            address(c.troveNFT).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"metadataNFT":"',
                            address(c.metadataNFT).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"priceFeed":"',
                            address(c.priceFeed).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"gasPool":"',
                            address(c.gasPool).toHexString(),
                            '",'
                        ),
                        string.concat(
                            '"interestRouter":"',
                            address(c.interestRouter).toHexString(),
                            '",'
                        )                      
                    )
                ),
                "}"
            );
    }

    function _getDeploymentConstants() internal pure returns (string memory) {
        return
            string.concat(
                "{",
                string.concat(
                    string.concat(
                        '"ETH_GAS_COMPENSATION":"',
                        ETH_GAS_COMPENSATION.toString(),
                        '",'
                    ),
                    string.concat(
                        '"INTEREST_RATE_ADJ_COOLDOWN":"',
                        INTEREST_RATE_ADJ_COOLDOWN.toString(),
                        '",'
                    ),
                    string.concat(
                        '"MAX_ANNUAL_INTEREST_RATE":"',
                        MAX_ANNUAL_INTEREST_RATE.toString(),
                        '",'
                    ),
                    string.concat(
                        '"MIN_ANNUAL_INTEREST_RATE":"',
                        MIN_ANNUAL_INTEREST_RATE.toString(),
                        '",'
                    ),
                    string.concat('"MIN_DEBT":"', MIN_DEBT.toString(), '",'),
                    string.concat(
                        '"SP_YIELD_SPLIT":"',
                        SP_YIELD_SPLIT.toString(),
                        '",'
                    ),
                    string.concat(
                        '"UPFRONT_INTEREST_PERIOD":"',
                        UPFRONT_INTEREST_PERIOD.toString(),
                        '"'
                    ) // no comma
                ),
                "}"
            );
    }

    function _getManifestJson(
        DeploymentResult memory deployed
    ) internal view returns (string memory) {
        string[] memory branches = new string[](deployed.contractsArray.length);

        // Poor man's .map()
        for (uint256 i = 0; i < branches.length; ++i) {
            branches[i] = _getBranchContractsJson(deployed.contractsArray[i]);
        }

        return
            string.concat(
                "{",
                string.concat(
                    string.concat(
                        '"constants":',
                        _getDeploymentConstants(),
                        ","
                    ),
                    string.concat(
                        '"collateralRegistry":"',
                        address(deployed.collateralRegistry).toHexString(),
                        '",'
                    ),
                    string.concat(
                        '"boldToken":"',
                        address(deployed.boldToken).toHexString(),
                        '",'
                    ),
                    string.concat(
                        '"hintHelpers":"',
                        address(deployed.hintHelpers).toHexString(),
                        '",'
                    ),
                    string.concat(
                        '"multiTroveGetter":"',
                        address(deployed.multiTroveGetter).toHexString(),
                        '",'
                    ),
                    string.concat('"branches":[', branches.join(","), "],")
                ),
                "}"
            );
    }
}
