// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IStabilityPool} from "./Interfaces/IStabilityPool.sol";
import {StabilityPool} from "./StabilityPool.sol";
import {ICollateralRegistry} from "./Interfaces/ICollateralRegistry.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// BOLD_1=0x47c88261347feecc2481c714fd4d6995b9638729 -> cREAL
// BOLD_2=0x85a14e14309dd9beea55d69512e283f898e1425b -> cEUR
// WETH=0xb6900011ff85da0f990be424aa88f4dbf2442584 -> cUSD

contract Broker is Ownable {
    event StabilityPoolSet(
        address indexed stableToken,
        address indexed stabilityPool
    );
    event CollateralRegistrySet(
        address indexed stableToken,
        address indexed collateralRegistry
    );
    event Swapped(
        address indexed from,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );

    mapping(address => address) public stableTokenToCollateralRegistry;
    mapping(address => address) public stableTokenToStabilityPool;

    mapping(address => string) public smokeAndMirrors;
    mapping(string => address) public mirrorsAndSmoke;

    // Mapping for fake exchange
    mapping(bytes32 => Rate) public exchangeRates;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    constructor() {
        smokeAndMirrors[0x47C88261347fEecc2481c714Fd4D6995B9638729] = "cREAL";
        smokeAndMirrors[0x85a14e14309DD9BEea55d69512e283F898E1425b] = "cEUR";
        smokeAndMirrors[0xb6900011Ff85dA0f990bE424Aa88F4dBf2442584] = "cUSD";

        mirrorsAndSmoke["cREAL"] = 0x47C88261347fEecc2481c714Fd4D6995B9638729;
        mirrorsAndSmoke["cEUR"] = 0x85a14e14309DD9BEea55d69512e283F898E1425b;
        mirrorsAndSmoke["cUSD"] = 0xb6900011Ff85dA0f990bE424Aa88F4dBf2442584;

        seedExchangeRates();
    }

    function seedExchangeRates() private {
        // cUSD to cREAL (1 cUSD = 6 cREAL)
        setRate("cUSD", "cREAL", 6, 1);

        // cREAL to cUSD (1 cREAL = 0.16 cUSD)
        setRate("cREAL", "cUSD", 16, 100);

        // cUSD to cEUR (1 cUSD = 0.94 cEUR)
        setRate("cUSD", "cEUR", 94, 100);

        // cEUR to cUSD (1 cEUR = 1.05 cUSD)
        setRate("cEUR", "cUSD", 105, 100);

        // cREAL to cEUR (1 cREAL = 0.15 cEUR)
        setRate("cREAL", "cEUR", 15, 100);

        // cEUR to cREAL (1 cEUR = 6.42 cREAL)
        setRate("cEUR", "cREAL", 642, 100);
    }

    /**
     * @dev Get the rate feed id for a given pair of symbols
     * @param fromSymbol The symbol of the from token
     * @param toSymbol The symbol of the to token
     * @return The rate feed id
     */
    function getRateFeedId(
        string memory fromSymbol,
        string memory toSymbol
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(fromSymbol, toSymbol, "FX"));
    }

    function setRate(
        string memory fromSymbol,
        string memory toSymbol,
        uint256 numerator,
        uint256 denominator
    ) public onlyOwner {
        require(denominator != 0, "Denominator cannot be zero");
        bytes32 rateId = getRateFeedId(fromSymbol, toSymbol);
        exchangeRates[rateId] = Rate(numerator, denominator);
    }

    function getRate(
        bytes32 rateFeedId
    ) public view returns (uint256, uint256) {
        Rate memory rate = exchangeRates[rateFeedId];
        require(rate.denominator != 0, "Rate not found");
        return (rate.numerator, rate.denominator);
    }

    function getAmountOut(
        address from,
        address to,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        // Get the symbol of the from token
        string memory fromSymbol = smokeAndMirrors[from];
        require(bytes(fromSymbol).length > 0, "From token not supported");

        // Get the symbol of the to token
        string memory toSymbol = smokeAndMirrors[to];
        require(bytes(toSymbol).length > 0, "To token not supported");

        bytes32 rateFeedId = getRateFeedId(fromSymbol, toSymbol);
        (uint256 rateNumerator, uint256 rateDenominator) = getRate(rateFeedId);
        amountOut =
            ((amountIn * rateNumerator * 1e18) / rateDenominator) /
            1e18;
    }

    function getAmountIn(
        address from,
        address to,
        uint256 amountOut
    ) external view returns (uint256 amountIn) {
        // Get the symbol of the from token
        string memory fromSymbol = smokeAndMirrors[from];
        require(bytes(fromSymbol).length > 0, "From token not supported");

        // Get the symbol of the to token
        string memory toSymbol = smokeAndMirrors[to];
        require(bytes(toSymbol).length > 0, "To token not supported");

        bytes32 rateFeedId = getRateFeedId(fromSymbol, toSymbol);
        (uint256 rateNumerator, uint256 rateDenominator) = getRate(rateFeedId);
        amountIn =
            ((amountOut * rateDenominator * 1e18) / rateNumerator) /
            1e18;
    }

    //==================================  Admin Setter Functions  ======================================= //

    function setCollateralRegistry(
        address stableToken,
        ICollateralRegistry collateralRegistry
    ) external onlyOwner {
        require(
            address(stableToken) != address(0),
            "StableToken address must be set"
        );
        require(
            address(collateralRegistry.boldToken()) == stableToken,
            "CollateralRegistry is not correct for the stable token"
        );
        stableTokenToCollateralRegistry[stableToken] = address(
            collateralRegistry
        );
        emit CollateralRegistrySet(stableToken, address(collateralRegistry));
    }

    function setStabilityPool(
        address stableToken,
        IStabilityPool stabilityPool
    ) external onlyOwner {
        require(
            address(stableToken) != address(0),
            "StableToken address must be set"
        );
        require(
            address(stabilityPool.boldToken()) == stableToken,
            "IStabilityPool is not correct for the stable token"
        );
        stableTokenToStabilityPool[stableToken] = address(stabilityPool);
        emit StabilityPoolSet(stableToken, address(stabilityPool));
    }

    // ==================================  Mutative Functions  ======================================= //

    function swapCollateral(
        address to,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        address toCollateralRegistry = stableTokenToCollateralRegistry[to];
        address toStabilityPool = stableTokenToStabilityPool[to];
        require(
            toCollateralRegistry != address(0),
            "CollateralRegistry not set for to token"
        );
        require(
            IERC20(to).balanceOf(msg.sender) >= amountIn,
            "Insufficient balance"
        );
        require(
            toStabilityPool != address(0),
            "StabilityPool not set for to token"
        );

        // Get the collateral address
        IERC20 collateralToken = StabilityPool(toCollateralRegistry)
            .collToken();
        require(
            collateralToken.allowance(msg.sender, address(this)) >= amountIn,
            "Insufficient allowance"
        );

        // Get the symbol of the collateral token
        string memory collateralSymbol = smokeAndMirrors[
            address(collateralToken)
        ];
        require(
            bytes(collateralSymbol).length > 0,
            "Collateral token not supported"
        );

        // Get the symbol of the to token
        string memory toSymbol = smokeAndMirrors[to];
        require(bytes(toSymbol).length > 0, "To token not supported");

        // Get the ratefeedId
        bytes32 rateFeedId = getRateFeedId(collateralSymbol, toSymbol);

        // Get the rate
        (uint256 rateNumerator, uint256 rateDenominator) = getRate(rateFeedId);
        amountOut =
            ((amountIn * rateNumerator * 1e18) / rateDenominator) /
            1e18;

        // Transfer collateral to the broker
        collateralToken.transferFrom(msg.sender, address(this), amountIn);

        // Allow stability pool to spend the collateral
        collateralToken.approve(toStabilityPool, amountIn);

        // Call the collateralSwapIn
        IStabilityPool(toStabilityPool).collateralSwapIn(
            amountIn,
            amountOut,
            msg.sender
        );

        emit Swapped(address(collateralToken), to, amountIn, amountOut);
    }

    function swap(
        address from,
        address to,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        require(
            IERC20(from).balanceOf(msg.sender) >= amountIn,
            "Insufficient balance"
        );
        require(
            IERC20(from).allowance(msg.sender, address(this)) >= amountIn,
            "Insufficient allowance"
        );

        address fromCollateralRegistry = stableTokenToCollateralRegistry[from];
        require(
            fromCollateralRegistry != address(0),
            "CollateralRegistry not set for from token"
        );

        address toStabilityPool = stableTokenToStabilityPool[to];
        require(
            toStabilityPool != address(0),
            "StabilityPool not set for to token"
        );

        // Get the symbol of the from token
        string memory fromSymbol = smokeAndMirrors[from];
        require(bytes(fromSymbol).length > 0, "From token not supported");

        // Get the symbol of the to token
        string memory toSymbol = smokeAndMirrors[to];
        require(bytes(toSymbol).length > 0, "To token not supported");

        // Get the rate feed id
        bytes32 rateFeedId = getRateFeedId(fromSymbol, toSymbol);

        // Get the rate
        (uint256 rateNumerator, uint256 rateDenominator) = getRate(rateFeedId);
        amountOut =
            ((amountIn * rateNumerator * 1e18) / rateDenominator) /
            1e18;

        ICollateralRegistry collateralRegistry = ICollateralRegistry(
            stableTokenToCollateralRegistry[from]
        );

        // Transfer the from token to this contract
        IERC20(from).transferFrom(msg.sender, address(this), amountIn);

        // Approve the collateral registry to spend the from token of this contract
        IERC20(from).approve(address(collateralRegistry), amountIn);

        // Assuming we only have one collateral token
        address collateralToken = address(collateralRegistry.getToken(0));
        uint256 collateralBalanceBefore = IERC20(collateralToken).balanceOf(
            address(this)
        );

        uint256 maxFeePct = collateralRegistry
            .getRedemptionRateForRedeemedAmount(amountIn);
        collateralRegistry.redeemCollateral(amountIn, 10, maxFeePct);

        uint256 collateralReceived = IERC20(collateralToken).balanceOf(
            address(this)
        ) - collateralBalanceBefore;

        // Allow stability pool to spend the collateral
        IERC20(collateralToken).approve(toStabilityPool, collateralReceived);

        // Call the collateralSwapIn
        IStabilityPool(toStabilityPool).collateralSwapIn(
            collateralReceived,
            amountOut,
            msg.sender
        );

        emit Swapped(from, to, amountIn, amountOut);
    }
}
