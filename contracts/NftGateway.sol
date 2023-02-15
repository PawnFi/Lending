// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "./INftGateway.sol";
import "./CTokenInterfaces.sol";

interface INftController {
    function STAKER_ROLE() external view returns(bytes32);
    function grantRole(bytes32 role, address account) external;
}

interface IPToken {
    function pieceCount() external view returns(uint256);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function deposit(uint256[] memory nftIds, uint256 blockNumber) external returns(uint256 tokenAmount);
    function withdraw(uint256[] memory nftIds) external returns(uint256 tokenAmount);
    function convert(uint256[] memory nftIds) external;
}

/**
 * @title Pawnfi's NftGateway Contract
 * @author Pawnfi
 */
contract NftGateway is INftGateway, OwnableUpgradeable, ERC721HolderUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 private constant BASE = 1e18;

    /// @notice transferManager contract address
    address public transferManager;

    /// @notice Get the corresponding nft address through ctoken address 
    mapping(address => address) public override getNft;

    /**
     * @notice lending market info
     * @member pieceCount Fragment amount
     * @member liquidateThreshold Liquidation threshold
     * @member isListed Whether listed for supplying NFT
     */
    struct MarketInfo {
        address market;
        address underlying;
        uint pieceCount;
        uint liquidateThreshold;
        bool isListed;
    }

    /// @notice Get market information corresponding to nft
    mapping(address => MarketInfo) public override marketInfo;
   
    // NFT address => User address => Supplied NFT list
    mapping(address => mapping(address => uint[])) internal _allNfts;

    /// @notice For ctoken transfer validation
    mapping(address => bool) public override transferExemption;

    /// @notice Emitted when register market info
    event RegistryMarket(address indexed nftAddr, address indexed market);

    /// @notice Emitted when update liquidation threshold
    event LiquidateThresholdUpdate(address indexed nftAddr, uint256 oldLiquidateThreshold, uint256 newLiquidateThreshold);

    /// @notice Emitted when update `list out NFT` status
    event ListedUpdate(address indexed nftAddr, bool listed);

    /// @notice Emitted when supply NFT
    event MintNft(address indexed owner, address indexed nftAddr, uint256[] nftAddrs);

    /// @notice Emitted when redeem NFT
    event RedeemNft(address indexed owner, address indexed nftAddr, uint256[] nftAddrs);

    /// @notice Emitted when liquidate NFT
    event LiquidateNft(address indexed borrower, address indexed nftAddr, uint256[] nftAddrs);

    /// @notice Emitted when set exemption from `validation of nft quantity when transferring ctoken`
    event TransferExemption(address indexed recipient, bool exemption);

    /**
     * @notice Initialize contract parameters
     * @param owner_ Owner
     * @param transferManager_ transferManager address
     */
    function initialize(address owner_, address transferManager_) external initializer {
        _transferOwnership(owner_);
        __ERC721Holder_init();
        transferManager = transferManager_;
    }

    /**
     * @notice Register market info
     * @param nftAddrs nft address array
     * @param markets lending market address array
     * @param liquidateThresholds Liquidation threshold array
     */
    function registry(address[] calldata nftAddrs, address[] calldata markets, uint256[] calldata liquidateThresholds) external onlyOwner {
        require(nftAddrs.length == markets.length && markets.length == liquidateThresholds.length, "INCONSISTENT_PARAMS_LENGTH");
        for(uint i = 0; i < nftAddrs.length; i++) {
            _registry(nftAddrs[i], markets[i], liquidateThresholds[i]);
        }
    }

    /**
     * @notice Register market info
     * @param nftAddr nft address array
     * @param market lending market address array
     * @param liquidateThreshold Liquidation threshold array
     */
    function _registry(address nftAddr, address market, uint256 liquidateThreshold) internal {
        getNft[market] = nftAddr;

        address underlying = CNftInterface(market).underlying();
        uint pieceCount = IPToken(underlying).pieceCount();
        require(liquidateThreshold < pieceCount, "the new liquidate threshold exceeds maximum");
        marketInfo[nftAddr] = MarketInfo({
            market: market,
            underlying: underlying,
            pieceCount: pieceCount,
            liquidateThreshold: liquidateThreshold,
            isListed: true
        });
        emit RegistryMarket(nftAddr, market);
    }

    /**
     * @notice Set liquidation threshold
     * @param nftAddr nft address
     * @param newLiquidateThreshold New liquidation threshold
     */
    function setLiquidateThreshold(address nftAddr, uint256 newLiquidateThreshold) external onlyOwner {
        require(newLiquidateThreshold < marketInfo[nftAddr].pieceCount, "the new liquidate threshold exceeds maximum");
        emit LiquidateThresholdUpdate(nftAddr, marketInfo[nftAddr].liquidateThreshold, newLiquidateThreshold);
        marketInfo[nftAddr].liquidateThreshold = newLiquidateThreshold;
    }

    /**
     * @notice Set whether the nft is on the list
     * @param nftAddr nft address
     * @param listed Whether the nft is on the list
     */
    function setListed(address nftAddr, bool listed) external onlyOwner {
        marketInfo[nftAddr].isListed = listed;
        emit ListedUpdate(nftAddr, listed);
    }

    /**
     * @notice Supply nft to lending market
     * @param nftAddr nft contract address
     * @param nftIds nft id list
     */
    function mintNft(address nftAddr, uint[] calldata nftIds) external {
        MarketInfo memory mInfo = marketInfo[nftAddr];
        require(mInfo.isListed, "Nft must be listed");
        require(nftIds.length > 0, "Nft list is null");

        address underlying = mInfo.underlying;
        address market = mInfo.market;
        uint balanceBefore = IERC20Upgradeable(underlying).balanceOf(address(this));

        for(uint i = 0; i < nftIds.length; i++) {
            TransferHelper.transferInNonFungibleToken(transferManager, nftAddr, msg.sender, address(this), nftIds[i]);
            TransferHelper.approveNonFungibleToken(transferManager, nftAddr, address(this), underlying, nftIds[i]);
            _allNfts[nftAddr][msg.sender].push(nftIds[i]);
        }

        IPToken(underlying).deposit(nftIds, type(uint256).max);
        uint balanceAfter = IERC20Upgradeable(underlying).balanceOf(address(this));

        uint amount = balanceAfter - balanceBefore;
        
        _approveMax(underlying, market, amount);
        require(CNftInterface(market).mint(amount) == 0, "mint failed");
        IERC20Upgradeable(market).safeTransfer(msg.sender, IERC20Upgradeable(market).balanceOf(address(this)));
        emit MintNft(msg.sender, nftAddr, nftIds);
    }

    /**
     * @notice Redeem nft
     * @param nftAddr nft contract address
     * @param indexes Index position corresponding to the nft id
     */
    function redeemNft(address nftAddr, uint[] calldata indexes) public {
        MarketInfo memory mInfo = marketInfo[nftAddr];
        address market = mInfo.market;
        address underlying = mInfo.underlying;

        uint256 redeemAmount = indexes.length * mInfo.pieceCount;

        uint[] memory nftIds = _removeNft(nftAddr, msg.sender, indexes);
        require(CNftInterface(market).redeemNft(payable(msg.sender), redeemAmount) == 0, "redeem failed");
        IERC20Upgradeable(underlying).safeTransferFrom(msg.sender, address(this), redeemAmount);
        IPToken(underlying).withdraw(nftIds);

        for(uint i = 0; i < nftIds.length; i++) {
            TransferHelper.transferOutNonFungibleToken(transferManager, nftAddr, address(this), msg.sender, nftIds[i]);
        }
        emit RedeemNft(msg.sender, nftAddr, nftIds);
    }

    /**
     * @notice Redeem nft
     * @param nftAddr nft contract address
     * @param indexes Index position corresponding to the nft id
     * @param deadline Signature expiration time
     * @param approveMax Whether the approval during signature is the maximum value of uint256 true = Max value
     * @param v v
     * @param r r
     * @param s s
     */
    function redeemNftWithPermit(address nftAddr, uint[] calldata indexes, uint deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s) external {
        MarketInfo memory mInfo = marketInfo[nftAddr];
        address underlying = mInfo.underlying;
        uint256 redeemAmount = indexes.length * mInfo.pieceCount;
        uint value = approveMax ? type(uint256).max : redeemAmount;
        IPToken(underlying).permit(msg.sender, address(this), value, deadline, v, r, s);

        redeemNft(nftAddr, indexes);
    }

    /**
     * @notice Remove NFT
     * @param nftAddr nft address
     * @param account User address
     * @param indexes Index list
     * @return nftList nft list
     */
    function _removeNft(address nftAddr, address account, uint[] memory indexes) internal returns (uint[] memory nftList) {
        uint[] storage userNfts = _allNfts[nftAddr][account];
        uint length = indexes.length;
        require(length <= userNfts.length, "INCONSISTENT_PARAMS_LENGTH");

        nftList = new uint[](length);
        
        for(uint i = length; i > 0; i--) {
            uint index = indexes[i - 1];
            require(index < userNfts.length, "Index out of bound");
            if(i >= 2) {
                require(index > indexes[i - 2], "Order error for index");
            }
            
            nftList[i - 1] = userNfts[index];
            userNfts[index] = userNfts[userNfts.length - 1];
            userNfts.pop();
        }
        return nftList;
    }

    /** 
     * @notice Liquidate nft
     * @param borrower Borrower address
     */
    function liquidateNft(address borrower) external override {
        address nftAddr = getNft[msg.sender];
        require(nftAddr != address(0), "caller isn't market address");

        MarketInfo memory mInfo = marketInfo[nftAddr];

        uint nftCount = _allNfts[nftAddr][borrower].length;
        uint tokenBalance = holdBalanceOfUnderling(msg.sender, borrower);

        uint currentCount = tokenBalance / mInfo.pieceCount;

        if(currentCount < nftCount) {
            currentCount = tokenBalance % mInfo.pieceCount >= mInfo.liquidateThreshold ? currentCount + 1 : currentCount;

            uint liquidateCount = nftCount - currentCount;
            if(liquidateCount > 0) {
                uint[] memory indexes = new uint[](liquidateCount);
                for(uint i = 0; i < liquidateCount; i++) {
                    indexes[i] = nftCount - liquidateCount + i;
                }
                uint[] memory nftIds = _removeNft(nftAddr, borrower, indexes);
                IPToken(mInfo.underlying).convert(nftIds);
                emit LiquidateNft(borrower, nftAddr, nftIds);
            }
        }
    }

    /**
     * @notice Check balance of underlying token
     * @param market ctoken address
     * @param account User address
     */
    function holdBalanceOfUnderling(address market, address account) internal view returns (uint256) {
        uint exchangeRate = CTokenInterface(market).exchangeRateStored();
        uint ctokenBalance = CTokenInterface(market).balanceOf(account);
        return exchangeRate * ctokenBalance / BASE;
    }

    /**
     * @notice Get the list of user's supplied NFTs
     * @param nftAddr nft address
     * @param account User address
     * @return nftList nft id list
     */
    function getNfts(address nftAddr, address account) external view override returns (uint[] memory nftList) {
        uint length = _allNfts[nftAddr][account].length;
        nftList = new uint[](length);
        for(uint i = 0; i < length; i++) {
            nftList[i] = _allNfts[nftAddr][account][i];
        }
    }

    /**
     * @notice Adjust the order of NFTs to prevent rare NFTs from being liquidated
     * @param nftAddr nft address
     * @param indexes Array of adjusted indices
     */
    function adjustOrderForNft(address nftAddr, uint[] calldata indexes) external {
        uint[] storage nftIds = _allNfts[nftAddr][msg.sender];
        uint[] memory nftArrary = nftIds;

        uint256 length = indexes.length;
        require(length == nftIds.length, "INCONSISTENT_PARAMS_LENGTH");
        bool[] memory duplicates = new bool[](length);

        for(uint i = 0; i < length; i++) {
            require(indexes[i] < length, "Index out of bound");
            require(!duplicates[indexes[i]], "Duplicate index"); // duplicate index
            nftIds[i] = nftArrary[indexes[i]];
            duplicates[indexes[i]] = true;
        }
    }

    /**
     * @notice Max amount of token approval
     * @param token token address
     * @param target Approved address
     * @param amount Approved amount
     */
    function _approveMax(address token, address target, uint256 amount) internal {
        uint allowance = IERC20Upgradeable(token).allowance(address(this), target);
        if(amount > allowance) {
            IERC20Upgradeable(token).safeApprove(target, 0);
            IERC20Upgradeable(token).safeApprove(target, type(uint256).max);
        }
    }

    /**
     * @notice Set exemption from validation of nft quantity when transferring ctoken
     * @param recipient Receiver address
     * @param newExemption Whether there is an exemption
     */
    function setTransferExemption(address recipient, bool newExemption) external onlyOwner {
        transferExemption[recipient] = newExemption;
        emit TransferExemption(recipient, newExemption);
    }

    /**
     * @notice Redeem verification
     * @param market ctoken address
     * @param account User address
     * @param redeemTokens Redeemed ctoken
     * @param redeemAmount Redeemed asset amount
     */
    function redeemVerify(address market, address account, uint256 redeemTokens, uint256 redeemAmount) external override returns (bool) {
        require(redeemTokens == 0 || redeemAmount == 0, "one of redeemTokens or redeemAmount must be zero");
        CTokenInterface(market).accrueInterest();
        uint exchangeRate = CTokenInterface(market).exchangeRateStored();
        uint ctokenBalance = CTokenInterface(market).balanceOf(account);
        
        if(redeemTokens > 0) {
            ctokenBalance = ctokenBalance - redeemTokens;
        }
        uint256 balance = exchangeRate * ctokenBalance / BASE;
        uint surplus = balance - redeemAmount;

        address nftAddr = getNft[market];
        uint nftCount = _allNfts[nftAddr][account].length;
        
        uint pieceCount = marketInfo[nftAddr].pieceCount;
        uint accrualNftCount = pieceCount * nftCount;
        return surplus >= accrualNftCount;
    }
}

