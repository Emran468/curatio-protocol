// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 ether);
    }

    // Echidna যেন র্যান্ডমলি টোকেন মিন্ট করতে পারে
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}