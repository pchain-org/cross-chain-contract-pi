// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IERC721Minter {
    function mint(address to, string memory tokenURI) external;

    function burn(uint256 tokenId) external;

    function replaceMinter(address newMinter) external;
}