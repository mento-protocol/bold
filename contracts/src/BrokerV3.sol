// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IStabilityPool} from "./Interfaces/IStabilityPool.sol";
import {StabilityPool} from "./StabilityPool.sol";
import {ICollateralRegistry} from "./Interfaces/ICollateralRegistry.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

    // Mapping for fake exchange
    mapping(bytes32 => Rate) public exchangeRates;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    constructor() {
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
        bytes32 rateFeedId = getRateFeedId(
            IERC20Metadata(from).symbol(),
            IERC20Metadata(to).symbol()
        );
        (uint256 rateNumerator, uint256 rateDenominator) = getRate(rateFeedId);
        amountOut =
            ((amountIn * rateNumerator * 1e18) / rateDenominator) /
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

        // Get the ratefeedId
        bytes32 rateFeedId = getRateFeedId(
            IERC20Metadata(address(collateralToken)).symbol(),
            IERC20Metadata(to).symbol()
        );

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

        // Get the rate feed id
        bytes32 rateFeedId = getRateFeedId(
            IERC20Metadata(from).symbol(),
            IERC20Metadata(to).symbol()
        );

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
