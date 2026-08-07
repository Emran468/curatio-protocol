// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";

// Minimal MockToken implementation inlined to avoid import path issues for Echidna tests
contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CuratioRebalancerEchidnaTest {
    CuratioRebalancer public rebalancer;
    MockToken public token0;
    MockToken public token1;

    // Echidna-র জন্য কিছু টেস্ট এড্রেস (Actors)
    address public admin = address(0x10000);
    address public vault = address(0x20000);
    address public hook = address(0x30000);
    address public poolManager = address(0x40000);

    constructor() {
        // ১. টেস্ট টোকেন ডিপ্লয়
        token0 = new MockToken("Token 0", "TK0");
        token1 = new MockToken("Token 1", "TK1");

        // Uniswap v4-এর নিয়ম অনুযায়ী token0 এর এড্রেস সবসময় token1-এর চেয়ে ছোট হতে হয়
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // ২. রিব্যালেন্সার কন্ট্রাক্ট ডিপ্লয়
        rebalancer = new CuratioRebalancer(
            poolManager,
            hook,
            vault,
            address(this), // এই কন্ট্রাক্টটিকেই এডমিন হিসেবে রাখা হলো
            1 ether
        );

        // ৩. প্রাথমিক ব্যালেন্স এবং মিন্টিং সেটআপ
        token0.mint(vault, 100_000 ether);
        token1.mint(vault, 100_000 ether);
    }

    // ── Echidna-র জন্য হেলপার ফাংশন ────────────────────────────────

    /// @notice Echidna র্যান্ডম अमाउंट দিয়ে Threshold টেস্ট করবে
    function setThreshold(uint256 amount) external {
        rebalancer.setRebalanceThreshold(amount);
    }

    // ── Invariants (যে শর্তগুলো Echidna সব সময় সত্য কিনা চেক করবে) ─────

    /// @notice Property: Vault এড্রেস কখনোই address(0) হতে পারবে না
    function echidna_vault_is_valid() public view returns (bool) {
        return rebalancer.vault() != address(0);
    }

    /// @notice Property: Threshold মান সবসময় ০-এর চেয়ে বড় হতে হবে
    function echidna_threshold_nonzero() public view returns (bool) {
        return rebalancer.rebalanceThreshold() > 0;
    }
}
