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

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../utils/BlueBerryConst.sol" as Constants;
import "../utils/BlueBerryErrors.sol" as Errors;
import "../interfaces/ICoreOracle.sol";
import "../interfaces/IERC20Wrapper.sol";

/**
 * @author gmspacex
 * @title Core Oracle
 * @notice Oracle contract which provides price feeds to Bank contract
 */
contract CoreOracle is ICoreOracle, OwnableUpgradeable {
    /// @dev Mapping from token to oracle routes. => Aggregator | LP Oracle | AdapterOracle ...
    mapping(address => address) public routes;
    /// @dev Mapping from token to liquidation thresholds, multiplied by 1e4.
    mapping(address => uint256) public liqThresholds; // 85% for volatile tokens, 90% for stablecoins
    /// @dev Mapping from token address to whitelist status
    mapping(address => bool) public whitelistedERC1155;

    function initialize() external initializer {
        __Ownable_init();
    }

    /// @notice Set oracle source routes for tokens
    /// @param tokens List of tokens
    /// @param oracleRoutes List of oracle source routes
    function setRoutes(
        address[] calldata tokens,
        address[] calldata oracleRoutes
    ) external onlyOwner {
        if (tokens.length != oracleRoutes.length)
            revert Errors.INPUT_ARRAY_MISMATCH();
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            address token = tokens[idx];
            address route = oracleRoutes[idx];
            if (token == address(0) || route == address(0))
                revert Errors.ZERO_ADDRESS();

            routes[token] = route;
            emit SetRoute(token, route);
        }
    }

    /// @notice Set token liquidation thresholds
    /// @param tokens List of tokens to set liq thresholds
    /// @param thresholds List of oracle token factors
    function setLiqThresholds(
        address[] memory tokens,
        uint256[] memory thresholds
    ) external onlyOwner {
        if (tokens.length != thresholds.length)
            revert Errors.INPUT_ARRAY_MISMATCH();
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            uint256 liqThreshold = thresholds[idx];
            address token = tokens[idx];
            if (token == address(0)) revert Errors.ZERO_ADDRESS();
            if (liqThreshold > Constants.DENOMINATOR)
                revert Errors.LIQ_THRESHOLD_TOO_HIGH(liqThreshold);
            if (liqThreshold < Constants.MIN_LIQ_THRESHOLD)
                revert Errors.LIQ_THRESHOLD_TOO_LOW(liqThreshold);
            liqThresholds[token] = liqThreshold;
            emit SetLiqThreshold(token, liqThreshold);
        }
    }

    /// @notice Whitelist ERC1155(wrapped tokens)
    /// @param tokens List of tokens to set whitelist status
    /// @param ok Whitelist status
    function setWhitelistERC1155(
        address[] memory tokens,
        bool ok
    ) external onlyOwner {
        for (uint256 idx = 0; idx < tokens.length; idx++) {
            address token = tokens[idx];
            if (token == address(0)) revert Errors.ZERO_ADDRESS();
            whitelistedERC1155[token] = ok;
            emit SetWhitelist(token, ok);
        }
    }

    /// @notice Return USD price of given token, multiplied by 10**18.
    /// @param token The ERC-20 token to get the price of.
    function _getPrice(address token) internal view returns (uint256) {
        address route = routes[token];
        if (route == address(0)) revert Errors.NO_ORACLE_ROUTE(token);
        uint256 px = IBaseOracle(route).getPrice(token);
        if (px == 0) revert Errors.PRICE_FAILED(token);
        return px;
    }

    /// @notice Return USD price of given token, multiplied by 10**18.
    /// @param token The ERC-20 token to get the price of.
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Return whether the oracle supports underlying token of given wrapper.
    /// @dev Only validate wrappers of Blueberry protocol such as WERC20
    /// @param token ERC1155 token address to check the support
    /// @param tokenId ERC1155 token id to check the support
    function isWrappedTokenSupported(
        address token,
        uint256 tokenId
    ) external view override returns (bool) {
        if (!whitelistedERC1155[token]) return false;
        address uToken = IERC20Wrapper(token).getUnderlyingToken(tokenId);
        return routes[uToken] != address(0);
    }

    /// @notice Return whether the oracle given ERC20 token
    /// @param token The ERC20 token to check the support
    function isTokenSupported(
        address token
    ) external view override returns (bool) {
        address route = routes[token];
        if (route == address(0)) return false;
        try IBaseOracle(route).getPrice(token) returns (uint256 price) {
            return price != 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Return the USD value of given position
     * @param token ERC1155 token address to get collateral value
     * @param id ERC1155 token id to get collateral value
     * @param amount Token amount to get collateral value, based 1e18
     */
    function getPositionValue(
        address token,
        uint256 id,
        uint256 amount
    ) external view override returns (uint256 positionValue) {
        if (!whitelistedERC1155[token])
            revert Errors.ERC1155_NOT_WHITELISTED(token);
        address uToken = IERC20Wrapper(token).getUnderlyingToken(id);
        // Underlying token is LP token, and it always has 18 decimals
        // so skipped getting LP decimals
        positionValue = (_getPrice(uToken) * amount) / 1e18;
    }

    /**
     * @dev Return the USD value of the token and amount.
     * @param token ERC20 token address
     * @param amount ERC20 token amount
     */
    function getTokenValue(
        address token,
        uint256 amount
    ) external view override returns (uint256 debtValue) {
        uint256 decimals = IERC20MetadataUpgradeable(token).decimals();
        debtValue = (_getPrice(token) * amount) / 10 ** decimals;
    }
}
