// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./CTokenInterfaces.sol";

interface ICErc20 {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function underlying() external view returns (address);
}

interface IPriceOracleGetter {
    function WETH() external view returns (address);

    function getAssetPrice(address asset) external view returns (uint256);
}

/**
 * @title Pawnfi's MultipleSourceAdvanceOracle Contract
 * @author Pawnfi
 */
contract MultipleSourceAdvanceOracle is Ownable {

    /// @notice WETH address
    address public WETH;

    /// @notice fallbackOracle contract address
    IPriceOracleGetter public fallbackOracle;

    /// @notice Emitted when update fallbackOracle
    event FallbackOracleUpdated(address indexed fallbackOracle);

    /// @notice Emitted when update asset ptice source
    event AssetSourceUpdated(address indexed asset, address indexed source);

    /**
     * @dev Price unit
     */
    enum PriceUnit { USD, ETH }

    /**
     * @notice Asset price info
     * @member fragment Fragment
     * @member assetSource Asset price source addrexx
     * @member priceUnit Price unit
     */
    struct AssetSourceInfo {
        uint256 fragment;
        address assetSource;
        PriceUnit priceUnit;
    }

    /// @notice  Asset price source
    mapping(address => AssetSourceInfo) public assetSourceInfos;

    /**
     * @notice Initialize parameters
     * @param fallbackOracle_ FallbackOracle contract address
     * @param ethSource_ ethSource address
     * @param assets_ Asset address array
     * @param assetSourceInfos_ assetSource info array
     */
    constructor(address owner_, address fallbackOracle_, address ethSource_,  address[] memory assets_, AssetSourceInfo[] memory assetSourceInfos_) {
        WETH = IPriceOracleGetter(fallbackOracle_).WETH();
        _setFallbackOracle(fallbackOracle_);
        AssetSourceInfo memory assetSourceInfo = AssetSourceInfo({
            fragment: 1,
            assetSource: ethSource_,
            priceUnit: PriceUnit.USD
        });
        _setAssetSource(WETH, assetSourceInfo);
        _setAssetSources(assets_, assetSourceInfos_);

        _transferOwnership(owner_);
    }

    /**
     * @notice Set FallbackOracle contract
     * @param newFallbackOracle FallbackOracle contract address
     */
    function setFallbackOracle(address newFallbackOracle) external onlyOwner {
        _setFallbackOracle(newFallbackOracle);
    }

    /**
     * @notice Set FallbackOracle contract
     * @param newFallbackOracle FallbackOracle contract address
     */
    function _setFallbackOracle(address newFallbackOracle) internal {
        fallbackOracle = IPriceOracleGetter(newFallbackOracle);
        emit FallbackOracleUpdated(newFallbackOracle);
    }

    /**
     * @notice Batch set asset price source info
     * @param assets Asset address array
     * @param newAssetSourceInfos Corresponding asset info array
     */
    function setAssetSources(address[] calldata assets, AssetSourceInfo[] calldata newAssetSourceInfos) external onlyOwner {
        _setAssetSources(assets, newAssetSourceInfos);
    }

    /**
     * @notice Batch set asset price source info
     * @param assets Asset address array
     * @param newAssetSourceInfos Corresponding asset info array
     */
    function _setAssetSources(address[] memory assets, AssetSourceInfo[] memory newAssetSourceInfos) internal {
        require(assets.length == newAssetSourceInfos.length, "INCONSISTENT_PARAMS_LENGTH");
        for(uint i = 0; i < assets.length; i++) {
            _setAssetSource(assets[i], newAssetSourceInfos[i]);
        }
    }

    /**
     * @notice Set single asset price source info
     * @param asset Asset address
     * @param newAssetSourceInfo Asset price source info
     */
    function _setAssetSource(address asset, AssetSourceInfo memory newAssetSourceInfo) internal {
        assetSourceInfos[asset] = newAssetSourceInfo;
        emit AssetSourceUpdated(asset, newAssetSourceInfo.assetSource);
    }

    /**
     * @notice Get lend market asset price (in USD)
     * @param cToken cToken address
     * @return asset price
     */
    function getUnderlyingPrice(address cToken) public view returns (uint256) {
        address asset = underlyingAddress(cToken);
        require(asset != address(0), "asset is zero address");
        uint256 assetPrice = getAssetPrice(asset);
        uint256 decimals = ICErc20(asset).decimals();
        return uint256(1e18) * assetPrice / (10**decimals);
    }

    /**
     * @notice Get lend market asset
     * @param cToken cToken address
     * @return Asset address
     */
    function underlyingAddress(address cToken) public view returns (address) {
        return compareStrings(ICErc20(cToken).symbol(), "iETH") ? WETH : ICErc20(cToken).underlying();
    }

    /**
     * @notice Get ETH price in usd
     * @return uint256 ETH price
     */
    function getETHUSDPrice() public view returns (uint256) {
        AggregatorV3Interface ethSource = AggregatorV3Interface(assetSourceInfos[WETH].assetSource);
        // uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ( , int256 price, , , ) = ethSource.latestRoundData();
        uint256 decimals = ethSource.decimals();
        return uint256(price) * 10**(18 - decimals);
    }

    /**
     * @notice Return asset price
     * @param asset asset address
     * @return price asset price
     */
    function getAssetPrice(address asset) public view returns (uint256 price) {
        AssetSourceInfo memory assetSourceInfo = assetSourceInfos[asset];
        if(assetSourceInfo.assetSource != address(0)) {
            // uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
            ( , int256 chainlinkPrice, , , ) = AggregatorV3Interface(assetSourceInfo.assetSource).latestRoundData();
            if(chainlinkPrice > 0) {
                price = uint256(chainlinkPrice);
                uint256 decimals = AggregatorV3Interface(assetSourceInfo.assetSource).decimals();
                price = price * 10**(18 - decimals);
                if(assetSourceInfo.priceUnit == PriceUnit.USD) {
                    return price / assetSourceInfo.fragment;
                }
            }
        } else {
            price = fallbackOracle.getAssetPrice(asset) * assetSourceInfo.fragment;
        }
        return getETHUSDPrice() * price / 1e18 / assetSourceInfo.fragment;
    }
    
    /**
     * @notice Compare strings
     * @param a String a
     * @param b String b
     * @return String comparison true = identical false = different
     */
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
