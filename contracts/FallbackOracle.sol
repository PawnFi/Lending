// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";

/**
 * @title Pawnfi's FallbackOracle Contract
 * @author Pawnfi
 */
contract FallbackOracle is AccessControl {

    uint256 private constant BASE = 1e18;

    // keccak256("FEEDER_ROLE")
    bytes32 private constant FEEDER_ROLE = 0x80a586cc4ecf40a390b370be075aa38ab3cc512c5c1a7bc1007974dbdf2663c7;

    /// @notice WETH contract address
    address public immutable WETH;

    /// @notice factory contract address
    address public immutable uniswapV3Factory;

    /// @notice Time interval
    uint32 public twapInterval;

    /// @notice lastest price weight
    uint256 public lastestPriceWeight = 0.7e18;

    /// @notice previous price weight
    uint256 public previousPriceWeight = 0.3e18;

    /**
     * @notice Price data
     * @member price Price
     * @member timestamp Timestamp
     */
    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    /**
     * @notice Price feed info
     * @member weight Weight
     * @member roundId Price feed count
     * @member priceData Price data
     */
    struct PriceFeed {
        uint256 roundId;
        uint256 weight;
        mapping(uint256 => PriceData) priceData;
    }

    // Corresponding price feed
    mapping(address => PriceFeed) private _priceFeed;

    /// @notice Emitted when price feed
    event AssetPriceUpdated(address indexed asset, uint256 price, uint256 roundId);

    /// @notice Emitted when update feed price weight
    event FeedWeightUpdated(address indexed asset, uint256 oldWeight, uint256 newWeight);

    /// @notice Emitted when update price weight
    event PriceWeightUpdated(uint256 lastestPriceWeight, uint256 previousPriceWeight);

    /// @notice Emitted when update time interval
    event TwapIntervalUpdated(uint256 oldTwapInterval, uint256 newTwapInterval);


    /**
     * @notice Initialize parameters
     * @param WETH_ weth address
     * @param uniswapV3Factory_ uniswap v3 factory_address
     * @param twapInterval_ TIme interval
     */
    constructor(address admin_, address WETH_, address uniswapV3Factory_, uint32 twapInterval_) {
        _setupRole(DEFAULT_ADMIN_ROLE, admin_);
        _setupRole(FEEDER_ROLE, admin_);

        WETH = WETH_;
        uniswapV3Factory = uniswapV3Factory_;
        twapInterval = twapInterval_;
    }

    /**
     * @notice Set time interval
     * @param newTwapInterval Time interval
     */
    function setTwapInterval(uint32 newTwapInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint oldTwapInterval = twapInterval;
        emit TwapIntervalUpdated(oldTwapInterval, newTwapInterval);
        twapInterval = newTwapInterval;
    }

    /**
     * @notice Set price feed weight
     * @param asset Asset
     * @param newWeight Weight
     */
    function setFeedWeight(address asset, uint256 newWeight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newWeight <= BASE);
        uint256 oldWeight = _priceFeed[asset].weight;
        emit FeedWeightUpdated(asset, oldWeight, newWeight);
        _priceFeed[asset].weight = newWeight;
    }

    /**
     * @notice Set price weight
     * @param newLastestPriceWeight lastest price weight
     * @param newPreviousPriceWeight previous price weight
     */
    function setPriceWeight(uint256 newLastestPriceWeight, uint256 newPreviousPriceWeight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newLastestPriceWeight + newPreviousPriceWeight == BASE);
        lastestPriceWeight = newLastestPriceWeight;
        previousPriceWeight = newPreviousPriceWeight;
        emit PriceWeightUpdated(newLastestPriceWeight, newPreviousPriceWeight);
    }

    /**
     * @notice Get asset price
     * @param asset Asset address
     * @return Price feed count
     * @return Price feed weight
     * @return Price
     * @return Timestamp
     */
    function getNewestAssetPriceData(address asset) public view returns (uint256, uint256, uint256, uint256) {
        uint256 roundId = _priceFeed[asset].roundId;
        return getRoundAssetPriceData(asset, roundId);
    }

    /**
     * @notice Get specified asset pirce based on Round ID
     * @param asset Asset address
     * @param roundId Round ID
     * @return Price feed count
     * @return Price feed weight
     * @return Price
     * @return Timestamp
     */
    function getRoundAssetPriceData(address asset, uint256 roundId) public view returns (uint256, uint256, uint256, uint256) {
        PriceFeed storage priceFeed = _priceFeed[asset];
        PriceData memory priceData = priceFeed.priceData[roundId];
        return (priceFeed.roundId, priceFeed.weight, priceData.price, priceData.timestamp);
    }

    /**
     * @notice Set asset price
     * @param asset asset address
     * @param price Asset price
     */
    function setAssetPriceData(address asset, uint256 price) external onlyRole(FEEDER_ROLE) {
        _setAssetPriceData(asset, price);
    }

    /**
     * @notice Batch set asset price
     * @param assets Asset address array
     * @param prices Asset price array
     */
    function setMultipleAssetPriceData(address[] calldata assets, uint256[] calldata prices) external onlyRole(FEEDER_ROLE) {
        require(assets.length == prices.length, "INCONSISTENT_PARAMS_LENGTH");
        for(uint i = 0; i < assets.length; i++) {
            _setAssetPriceData(assets[i], prices[i]);
        }
    }
    /**
     * @notice Set asset price
     * @param asset asset address
     * @param price Asset price
     */
    function _setAssetPriceData(address asset, uint256 price) private {
        uint256 roundId = ++_priceFeed[asset].roundId;
        _priceFeed[asset].priceData[roundId] = PriceData({
            price: price,
            timestamp: block.timestamp
        });
        emit AssetPriceUpdated(asset, price, roundId);
    }

    /**
     * @notice Get weighted price
     * @param asset asset address
     * @return Weighted price
     */
    function feedTawpPrice(address asset) public view returns (uint256) {
        uint256 roundId = _priceFeed[asset].roundId;
        if(roundId < 2) {
            ( , , uint newestPrice, ) = getNewestAssetPriceData(asset);
            return newestPrice;
        }
        ( , , uint currentPrice, ) = getRoundAssetPriceData(asset, roundId);
        ( , , uint previousPrice, ) = getRoundAssetPriceData(asset, roundId - 1);
        return (currentPrice * lastestPriceWeight / BASE) + (previousPrice * previousPriceWeight / BASE);
    }

    /**
     * @notice Get weighted average price from Uniswap
     * @param asset Asset address
     * @return Weighted price
     */
    function uniswapTwapPrice(address asset) public view returns (uint256) {
        uint256 length = 6;
        uint32[] memory secondsAgos = new uint32[](length);
        for(uint8 i = 0; i < length; i++) {
            secondsAgos[i] = uint32(twapInterval * (length - i - 1));
        }

        (address token0, address token1) = asset < WETH ? (asset, WETH) : (WETH, asset);
        address pool = IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, 3000);
        if(pool == address(0)) {
            return 0;
        }
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);

        uint256 token0Decimals = IERC20Metadata(token0).decimals();
        uint256 token1Decimals = IERC20Metadata(token1).decimals();

        // tick(imprecise as it's an integer) to price
        uint160[] memory sqrtPricesX96 = new uint160[](length - 1);
        uint256 totalPrice = 0;
        for(uint8 i = 0; i < length - 1; i++) {
            sqrtPricesX96[i] = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[i + 1] - tickCumulatives[i]) / int56(uint56(twapInterval)))
            );
            uint256 priceX96 = FullMath.mulDiv(sqrtPricesX96[i], sqrtPricesX96[i], FixedPoint96.Q96);
            uint256 normalPrice = FullMath.mulDiv(priceX96, 10**token0Decimals, FixedPoint96.Q96);
            totalPrice += FullMath.mulDiv(normalPrice, BASE, 10**token1Decimals);
        }

        uint256 price = totalPrice / (length - 1);

        if(WETH != token1) {
            price = 1e36 / price;
        }
        return price;
    }
    
    /**
     * @notice Get asset price
     * @param asset Asset address
     * @return assetPrice Asset price
     */
    function getAssetPrice(address asset) external view returns (uint256 assetPrice) {
        uint256 feedPrice = feedTawpPrice(asset);
        uint256 feedWeight = _priceFeed[asset].weight;
        assetPrice = feedPrice * feedWeight;
        
        uint256 anotherWeight = BASE - feedWeight;
        if(anotherWeight > 0) {
            uint256 uniswapPrice = uniswapTwapPrice(asset);
            assetPrice += (uniswapPrice * anotherWeight);
        }
        assetPrice = assetPrice / BASE;
    }

}