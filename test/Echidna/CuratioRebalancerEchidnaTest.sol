// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// Minimal MockToken (inline, avoids import path issues under Echidna)
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

/// @dev Minimal mock so rebalanceLiquidity()'s unlock/modifyLiquidity/sync/
///      settle/take path can actually execute under fuzzing instead of
///      hitting a no-code address. Always returns zero deltas — sufficient
///      to exercise CuratioRebalancer's own state transitions and
///      invariants; it does NOT validate real AMM math (that belongs to
///      CuratioHook's own Echidna suite).
contract MockPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency, address, uint256) external {}
}

/// @dev Vault actor wrapper — lets Echidna drive notifyDeposit/notifyWithdraw
///      as the actual `vault` address, since CuratioRebalancer gates those
///      behind `onlyVault` (msg.sender == vault). Calling directly from the
///      test contract itself would always revert with NotVault.
contract VaultActor {
    CuratioRebalancer public immutable rebalancer;

    constructor(CuratioRebalancer _rebalancer) {
        rebalancer = _rebalancer;
    }

    function notifyDeposit(uint256 assets) external {
        rebalancer.notifyDeposit(assets);
    }

    function notifyWithdraw(uint256 assets) external {
        rebalancer.notifyWithdraw(assets);
    }
}

contract CuratioRebalancerEchidnaTest {
    CuratioRebalancer public rebalancer;
    MockToken public token0;
    MockToken public token1;
    MockPoolManager public mockPoolManager;
    VaultActor public vaultActor;

    address public hook = address(0x30000);
    uint256 public constant INITIAL_THRESHOLD = 1 ether;

    constructor() {
        token0 = new MockToken("Token 0", "TK0");
        token1 = new MockToken("Token 1", "TK1");
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        mockPoolManager = new MockPoolManager();

        // Deploy the rebalancer first with a placeholder vault, then deploy
        // VaultActor pointing at it, then re-point vault via setVault — this
        // avoids a circular-construction problem (VaultActor needs the
        // rebalancer's address, but the rebalancer's constructor needs a
        // real vault address up front).
        rebalancer = new CuratioRebalancer(
            address(mockPoolManager),
            hook,
            address(this), // temporary placeholder vault == this test contract
            address(this), // admin == this test contract
            INITIAL_THRESHOLD
        );

        vaultActor = new VaultActor(rebalancer);
        rebalancer.setVault(address(vaultActor));

        token0.mint(address(vaultActor), 100_000 ether);
        token1.mint(address(vaultActor), 100_000 ether);
    }

    // ── Fuzzed actions ────────────────────────────────────────────────

    /// @notice Fuzzes strategist threshold changes. This contract holds
    ///         STRATEGIST_ROLE (granted to `admin` == address(this) in the
    ///         constructor), so this call succeeds directly.
    function setThreshold(uint256 amount) external {
        uint256 bounded = (amount % 1000 ether) + 1; // keep > 0, matches contract's own invariant
        rebalancer.setRebalanceThreshold(bounded);
    }

    /// @notice Fuzzes the admin-only min-blocks-between-rebalances setting.
    function setMinBlocks(uint256 blocks_) external {
        uint256 bounded = blocks_ % 1000;
        rebalancer.setMinBlocksBetweenRebalances(bounded);
    }

    /// @notice Fuzzes deposit notifications, routed through the real vault
    ///         actor so `onlyVault` passes.
    function notifyDeposit(uint256 amount) external {
        uint256 bounded = amount % 10_000 ether;
        vaultActor.notifyDeposit(bounded);
    }

    /// @notice Fuzzes withdraw notifications the same way.
    function notifyWithdraw(uint256 amount) external {
        uint256 bounded = amount % 10_000 ether;
        vaultActor.notifyWithdraw(bounded);
    }

    /// @notice Fuzzes managed-pool configuration (admin-only).
    function setManagedPool(uint24 fee, int24 tickSpacing) external {
        int24 spacing = int24(int256(bound24(tickSpacing, 1, 200)));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        rebalancer.setManagedPool(key);
    }

    /// @notice Fuzzes the strategist-only rebalance execution path against
    ///         the MockPoolManager, exercising tick-range validation and
    ///         the full unlock/callback/settle flow.
    function rebalanceLiquidity(int24 tickLowerRaw, int24 tickUpperRaw, int256 liquidityToMove) external {
        if (!rebalancer.poolConfigured()) return; // must configure a pool first via setManagedPool

        int24 tickLower = int24(bound24(tickLowerRaw, -887220, 887200));
        int24 tickUpper = int24(bound24(tickUpperRaw, tickLower + 1, 887220));

        int256 boundedLiquidity = liquidityToMove % 1_000_000 ether;

        rebalancer.rebalanceLiquidity(tickLower, tickUpper, boundedLiquidity);
    }

    /// @dev Simple modulo-based bounding helper for int24 fuzz inputs.
    function bound24(int24 x, int24 min, int24 max) internal pure returns (int24) {
        if (min >= max) return min;
        int256 range = int256(max) - int256(min) + 1;
        int256 wrapped = int256(x) % range;
        if (wrapped < 0) wrapped += range;
        return int24(min + wrapped);
    }

    // ── Invariants ────────────────────────────────────────────────────

    /// @notice Vault address must never become the zero address (setVault
    ///         itself reverts on zero, but this confirms no other path
    ///         can corrupt it).
    function echidna_vault_is_valid() public view returns (bool) {
        return rebalancer.vault() != address(0);
    }

    /// @notice Hook address must never become the zero address.
    function echidna_hook_is_valid() public view returns (bool) {
        return address(rebalancer.hook()) != address(0);
    }

    /// @notice Rebalance threshold must always stay strictly positive —
    ///         both the constructor and setRebalanceThreshold enforce this,
    ///         so a violation here would mean a bypass exists.
    function echidna_threshold_nonzero() public view returns (bool) {
        return rebalancer.rebalanceThreshold() > 0;
    }

    /// @notice Once a pool is configured, the active tick range must
    ///         always be a valid (lower < upper) range after any
    ///         successful rebalance — this mirrors the InvalidTickRange
    ///         guard inside rebalanceLiquidity() itself.
    function echidna_tick_range_valid_when_set() public view returns (bool) {
        int24 lower = rebalancer.currentTickLower();
        int24 upper = rebalancer.currentTickUpper();
        // Initial state (both zero, before any rebalance) is a valid
        // exception — the contract starts with lower == upper == 0.
        if (lower == 0 && upper == 0) return true;
        return lower < upper;
    }

    /// @notice lastRebalanceBlock can never be in the future relative to
    ///         the current block — would indicate corrupted state.
    function echidna_last_rebalance_not_future() public view returns (bool) {
        return rebalancer.lastRebalanceBlock() <= block.number;
    }
}