interface ITransferManager {
    function getInputData(address nftAddress, address from, address to, uint256 tokenId, bytes32 operateType) external view returns (bytes memory data);
}

library TransferHelper {

    using AddressUpgradeable for address;

    // keccak256("TRANSFER_IN")
    bytes32 private constant TRANSFER_IN = 0xe69a0828d85fdb5875ad77f7b8a0e2275447a64f18daaf58f34b3af9b7b691da;
    // keccak256("TRANSFER_OUT")
    bytes32 private constant TRANSFER_OUT = 0x2b6780fa84213a97faf5c6208861692a9b75df0c4afffad07a2dc98411dfe785;
    // keccak256("APPROVAL")
    bytes32 private constant APPROVAL = 0x2acd155ba8c67e9321668716d05aae1ff9e47e502b6b2f301b6f41e3a57ee2ef;

    /**
     * @notice Transfer in NFT
     * @param transferManager nft transfer manager contract address
     * @param nftAddr nft address
     * @param from Sender address
     * @param to Receiver address
     * @param nftId NFT ID   
     */
    function transferInNonFungibleToken(address transferManager, address nftAddr, address from, address to, uint256 nftId) internal {
        bytes memory data = ITransferManager(transferManager).getInputData(nftAddr, from, to, nftId, TRANSFER_IN);
        nftAddr.functionCall(data);
    }

    /**
     * @notice Transfer in NFT
     * @param transferManager nft transfer manager contract address
     * @param nftAddr nft address
     * @param from Sender address
     * @param to Receiver address
     * @param nftId NFT ID   
     */
    function transferOutNonFungibleToken(address transferManager, address nftAddr, address from, address to, uint256 nftId) internal {
        bytes memory data = ITransferManager(transferManager).getInputData(nftAddr, from, to, nftId, TRANSFER_OUT);
        nftAddr.functionCall(data);
    }

    /**
     * @notice Approve NFT
     * @param transferManager nft transfer manager contract address
     * @param nftAddr nft address
     * @param from Sender address
     * @param to Receiver address
     * @param nftId NFT ID   
     */
    function approveNonFungibleToken(address transferManager, address nftAddr, address from, address to, uint256 nftId) internal {
        bytes memory data = ITransferManager(transferManager).getInputData(nftAddr, from, to, nftId, APPROVAL);
        nftAddr.functionCall(data);
    }
}