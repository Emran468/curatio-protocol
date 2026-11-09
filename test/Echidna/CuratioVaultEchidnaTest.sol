// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratioVault} from "../../src/CuratioVault.sol";
import {CuratioAccess} from "../../src/CuratioAccess.sol";
import {CuratioRebalancer} from "../../src/CuratioRebalancer.sol";
import {CuratioDynamicFee} from "../../src/CuratioDynamicFee.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks (prefixed "Vt" so they never clash with the rebalancer Echidna file)
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Full ERC20 (the vault needs transferFrom/approve) plus mint/burn for gains and losses.
contract VtToken {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function burn(address from, uint256 a) external {
        require(balanceOf[from] >= a, "burn>bal");
        balanceOf[from] -= a;
        totalSupply -= a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        require(al >= a, "allowance");
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Price-1 TWAP hook with a switch to simulate a TWAP outage.
contract VtHook {
    bool public down;

    function setDown(bool d) external {
        down = d;
    }

    function getCurrentFee(PoolKey calldata) external pure returns (uint24) {
        return 3000;
    }

    function getPoolState(PoolKey calldata) external view returns (int24, uint24, uint64, uint64, bool) {
        require(!down, "twap down");
        return (0, 3000, 0, 0, true);
    }

    function getTwapTick(PoolKey calldata, uint32) external view returns (int24) {
        require(!down, "twap down");
        return 0;
    }
}

/// @dev Exact-output swaps at price 1 with no fee, take() mints. Value-conserving at price 1.
contract VtPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function swap(PoolKey calldata, SwapParams calldata p, bytes calldata) external pure returns (BalanceDelta) {
        require(p.amountSpecified > 0, "exact-out only");
        int128 out = int128(p.amountSpecified);
        return p.zeroForOne ? toBalanceDelta(-out, out) : toBalanceDelta(out, -out);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency c, address to, uint256 amount) external {
        VtToken(Currency.unwrap(c)).mint(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Actors
// ─────────────────────────────────────────────────────────────────────────────

/// @dev A vault user. Holds tokens, pre-approves the vault.
contract VtActor {
    CuratioVault public immutable vault;

    constructor(CuratioVault v, VtToken a, uint256 funds) {
        vault = v;
        a.mint(address(this), funds);
        a.approve(address(v), type(uint256).max);
    }

    function deposit(uint256 a, address r) external returns (uint256) {
        return vault.deposit(a, r);
    }

    function mint(uint256 s, address r) external returns (uint256) {
        return vault.mint(s, r);
    }

    function withdraw(uint256 a, address r) external returns (uint256) {
        return vault.withdraw(a, r, address(this));
    }

    function redeem(uint256 s, address r) external returns (uint256) {
        return vault.redeem(s, r, address(this));
    }
}

/// @dev No roles. Every privileged call must revert.
///      Only calls whose success does not depend on vault funds are probed, so a revert can
///      never be caused by something other than the role check.
contract VtAttacker {
    CuratioVault public immutable v;
    CuratioAccess public immutable a;
    CuratioRebalancer public immutable r;
    CuratioDynamicFee public immutable f;

    constructor(CuratioVault _v, CuratioAccess _a, CuratioRebalancer _r, CuratioDynamicFee _f) {
        v = _v;
        a = _a;
        r = _r;
        f = _f;
    }

    function probe() external returns (bool) {
        try v.setDepositCap(0) {
            return true;
        }
            catch {}
        try v.setDepositsPaused(true) {
            return true;
        }
            catch {}
        try v.proposeRebalancer(address(0xBEEF)) {
            return true;
        }
            catch {}
        try v.proposeAccessControl(address(0xBEEF)) {
            return true;
        }
            catch {}
        try v.proposeFeeModule(address(0)) {
            return true;
        }
            catch {}
        try v.harvest() {
            return true;
        }
            catch {}
        try v.grantRole(v.VAULT_MANAGER_ROLE(), address(this)) {
            return true;
        }
            catch {}
        try a.setWhitelistedUser(address(this), true) {
            return true;
        }
            catch {}
        try a.toggleWhitelisting(false) {
            return true;
        }
            catch {}
        try r.setVault(address(0xCAFE)) {
            return true;
        }
            catch {}
        try r.setAsset(address(0xCAFE)) {
            return true;
        }
            catch {}
        try f.setPerformanceFeeBps(0) {
            return true;
        }
            catch {}
        try f.setFeeRecipient(address(this)) {
            return true;
        }
            catch {}
        try f.setVault(address(this)) {
            return true;
        }
            catch {}
        try f.reportPerformanceFeeCharged(0, 0) {
            return true;
        }
            catch {}
        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Echidna test
// ─────────────────────────────────────────────────────────────────────────────

contract CuratioVaultEchidnaTest {
    uint256 constant ACTORS = 4; // 0..2 whitelisted, 3 = outsider (never whitelisted)
    uint256 constant INITIAL_FUNDS = 1_000_000_000 ether;
    uint256 constant VIRT = 1e6; // must equal 10 ** _decimalsOffset() in CuratioVault

    VtToken public asset; // pool currency0
    VtToken public other; // pool currency1
    VtPoolManager public pm;
    VtHook public hook;
    CuratioAccess public access;
    CuratioRebalancer public rebalancer;
    CuratioVault public vault;
    CuratioDynamicFee public dynamicFee; // fee recipient = actors[0] (whitelisted, counted in shares_conserved)
    VtAttacker public attacker;
    VtActor[4] public actors;

    // Ghost accounting (value is 1:1 across both tokens: price 1, no fees)
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostGains;
    uint256 public ghostLosses;

    // Share-price baseline, stored as (assets + 1, shares + VIRT) like OZ's virtual shares
    uint256 internal baseA;
    uint256 internal baseS;

    /// @dev Lowest value the high-water mark may have: updated after every harvest, reset by a re-baseline.
    uint256 public hwmFloor;

    // Failure flags
    bool public priceDropped; // share price fell without a loss or fee event
    bool public accountingBroken; // a post-condition was violated
    bool public ruleBreak; // pause / whitelist / cap / outage rule bypassed
    bool public unexpectedRevert; // a call that must succeed reverted
    bool public accessBroken; // an unprivileged call succeeded
    bool public zeroShareDeposit; // a deposit succeeded with zero shares
    bool public harvestBroken; // a harvest post-condition was violated

    // Reachability counters (used by canaries)
    uint256 public successfulDeposits;
    uint256 public successfulMints;
    uint256 public successfulWithdraws;
    uint256 public successfulRedeems;
    uint256 public successfulPullWithdraws; // vault idle was short, pulled from rebalancer
    uint256 public successfulSwapWithdraws; // rebalancer idle asset was short too: swap path
    uint256 public successfulDeploys;
    uint256 public rejectedWhilePaused;
    uint256 public rejectedNotWhitelisted;
    uint256 public rejectedByCap;
    uint256 public rejectedZeroShares;
    uint256 public rejectedZeroAssets;
    uint256 public haltedDuringOutage;
    uint256 public lossEvents;
    uint256 public donations;
    uint256 public probeCount;
    uint256 public successfulHarvests;
    uint256 public baselineHarvests;
    uint256 public feeHarvests;
    uint256 public feeHarvestsWithHolders;
    uint256 public noGainHarvests;
    uint256 public haltedHarvests;
    uint256 public doubleHarvestsChecked;
    uint256 public rebaselines;
    uint256 public feeRateChanges;
    uint256 public feeCapRejections;

    struct Pre {
        bool down;
        bool paused;
        bool wl;
        bool haveTotal;
        uint256 cap;
        uint256 total;
    }

    struct W {
        bool down;
        bool wl;
        uint256 shortfall;
        uint256 rIdle;
        uint256 rcvBefore;
        uint256 shBefore;
    }

    struct H {
        bool down;
        uint256 hwm;
        uint256 supply;
        uint256 recv;
        uint256 fees;
        uint256 yld;
        uint256 assets;
    }

    constructor() {
        VtToken a = new VtToken();
        VtToken b = new VtToken();
        (asset, other) = address(a) < address(b) ? (a, b) : (b, a); // asset = currency0

        pm = new VtPoolManager();
        hook = new VtHook();
        access = new CuratioAccess(address(this));

        // vault <-> rebalancer are mutually dependent: placeholder vault first, then re-point
        rebalancer = new CuratioRebalancer(
            address(pm), address(hook), address(this), address(this), 1 ether, address(this), 1000 ether
        );
        vault = new CuratioVault(IERC20(address(asset)), address(access), address(rebalancer), address(this), 0);

        rebalancer.setVault(address(vault));
        rebalancer.setManagedPool(
            PoolKey({
                currency0: Currency.wrap(address(asset)),
                currency1: Currency.wrap(address(other)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            })
        );
        rebalancer.setAsset(address(asset));

        for (uint256 i = 0; i < ACTORS; i++) {
            actors[i] = new VtActor(vault, asset, INITIAL_FUNDS);
            if (i < 3) access.setWhitelistedUser(address(actors[i]), true);
        }

        // fee module: this contract is its admin (FEE_ADMIN_ROLE), actors[0] receives the fee shares
        dynamicFee = new CuratioDynamicFee(address(this), address(vault), address(actors[0]));
        vault.initializeFeeModule(address(dynamicFee));

        attacker = new VtAttacker(vault, access, rebalancer, dynamicFee);

        _rebase();
    }

    // ── Price baseline helpers ───────────────────────────────────────

    function _rebase() internal {
        try vault.totalAssets() returns (uint256 a) {
            baseA = a + 1;
            baseS = vault.totalSupply() + VIRT;
        } catch {}
    }

    /// @dev Share price (A+1)/(S+VIRT) must never decrease across user actions.
    ///      Cross-multiplied so rounding cannot hide or fake a drop.
    function _checkPrice() internal {
        try vault.totalAssets() returns (uint256 a) {
            uint256 s = vault.totalSupply();
            if ((a + 1) * baseS < baseA * (s + VIRT)) priceDropped = true;
            baseA = a + 1;
            baseS = s + VIRT;
        } catch {}
    }

    function _pre(address who, address recv) internal view returns (Pre memory p) {
        p.down = hook.down();
        p.paused = vault.depositsPaused();
        p.cap = vault.depositCap();
        p.wl = access.isWhitelisted(who) && access.isWhitelisted(recv);
        try vault.totalAssets() returns (uint256 t) {
            p.total = t;
            p.haveTotal = true;
        } catch {}
    }

    // ── User actions ─────────────────────────────────────────────────

    function userDeposit(uint8 aIdx, uint8 rIdx, uint256 amtRaw) external {
        VtActor who = actors[aIdx % ACTORS];
        address recv = address(actors[rIdx % ACTORS]);
        uint256 bal = asset.balanceOf(address(who));
        if (bal == 0) return;
        uint256 amt = (amtRaw % bal) + 1;

        Pre memory p = _pre(address(who), recv);
        bool zeroShares = !p.down && vault.previewDeposit(amt) == 0;
        bool expectOk = !p.down && !p.paused && p.wl && !zeroShares && (p.cap == 0 || p.total + amt <= p.cap);
        uint256 rcvBefore = vault.balanceOf(recv);

        try who.deposit(amt, recv) returns (uint256 shares) {
            successfulDeposits++;
            ghostDeposited += amt;
            _afterMintLike(p, recv, shares, rcvBefore);
            if (asset.balanceOf(address(who)) != bal - amt) accountingBroken = true;
            if (shares == 0) zeroShareDeposit = true;
            _checkPrice();
        } catch {
            _onDepositRevert(p, expectOk, zeroShares);
        }
    }

    function userMint(uint8 aIdx, uint8 rIdx, uint256 sharesRaw) external {
        VtActor who = actors[aIdx % ACTORS];
        address recv = address(actors[rIdx % ACTORS]);
        uint256 sh = (sharesRaw % (1_000_000 ether * VIRT)) + 1;

        Pre memory p = _pre(address(who), recv);
        if (!p.down) {
            // skip attempts the caller cannot afford (not interesting)
            if (vault.previewMint(sh) > asset.balanceOf(address(who))) return;
        }
        uint256 rcvBefore = vault.balanceOf(recv);
        uint256 balBefore = asset.balanceOf(address(who));

        try who.mint(sh, recv) returns (uint256 assetsIn) {
            successfulMints++;
            ghostDeposited += assetsIn;
            _afterMintLike(p, recv, sh, rcvBefore);
            if (asset.balanceOf(address(who)) != balBefore - assetsIn) accountingBroken = true;
            _checkPrice();
        } catch {
            // safety-only for mint: a revert is always acceptable here, but outages must halt it
            if (p.down) haltedDuringOutage++;
        }
    }

    /// @dev Shared post-conditions for deposit/mint.
    function _afterMintLike(Pre memory p, address recv, uint256 sharesOut, uint256 rcvBefore) internal {
        if (p.down || p.paused || !p.wl) ruleBreak = true;
        if (vault.balanceOf(recv) != rcvBefore + sharesOut) accountingBroken = true;
        if (p.cap != 0) {
            try vault.totalAssets() returns (uint256 t) {
                if (t > p.cap) ruleBreak = true; // cap enforced at deposit time
            } catch {}
        }
    }

    function _onDepositRevert(Pre memory p, bool expectOk, bool zeroShares) internal {
        if (expectOk) {
            unexpectedRevert = true;
            return;
        }
        if (p.down) haltedDuringOutage++;
        else if (p.paused) rejectedWhilePaused++;
        else if (!p.wl) rejectedNotWhitelisted++;
        else if (zeroShares) rejectedZeroShares++;
        else rejectedByCap++;
    }

    function userWithdraw(uint8 aIdx, uint8 rIdx, uint256 amtRaw) external {
        VtActor who = actors[aIdx % ACTORS];
        address recv = address(actors[rIdx % ACTORS]);

        W memory w;
        w.shBefore = vault.balanceOf(address(who));
        if (w.shBefore == 0) return;
        w.down = hook.down();
        uint256 maxA = w.down ? 1 ether : vault.convertToAssets(w.shBefore);
        if (maxA == 0) return;
        uint256 amt = (amtRaw % maxA) + 1;

        w.wl = access.isWhitelisted(address(who)) && access.isWhitelisted(recv);
        uint256 vIdle = asset.balanceOf(address(vault));
        w.shortfall = amt > vIdle ? amt - vIdle : 0;
        w.rIdle = asset.balanceOf(address(rebalancer));
        w.rcvBefore = asset.balanceOf(recv);

        try who.withdraw(amt, recv) returns (uint256 sh) {
            successfulWithdraws++;
            ghostWithdrawn += amt;
            if (w.down || !w.wl) ruleBreak = true;
            if (asset.balanceOf(recv) != w.rcvBefore + amt) accountingBroken = true;
            if (vault.balanceOf(address(who)) != w.shBefore - sh) accountingBroken = true;
            if (w.shortfall > 0) successfulPullWithdraws++;
            if (w.shortfall > w.rIdle) successfulSwapWithdraws++;
            _checkPrice();
        } catch {
            if (!w.down && w.wl) unexpectedRevert = true; // amt <= maxWithdraw and TWAP is up: must succeed
            if (w.down) haltedDuringOutage++;
        }
    }

    function userRedeem(uint8 aIdx, uint8 rIdx, uint256 sharesRaw) external {
        VtActor who = actors[aIdx % ACTORS];
        address recv = address(actors[rIdx % ACTORS]);

        W memory w;
        w.shBefore = vault.balanceOf(address(who));
        if (w.shBefore == 0) return;
        uint256 sh = (sharesRaw % w.shBefore) + 1;
        w.down = hook.down();
        w.wl = access.isWhitelisted(address(who)) && access.isWhitelisted(recv);
        w.rcvBefore = asset.balanceOf(recv);
        bool zeroAssets = !w.down && vault.previewRedeem(sh) == 0;

        try who.redeem(sh, recv) returns (uint256 assetsOut) {
            successfulRedeems++;
            if (assetsOut == 0) accountingBroken = true; // a zero-payout redeem must now revert
            ghostWithdrawn += assetsOut;
            if (w.down || !w.wl) ruleBreak = true;
            if (asset.balanceOf(recv) != w.rcvBefore + assetsOut) accountingBroken = true;
            if (vault.balanceOf(address(who)) != w.shBefore - sh) accountingBroken = true;
            _checkPrice();
        } catch {
            if (!w.down && w.wl && zeroAssets) rejectedZeroAssets++;
            else if (!w.down && w.wl) unexpectedRevert = true;
            if (w.down) haltedDuringOutage++;
        }
    }

    // ── Manager / environment actions ────────────────────────────────

    /// @notice Moves idle vault asset to the rebalancer. Must be exactly value-neutral.
    function deployToRebalancer(uint256 raw) external {
        uint256 idle = asset.balanceOf(address(vault));
        if (idle == 0) return;
        uint256 amt = (raw % idle) + 1;

        uint256 before_;
        bool ok;
        try vault.totalAssets() returns (uint256 t) {
            before_ = t;
            ok = true;
        } catch {}

        try vault.deployToRebalancer(amt) {
            successfulDeploys++;
            if (ok) {
                try vault.totalAssets() returns (uint256 t2) {
                    if (t2 != before_) accountingBroken = true;
                } catch {
                    unexpectedRevert = true;
                }
            }
        } catch {
            unexpectedRevert = true;
        }
    }

    function setCap(uint256 raw) external {
        vault.setDepositCap(raw % 4 == 0 ? 0 : raw % 5_000_000_000 ether);
    }

    function setPaused(bool p) external {
        vault.setDepositsPaused(p);
    }

    function toggleWhitelist(bool on) external {
        access.toggleWhitelisting(on);
    }

    function setTwapOutage(bool d) external {
        hook.setDown(d);
        if (!d) _rebase();
    }

    /// @notice Free money arrives (yield stand-in): asset to vault, asset to rebalancer, or the
    ///         other token to rebalancer (valued at price 1).
    function donate(uint8 kind, uint256 raw) external {
        uint256 amt = (raw % 1_000_000 ether) + 1;
        kind = kind % 3;
        if (kind == 0) asset.mint(address(vault), amt);
        else if (kind == 1) asset.mint(address(rebalancer), amt);
        else other.mint(address(rebalancer), amt);
        ghostGains += amt;
        donations++;
        _rebase();
    }

    /// @notice A genuine loss event: idle asset in the rebalancer disappears.
    ///         Together with a fee harvest this is the only way to lower the share price.
    function simulateLoss(uint256 raw) external {
        if (hook.down()) return; // cannot rebase the baseline while the TWAP is down
        uint256 idle = asset.balanceOf(address(rebalancer));
        if (idle == 0) return;
        uint256 amt = (raw % idle) + 1;
        asset.burn(address(rebalancer), amt);
        ghostLosses += amt;
        lossEvents++;
        _rebase();
    }

    function attackerProbe() external {
        probeCount++;
        if (attacker.probe()) accessBroken = true;
    }

    // ── Harvest actions ──────────────────────────────────────────────

    /// @notice Calls harvest(). During a TWAP outage it must revert; otherwise it must succeed and
    ///         leave every accounting property intact.
    function harvestAction() external {
        H memory h;
        h.down = hook.down();
        h.hwm = vault.highWaterMark();
        h.supply = vault.totalSupply();
        h.recv = vault.balanceOf(address(actors[0]));
        h.fees = dynamicFee.totalFeesCharged();
        h.yld = dynamicFee.totalYieldProcessed();

        if (h.down) {
            try vault.harvest() {
                harvestBroken = true; // harvest must halt without a TWAP
            } catch {
                haltedHarvests++;
            }
            return;
        }
        h.assets = vault.totalAssets();

        try vault.harvest() returns (uint256 feeShares) {
            successfulHarvests++;
            _checkHarvest(h, feeShares);
            hwmFloor = vault.highWaterMark();
            _rebase(); // minting fee shares legitimately lowers the share price
        } catch {
            unexpectedRevert = true;
        }
    }

    function _checkHarvest(H memory h, uint256 feeShares) internal {
        uint256 hwmAfter = vault.highWaterMark();
        if (hwmAfter < h.hwm) harvestBroken = true; // HWM never decreases
        if (vault.totalSupply() != h.supply + feeShares) harvestBroken = true;
        if (vault.balanceOf(address(actors[0])) != h.recv + feeShares) harvestBroken = true;
        if (vault.totalAssets() != h.assets) harvestBroken = true; // no asset may move

        uint256 feeDelta = dynamicFee.totalFeesCharged() - h.fees;
        uint256 yieldDelta = dynamicFee.totalYieldProcessed() - h.yld;

        if (h.hwm == 0) {
            baselineHarvests++;
            if (feeShares != 0 || feeDelta != 0 || yieldDelta != 0 || hwmAfter == 0) harvestBroken = true;
        } else if (feeShares > 0) {
            feeHarvests++;
            if (h.supply > 0) feeHarvestsWithHolders++; // NEW: a fee was charged while shares already existed
            if (feeDelta == 0 || feeDelta > yieldDelta) harvestBroken = true; // fee never exceeds the gain
            if (feeDelta > (yieldDelta * dynamicFee.performanceFeeBps()) / 10_000) harvestBroken = true; // fee <= rate x gain
            if (yieldDelta > h.assets + 1) harvestBroken = true; // a gain cannot exceed total value
            if (vault.convertToAssets(feeShares) > feeDelta) harvestBroken = true; // recipient never over-paid
        } else {
            noGainHarvests++;
            if (feeDelta != 0 || yieldDelta != 0) harvestBroken = true;
        }
    }

    /// @notice Harvest twice in a row: the second call must charge nothing and change nothing.
    function harvestTwice() external {
        if (hook.down()) return;

        try vault.harvest() {
            hwmFloor = vault.highWaterMark();
        } catch {
            unexpectedRevert = true;
            return;
        }
        _rebase();

        uint256 supplyMid = vault.totalSupply();
        uint256 feesMid = dynamicFee.totalFeesCharged();
        uint256 hwmMid = vault.highWaterMark();

        try vault.harvest() returns (uint256 fs) {
            doubleHarvestsChecked++;
            if (
                fs != 0 || vault.totalSupply() != supplyMid || dynamicFee.totalFeesCharged() != feesMid
                    || vault.highWaterMark() != hwmMid
            ) harvestBroken = true; // the same gain was charged twice
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Re-registering the module resets the HWM to 0 (a fresh baseline).
    function rebaselineModule() external {
        vault.initializeFeeModule(address(dynamicFee));
        hwmFloor = 0;
        if (vault.highWaterMark() != 0) harvestBroken = true;
        rebaselines++;
    }

    /// @notice Changes the fee rate within the cap, then tries a rate above the 30% hard cap (must revert).
    function setFeeBps(uint256 raw) external {
        dynamicFee.setPerformanceFeeBps(raw % 3001);
        feeRateChanges++;

        try dynamicFee.setPerformanceFeeBps(3001 + (raw % 1_000_000)) {
            harvestBroken = true;
        } catch {
            feeCapRejections++;
        }
    }

    // ── Invariants ───────────────────────────────────────────────────

    /// @dev Exact conservation: tokens in the system + what left = what came in.
    function echidna_value_conserved() public view returns (bool) {
        uint256 v = asset.balanceOf(address(vault)) + asset.balanceOf(address(rebalancer))
            + other.balanceOf(address(rebalancer));
        return v + ghostWithdrawn + ghostLosses == ghostDeposited + ghostGains;
    }

    /// @dev totalAssets() must equal real token balances (computed independently of the vault).
    function echidna_total_assets_matches_ground_truth() public view returns (bool) {
        if (hook.down()) return true; // totalAssets is meant to revert during an outage
        uint256 v = asset.balanceOf(address(vault)) + asset.balanceOf(address(rebalancer))
            + other.balanceOf(address(rebalancer));
        return vault.totalAssets() == v;
    }

    /// @dev Redeeming every share cannot claim more than the vault holds.
    function echidna_solvent() public view returns (bool) {
        if (hook.down()) return true;
        return vault.convertToAssets(vault.totalSupply()) <= vault.totalAssets();
    }

    /// @dev Includes the fee recipient (actors[0]), so minted fee shares are accounted for.
    function echidna_shares_conserved() public view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < ACTORS; i++) {
            sum += vault.balanceOf(address(actors[i]));
        }
        return sum == vault.totalSupply();
    }

    function echidna_no_free_money() public view returns (bool) {
        return ghostWithdrawn <= ghostDeposited + ghostGains;
    }

    function echidna_share_price_never_drops() public view returns (bool) {
        return !priceDropped;
    }

    function echidna_accounting_exact() public view returns (bool) {
        return !accountingBroken;
    }

    function echidna_rules_enforced() public view returns (bool) {
        return !ruleBreak;
    }

    function echidna_no_unexpected_revert() public view returns (bool) {
        return !unexpectedRevert;
    }

    function echidna_access_control_holds() public view returns (bool) {
        return !accessBroken && !vault.hasRole(vault.VAULT_MANAGER_ROLE(), address(attacker))
            && !access.hasRole(access.VAULT_MANAGER_ROLE(), address(attacker))
            && !dynamicFee.hasRole(dynamicFee.FEE_ADMIN_ROLE(), address(attacker));
    }

    function echidna_wiring_unchanged() public view returns (bool) {
        return address(vault.rebalancer()) == address(rebalancer) && address(vault.accessControl()) == address(access)
            && rebalancer.vault() == address(vault) && address(vault.feeModule()) == address(dynamicFee)
            && dynamicFee.vault() == address(vault);
    }

    /// @dev The offset + ZeroShares guard (inflation-attack protection): a deposit never pays for nothing.
    function echidna_no_zero_share_deposit() public view returns (bool) {
        return !zeroShareDeposit;
    }

    // ── Harvest / high-water-mark invariants ─────────────────────────

    /// @dev The HWM never decreases; only re-registering the module may reset it (hwmFloor is reset then).
    function echidna_hwm_monotonic() public view returns (bool) {
        return vault.highWaterMark() >= hwmFloor;
    }

    /// @dev Every harvest post-condition: no asset moves, shares minted only to the recipient, fee <= rate x gain,
    ///      fee <= gain, recipient never over-paid, a second harvest charges nothing, the 30% cap holds.
    function echidna_harvest_accounting() public view returns (bool) {
        return !harvestBroken;
    }

    /// @dev Cumulative fees never exceed the 30% hard cap of cumulative yield (sum of floors).
    function echidna_fees_within_cap() public view returns (bool) {
        return dynamicFee.totalFeesCharged() * 10_000 <= dynamicFee.totalYieldProcessed() * 3000;
    }

    // ── CANARIES: EXPECTED TO FAIL ("failed!" = path reached) ────────
    // A canary that still says "passing" means that path never ran, so the invariants
    // above proved nothing about it.

    function echidna_canary_deposit_reached() public view returns (bool) {
        return successfulDeposits == 0;
    }

    function echidna_canary_mint_reached() public view returns (bool) {
        return successfulMints == 0;
    }

    function echidna_canary_withdraw_reached() public view returns (bool) {
        return successfulWithdraws == 0;
    }

    function echidna_canary_redeem_reached() public view returns (bool) {
        return successfulRedeems == 0;
    }

    function echidna_canary_pull_from_rebalancer_reached() public view returns (bool) {
        return successfulPullWithdraws == 0;
    }

    function echidna_canary_swap_on_withdraw_reached() public view returns (bool) {
        return successfulSwapWithdraws == 0;
    }

    function echidna_canary_deploy_reached() public view returns (bool) {
        return successfulDeploys == 0;
    }

    function echidna_canary_pause_rejection_reached() public view returns (bool) {
        return rejectedWhilePaused == 0;
    }

    function echidna_canary_whitelist_rejection_reached() public view returns (bool) {
        return rejectedNotWhitelisted == 0;
    }

    function echidna_canary_cap_rejection_reached() public view returns (bool) {
        return rejectedByCap == 0;
    }

    function echidna_canary_zero_share_rejection_reached() public view returns (bool) {
        return rejectedZeroShares == 0;
    }

    function echidna_canary_zero_asset_rejection_reached() public view returns (bool) {
        return rejectedZeroAssets == 0;
    }

    function echidna_canary_outage_halt_reached() public view returns (bool) {
        return haltedDuringOutage == 0;
    }

    function echidna_canary_loss_event_reached() public view returns (bool) {
        return lossEvents == 0;
    }

    function echidna_canary_donation_reached() public view returns (bool) {
        return donations == 0;
    }

    function echidna_canary_attacker_probe_reached() public view returns (bool) {
        return probeCount == 0;
    }

    function echidna_canary_harvest_reached() public view returns (bool) {
        return successfulHarvests == 0;
    }

    function echidna_canary_harvest_baseline_reached() public view returns (bool) {
        return baselineHarvests == 0;
    }

    /// @dev The important one: a harvest that really minted fee shares.
    function echidna_canary_fee_harvest_reached() public view returns (bool) {
        return feeHarvests == 0;
    }

    function echidna_canary_no_gain_harvest_reached() public view returns (bool) {
        return noGainHarvests == 0;
    }

    function echidna_canary_harvest_outage_halt_reached() public view returns (bool) {
        return haltedHarvests == 0;
    }

    function echidna_canary_double_harvest_checked() public view returns (bool) {
        return doubleHarvestsChecked == 0;
    }

    function echidna_canary_rebaseline_reached() public view returns (bool) {
        return rebaselines == 0;
    }

    function echidna_canary_fee_rate_change_reached() public view returns (bool) {
        return feeRateChanges == 0;
    }

    function echidna_canary_fee_cap_rejection_reached() public view returns (bool) {
        return feeCapRejections == 0;
    }

    /// @dev Stronger than the one above: a fee harvest that happened while shares already existed.
    function echidna_canary_fee_harvest_with_holders_reached() public view returns (bool) {
        return feeHarvestsWithHolders == 0;
    }
}
