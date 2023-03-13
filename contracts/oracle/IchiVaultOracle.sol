// SPDX-License-Identifier: MIT
/*
██████╗ ██╗     ██╗   ██╗███████╗██████╗ ███████╗██████╗ ██████╗ ██╗   ██╗
██╔══██╗██║     ██║   ██║██╔════╝██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝██║     ██║   ██║█████╗  ██████╔╝█████╗  ██████╔╝██████╔╝ ╚████╔╝
██╔══██╗██║     ██║   ██║██╔══╝  ██╔══██╗██╔══╝  ██╔══██╗██╔══██╗  ╚██╔╝
██████╔╝███████╗╚██████╔╝███████╗██████╔╝███████╗██║  ██║██║  ██║   ██║
╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝
*/

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../utils/BlueBerryErrors.sol" as Errors;
import "../utils/BlueBerryConst.sol" as Constants;
import "../libraries/UniV3/UniV3WrappedLibMockup.sol";
import "./UsingBaseOracle.sol";
import "../interfaces/IBaseOracle.sol";
import "../interfaces/ichi/IICHIVault.sol";

/**
 * @author gmspacex
 * @title Ichi Vault Oracle
 * @notice Oracle contract provides price feeds of Ichi Vault tokens
 * @dev The logic of this oracle is using legacy & traditional mathematics of Uniswap V2 Lp Oracle.
 *      Base token prices are fetched from Chainlink or Band Protocol.
 *      To prevent flashloan price manipulations, it compares spot & twap prices from Uni V3 Pool.
 */
contract IchiVaultOracle is UsingBaseOracle, IBaseOracle, Ownable {
    mapping(address => uint256) public maxPriceDeviations;

    constructor(IBaseOracle _base) UsingBaseOracle(_base) {}

    event SetPriceDeviation(address indexed token, uint256 maxPriceDeviation);

    /// @notice Set price deviations for given token
    /// @dev Input token is the underlying token of ICHI Vaults which is token0 or token1 of Uni V3 Pool
    /// @param token Token to price deviation
    /// @param maxPriceDeviation Max price deviation (in 1e18) of price feeds
    function setPriceDeviation(
        address token,
        uint256 maxPriceDeviation
    ) external onlyOwner {
        // Validate inputs
        if (token == address(0)) revert Errors.ZERO_ADDRESS();
        if (maxPriceDeviation > Constants.MAX_PRICE_DEVIATION)
            revert Errors.OUT_OF_DEVIATION_CAP(maxPriceDeviation);

        maxPriceDeviations[token] = maxPriceDeviation;
        emit SetPriceDeviation(token, maxPriceDeviation);
    }

    /**
     * @notice Get token 0 spot price quoted in token1
     * @dev Returns token0 price of 1e18 amount
     * @param vault ICHI Vault address
     * @return price spot price of token0 quoted in token1
     */
    function spotPrice0InToken1(
        IICHIVault vault
    ) public view returns (uint256) {
        return
            UniV3WrappedLibMockup.getQuoteAtTick(
                vault.currentTick(), // current tick
                uint128(Constants.PRICE_PRECISION), // amountIn
                vault.token0(), // tokenIn
                vault.token1() // tokenOut
            );
    }

    /**
     * @notice Get token 0 twap price quoted in token1
     * @dev Returns token0 price of 1e18 amount
     * @param vault ICHI Vault address
     * @return price spot price of token0 quoted in token1
     */
    function twapPrice0InToken1(
        IICHIVault vault
    ) public view returns (uint256) {
        (int256 twapTick, ) = UniV3WrappedLibMockup.consult(
            vault.pool(),
            vault.twapPeriod()
        );
        return
            UniV3WrappedLibMockup.getQuoteAtTick(
                int24(twapTick), // can assume safe being result from consult()
                uint128(Constants.PRICE_PRECISION), // amountIn
                vault.token0(), // tokenIn
                vault.token1() // tokenOut
            );
    }

    /**
     * @notice Internal function to validate deviations of 2 given prices
     * @param price0 First price to validate, base 1e18
     * @param price1 Second price to validate, base 1e18
     * @param maxPriceDeviation Max price deviation of 2 prices, base 10000
     */
    function _isValidPrices(
        uint256 price0,
        uint256 price1,
        uint256 maxPriceDeviation
    ) internal pure returns (bool) {
        uint256 delta = price0 > price1 ? (price0 - price1) : (price1 - price0);
        return ((delta * Constants.DENOMINATOR) / price0) <= maxPriceDeviation;
    }

    /**
     * @notice Return vault token price in USD, with 18 decimals of precision.
     * @param token The vault token to get the price of.
     * @return price USD price of token in 18 decimal
     */
    function getPrice(address token) external view override returns (uint256) {
        IICHIVault vault = IICHIVault(token);
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return 0;

        address token0 = vault.token0();
        address token1 = vault.token1();

        // Check price manipulations on Uni V3 pool by flashloan attack
        uint256 spotPrice = spotPrice0InToken1(vault);
        uint256 twapPrice = twapPrice0InToken1(vault);
        uint256 maxPriceDeviation = maxPriceDeviations[token0];
        if (!_isValidPrices(spotPrice, twapPrice, maxPriceDeviation))
            revert Errors.EXCEED_DEVIATION();

        (uint256 r0, uint256 r1) = vault.getTotalAmounts();
        uint256 px0 = base.getPrice(address(token0));
        uint256 px1 = base.getPrice(address(token1));
        uint256 t0Decimal = IERC20Metadata(token0).decimals();
        uint256 t1Decimal = IERC20Metadata(token1).decimals();

        uint256 totalReserve = (r0 * px0) /
            10 ** t0Decimal +
            (r1 * px1) /
            10 ** t1Decimal;

        return (totalReserve * 1e18) / totalSupply;
    }
}
