// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20FixedSupply is ERC20 {
    constructor() public ERC20("GameItem", "GI") {
        _mint(msg.sender, 1000);
    }
}
