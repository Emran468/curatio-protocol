// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 (inline, avoids import path issues under Echidna).
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

/// @dev Fixed-price (tick 0) hook: TWAP is always available and equals price 1.
contract MockHook {
    function getCurrentFee(PoolKey calldata) external pure returns (uint24) {
        return 3000;
    }

    function getPoolState(PoolKey calldata) external pure returns (int24, uint24, uint64, uint64, bool) {
        return (0, 3000, 0, 0, true);
    }

    function getTwapTick(PoolKey calldata, uint32) external pure returns (int24) {
        return 0;
    }
}

/// @dev Mock PoolManager that keeps REAL position bookkeeping so invariants can compare the
///      rebalancer's tracked state with ground truth:
///      - modifyLiquidity updates per-position liquidity and reverts on over-removal (like v4).
///      - Liquidity changes return ZERO token deltas (no AMM math; that is covered by the Foundry
///        real-PoolManager tests).
///      - swap is exact-output at price 1 with no fee (matches MockHook's TWAP), so the rebalancer's
///        unwind/cover-deficit path is reachable.
///      - take() mints tokens to the receiver (stands in for the pool paying out).
contract MockPoolManager {
    mapping(bytes32 => uint128) private _positionLiquidity;
    uint256 public totalLiquidity;

    function _key(address owner, int24 lo, int24 hi, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, lo, hi, salt));
    }

    function liquidityOf(address owner, int24 lo, int24 hi) external view returns (uint128) {
        return _positionLiquidity[_key(owner, lo, hi, bytes32(0))];
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata p, bytes calldata)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        bytes32 k = _key(msg.sender, p.tickLower, p.tickUpper, p.salt);
        if (p.liquidityDelta >= 0) {
            uint128 add = uint128(uint256(p.liquidityDelta));
            _positionLiquidity[k] += add;
            totalLiquidity += add;
        } else {
            uint128 rem = uint128(uint256(-p.liquidityDelta));
            require(_positionLiquidity[k] >= rem, "MockPM: remove > position");
            _positionLiquidity[k] -= rem;
            totalLiquidity -= rem;
        }
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function swap(PoolKey calldata, SwapParams calldata p, bytes calldata) external pure returns (BalanceDelta) {
        require(p.amountSpecified > 0, "MockPM: exact-out only");
        int128 out = int128(p.amountSpecified);
        // zeroForOne: pay token0, receive token1. Otherwise the reverse. Price 1, no fee.
        return p.zeroForOne ? toBalanceDelta(-out, out) : toBalanceDelta(out, -out);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        MockToken(Currency.unwrap(currency)).mint(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Actors (the rebalancer gates these behind msg.sender checks)
// ─────────────────────────────────────────────────────────────────────────────

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

    function returnToVault(uint256 amount) external {
        rebalancer.returnToVault(amount);
    }
}

contract KeeperActor {
    CuratioRebalancer public immutable rebalancer;

    constructor(CuratioRebalancer _rebalancer) {
        rebalancer = _rebalancer;
    }

    function performUpkeep(bytes calldata data) external {
        rebalancer.performUpkeep(data);
    }
}

/// @dev Has no roles. Every call below MUST revert.
contract Attacker {
    CuratioRebalancer public immutable rebalancer;

    constructor(CuratioRebalancer _rebalancer) {
        rebalancer = _rebalancer;
    }

    /// @return succeeded true if ANY privileged call went through (that would be a bug).
       function probe(address newVault) external returns (bool succeeded) {
        try rebalancer.rebalanceLiquidity(-60, 60, 1, 0, 0) {
            return true;
        } catch {}
        try rebalancer.returnToVault(1) {
            return true;
        } catch {}
        try rebalancer.performUpkeep(abi.encode(int24(0), false)) {
            return true;
        } catch {}
        try rebalancer.notifyDeposit(1 ether) {
            return true;
        } catch {}
        try rebalancer.setVault(newVault) {
            return true;
        } catch {}
        try rebalancer.setKeeperMaxPay(type(uint256).max, type(uint256).max) {
            return true;
        } catch {}
        try rebalancer.setAsset(newVault) {
            return true;
        } catch {}
        try rebalancer.proposeHook(newVault) {
            return true;
        } catch {}
        try rebalancer.executeHook() {
            return true;
        } catch {}
        try rebalancer.cancelHookProposal() {
            return true;
        } catch {}
        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Echidna test
// ─────────────────────────────────────────────────────────────────────────────

contract CuratioRebalancerEchidnaTest {
    uint256 public constant INITIAL_THRESHOLD = 1 ether;
    uint256 public constant DEFAULT_AMOUNT = 1000 ether;
    int256 internal constant MAX_TICK_ABS = 887272;

    CuratioRebalancer public rebalancer;
    MockToken public token0;
    MockToken public token1;
    MockPoolManager public pm;
    MockHook public mockHook;
    VaultActor public vaultActor;
    KeeperActor public keeperActor;
    Attacker public attacker;

    /// @dev Tick spacing of the currently configured pool (kept in sync with the rebalancer).
    int24 public poolSpacing;

    // Failure flags: set inside actions, read by invariants.
    bool public unexpectedRevert; // a call that must succeed reverted
    bool public accountingBroken; // a post-condition was violated
    bool public accessControlBroken; // an unprivileged call succeeded

    // Reachability counters (used by the canary properties).
    uint256 public successfulRebalances;
    uint256 public successfulKeeperRebalances;
    uint256 public successfulReturns;
    uint256 public successfulUnwinds;
    uint256 public successfulPoolChanges;
    uint256 public successfulAssetChanges;
    uint256 public assetChangesBlocked;

    constructor() {
        token0 = new MockToken("Token 0", "TK0");
        token1 = new MockToken("Token 1", "TK1");
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        pm = new MockPoolManager();
        mockHook = new MockHook();

        // placeholders for vault and automation registry, re-pointed below (circular construction)
        rebalancer = new CuratioRebalancer(
            address(pm),
            address(mockHook),
            address(this), // placeholder vault
            address(this), // admin == this test contract (also STRATEGIST_ROLE)
            INITIAL_THRESHOLD,
            address(this), // placeholder automation registry
            DEFAULT_AMOUNT
        );

        vaultActor = new VaultActor(rebalancer);
        keeperActor = new KeeperActor(rebalancer);
        attacker = new Attacker(rebalancer);
        rebalancer.setVault(address(vaultActor));
        rebalancer.setAutomationRegistry(address(keeperActor));

        // Configure a pool and asset up front so the fuzzer starts in a useful state.
        poolSpacing = 60;
        rebalancer.setManagedPool(_key(3000, 60));
        rebalancer.setAsset(address(token0));

        // The rebalancer must hold both tokens for the unwind/swap path to be reachable.
        token0.mint(address(rebalancer), 10_000 ether);
        token1.mint(address(rebalancer), 10_000 ether);
    }

    // ── Fuzzed actions ────────────────────────────────────────────────

    function setThreshold(uint256 amount) external {
        rebalancer.setRebalanceThreshold((amount % 1000 ether) + 1);
    }

    function setMinBlocks(uint256 blocks_) external {
        rebalancer.setMinBlocksBetweenRebalances(blocks_ % 1000);
    }

    function notifyDeposit(uint256 amount) external {
        vaultActor.notifyDeposit(amount % 10_000 ether);
    }

    function notifyWithdraw(uint256 amount) external {
        vaultActor.notifyWithdraw(amount % 10_000 ether);
    }

    /// @notice Gives the rebalancer more tokens so swaps/returns have funds to work with.
    function fundRebalancer(uint256 a0, uint256 a1) external {
        token0.mint(address(rebalancer), a0 % 50_000 ether);
        token1.mint(address(rebalancer), a1 % 50_000 ether);
    }

      /// @notice Changes the vault asset. While a position exists the call MUST revert and change nothing;
    ///         with no position it MUST succeed.
    function selectAsset(bool pickToken0) external {
        address a = pickToken0 ? address(token0) : address(token1);

        if (rebalancer.currentLiquidity() != 0) {
            address before_ = rebalancer.asset();
            try rebalancer.setAsset(a) {
                accountingBroken = true; // the asset was switched under a live position
            } catch {
                assetChangesBlocked++;
            }
            if (rebalancer.asset() != before_) accountingBroken = true;
            return;
        }

        try rebalancer.setAsset(a) {
            successfulAssetChanges++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Strategist rebalance with ticks aligned to the pool's spacing and inside the usable range.
    ///         On valid input this call must NEVER revert.
    function strategistRebalance(int256 loRaw, int256 hiRaw, uint256 liqRaw) external {
        int256 spacing = int256(poolSpacing);
        int256 maxIdx = MAX_TICK_ABS / spacing;
        int256 loIdx = _bound(loRaw, -maxIdx, maxIdx - 1);
        int256 hiIdx = _bound(hiRaw, loIdx + 1, maxIdx);
        int24 lo = int24(loIdx * spacing);
        int24 hi = int24(hiIdx * spacing);
        uint128 liq = uint128((liqRaw % 1_000_000 ether) + 1);

        try rebalancer.rebalanceLiquidity(lo, hi, liq, type(uint256).max, type(uint256).max) {
            successfulRebalances++;
            if (
                rebalancer.currentLiquidity() != liq || rebalancer.currentTickLower() != lo
                    || rebalancer.currentTickUpper() != hi
            ) {
                accountingBroken = true;
            }
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Keeper path (Chainlink Automation). On valid input this must NEVER revert
    ///         (it may legitimately skip: too soon / range unchanged).
    function keeperUpkeep(int256 refRaw, bool diverged) external {
        int24 ref = int24(_bound(refRaw, -800_000, 800_000));
        uint256 blockBefore = rebalancer.lastRebalanceBlock();

        try keeperActor.performUpkeep(abi.encode(ref, diverged)) {
            if (rebalancer.lastRebalanceBlock() != blockBefore) successfulKeeperRebalances++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Vault withdrawal path. amount may exceed idle asset, which forces an LP unwind + swap.
    ///         Reverts are acceptable here (e.g. not enough of the other token), but a success must be exact.
    function returnFunds(uint256 amountRaw) external {
        address a = rebalancer.asset();
        if (a == address(0)) return;

        uint256 idle = MockToken(a).balanceOf(address(rebalancer));
        uint256 amount = (amountRaw % (idle + 5_000 ether)) + 1;
        uint256 vaultBefore = MockToken(a).balanceOf(address(vaultActor));
        uint128 liqBefore = rebalancer.currentLiquidity();

        try vaultActor.returnToVault(amount) {
            successfulReturns++;
            // the vault must receive exactly what it asked for
            if (MockToken(a).balanceOf(address(vaultActor)) != vaultBefore + amount) accountingBroken = true;
            if (amount > idle) {
                successfulUnwinds++;
                // an unwind with an existing position must shrink it
                if (liqBefore > 0 && rebalancer.currentLiquidity() >= liqBefore) accountingBroken = true;
            }
        } catch {}
    }

    /// @notice Pool reconfiguration. Must revert while a position exists, and must succeed otherwise.
    function reconfigurePool(uint24 fee, uint256 spacingRaw) external {
        int24 spacing = int24(_bound(int256(spacingRaw), 1, 200));
        bool hadLiquidity = rebalancer.currentLiquidity() != 0;

        try rebalancer.setManagedPool(_key(fee, spacing)) {
            if (hadLiquidity) accountingBroken = true; // should have reverted PositionStillActive
            poolSpacing = spacing;
            successfulPoolChanges++;
            if (rebalancer.asset() != address(0)) accountingBroken = true; // asset must reset
            try rebalancer.setAsset(address(token0)) {} catch {
                unexpectedRevert = true;
            }
        } catch {
            if (!hadLiquidity) unexpectedRevert = true;
        }
    }

    /// @notice Unprivileged caller tries every privileged function. All must revert.
    function attackerProbe(address newVault) external {
        if (attacker.probe(newVault)) accessControlBroken = true;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    function _key(uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(mockHook))
        });
    }

    /// @dev Modulo-based bounding into [lo, hi] (inclusive).
    function _bound(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        if (lo >= hi) return lo;
        int256 range = hi - lo + 1;
        int256 w = x % range;
        if (w < 0) w += range;
        return lo + w;
    }

    // ── Invariants ────────────────────────────────────────────────────

    function echidna_vault_unchanged() public view returns (bool) {
        return rebalancer.vault() == address(vaultActor);
    }

    function echidna_hook_is_valid() public view returns (bool) {
        return address(rebalancer.hook()) == address(mockHook);
    }

    function echidna_threshold_nonzero() public view returns (bool) {
        return rebalancer.rebalanceThreshold() > 0;
    }

    function echidna_last_rebalance_not_future() public view returns (bool) {
        return rebalancer.lastRebalanceBlock() <= block.number;
    }

    function echidna_asset_is_pool_token() public view returns (bool) {
        address a = rebalancer.asset();
        return a == address(0) || a == address(token0) || a == address(token1);
    }

    /// @dev Whenever a position exists, its ticks are ordered and aligned to the pool spacing.
    function echidna_tick_range_valid_when_position_exists() public view returns (bool) {
        if (rebalancer.currentLiquidity() == 0) return true;
        int24 lo = rebalancer.currentTickLower();
        int24 hi = rebalancer.currentTickUpper();
        return lo < hi && lo % poolSpacing == 0 && hi % poolSpacing == 0;
    }

    /// @dev Ground truth: the PoolManager holds exactly the liquidity the rebalancer thinks it has,
    ///      in exactly the range it thinks it has.
    function echidna_tracked_liquidity_matches_pool() public view returns (bool) {
        return pm.liquidityOf(address(rebalancer), rebalancer.currentTickLower(), rebalancer.currentTickUpper())
            == rebalancer.currentLiquidity();
    }

    /// @dev No liquidity is ever orphaned in an old range.
    function echidna_no_orphaned_liquidity() public view returns (bool) {
        return pm.totalLiquidity() == uint256(rebalancer.currentLiquidity());
    }

    function echidna_no_unexpected_revert() public view returns (bool) {
        return !unexpectedRevert;
    }

    function echidna_accounting_exact() public view returns (bool) {
        return !accountingBroken;
    }

    function echidna_access_control_holds() public view returns (bool) {
        return !accessControlBroken;
    }

    // ── CANARIES: these are EXPECTED TO FAIL ──────────────────────────
    // Each one returns false as soon as the action succeeds at least once.
    // If a canary still shows "passing" at the end of the run, that action was never
    // successfully exercised, so the invariants above proved nothing about it.

    function echidna_canary_strategist_rebalance_reached() public view returns (bool) {
        return successfulRebalances == 0;
    }

    function echidna_canary_keeper_rebalance_reached() public view returns (bool) {
        return successfulKeeperRebalances == 0;
    }

    function echidna_canary_return_reached() public view returns (bool) {
        return successfulReturns == 0;
    }

    function echidna_canary_unwind_reached() public view returns (bool) {
        return successfulUnwinds == 0;
    }

    function echidna_canary_pool_reconfigure_reached() public view returns (bool) {
        return successfulPoolChanges == 0;
    }

        function echidna_canary_asset_change_reached() public view returns (bool) {
        return successfulAssetChanges == 0;
    }

    function echidna_canary_asset_change_blocked_reached() public view returns (bool) {
        return assetChangesBlocked == 0;
    }
}