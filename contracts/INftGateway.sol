// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;


interface INftGateway {
    function marketInfo(address nft) external view returns (address, address, uint256, uint256, bool);
    function getNft(address cToken) external view returns (address);
    function getNfts(address nft, address account) external view returns (uint[] memory nftList);

    function liquidateNft(address) external;
    function transferExemption(address) external view returns (bool);
    function redeemVerify(address, address, uint256, uint256) external returns (bool);
}