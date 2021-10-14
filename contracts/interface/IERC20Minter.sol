// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IERC20Minter {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;

    function replaceMinter(address newMinter) external;
}