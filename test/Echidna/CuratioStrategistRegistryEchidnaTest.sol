// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
    CuratioStrategistRegistryEchidnaTest

    Echidna property tests for CuratioStrategistRegistry.sol.

    WHY THIS HARNESS IS SIMPLE
    ---------------------------
    Unlike CuratioHook, CuratioStrategistRegistry is a plain AccessControl
    contract with no CREATE2 address-flag requirement and no chain/PoolManager
    guard — Echidna deploys this test contract, msg.sender == address(this)
    at construction time, and the registry's constructor grants
    DEFAULT_ADMIN_ROLE + REGISTRAR_ROLE to whoever deploys it. So this test
    contract can call every admin/registrar function directly without any
    mining or bypass hooks.

    We additionally self-authorize as a REBALANCER_ROLE holder so the same
    contract can also fuzz recordRebalanceExecuted / recordFeesGenerated,
    exercising the full registrar+rebalancer surface from one address.

    Run with (from repo root):
      echidna test/Echidna/CuratioStrategistRegistryEchidnaTest.sol \
        --contract CuratioStrategistRegistryEchidnaTest --config test/Echidna/echidna.yaml
//////////////////////////////////////////////////////////////////////////*/

import {CuratioStrategistRegistry} from "../../src/CuratioStrategistRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CuratioStrategistRegistryEchidnaTest {
    CuratioStrategistRegistry public registry;

    address[5] internal strategistPool;
    PoolId[5] internal poolIdPool;

    // Shadow accounting used only to cross-check the registry's own
    // bookkeeping — never trusted on its own, always compared against
    // registry state.
    mapping(address => bool) internal everRegistered;

    // Echidna deploys this contract once; deployment is msg.sender == this,
    // so the registry's DEFAULT_ADMIN_ROLE and REGISTRAR_ROLE both land on
    // address(this), letting fuzz functions call admin/registrar functions
    // directly.
    constructor() {
        registry = new CuratioStrategistRegistry(address(this));
        registry.authorizeRebalancer(address(this));

        for (uint256 i = 0; i < 5; i++) {
            strategistPool[i] = address(uint160(0xA000 + i));
        }
        for (uint256 i = 0; i < 5; i++) {
            poolIdPool[i] = PoolId.wrap(bytes32(uint256(i + 1)));
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Fuzzed action wrappers. Each is a no-op (not a revert) on invalid
    // preconditions so Echidna keeps generating useful call sequences
    // instead of wasting runs on guaranteed-revert paths.
    // ════════════════════════════════════════════════════════════════════

    function fuzz_registerStrategist(uint256 seed) public {
        address s = strategistPool[seed % strategistPool.length];
        if (!registry.isRegisteredStrategist(s)) {
            registry.registerStrategist(s, "fuzz-strategist");
            everRegistered[s] = true;
        }
    }

    function fuzz_deactivateStrategist(uint256 seed) public {
        address s = strategistPool[seed % strategistPool.length];
        if (registry.isRegisteredStrategist(s)) {
            registry.deactivateStrategist(s);
        }
    }

    function fuzz_reactivateStrategist(uint256 seed) public {
        address s = strategistPool[seed % strategistPool.length];
        if (registry.isRegisteredStrategist(s)) {
            registry.reactivateStrategist(s);
        }
    }

    function fuzz_assignPool(uint256 sSeed, uint256 pSeed) public {
        address s = strategistPool[sSeed % strategistPool.length];
        PoolId p = poolIdPool[pSeed % poolIdPool.length];
        if (registry.isRegisteredStrategist(s) && registry.poolStrategist(p) == address(0)) {
            registry.assignPoolToStrategist(s, p);
        }
    }

    function fuzz_reassignPool(uint256 pSeed, uint256 sSeed) public {
        PoolId p = poolIdPool[pSeed % poolIdPool.length];
        address s = strategistPool[sSeed % strategistPool.length];
        if (registry.isRegisteredStrategist(s)) {
            registry.reassignPool(p, s);
        }
    }

    function fuzz_bulkReassignPools(uint256 s1Seed, uint256 s2Seed) public {
        address s1 = strategistPool[s1Seed % strategistPool.length];
        address s2 = strategistPool[s2Seed % strategistPool.length];
        if (s1 != s2 && registry.isRegisteredStrategist(s1) && registry.isRegisteredStrategist(s2)) {
            registry.bulkReassignPools(s1, s2, type(uint256).max);
        }
    }

    function fuzz_recordRebalance(uint256 seed) public {
        address s = strategistPool[seed % strategistPool.length];
        (bool success,) = address(registry).call(abi.encodeWithSelector(registry.recordRebalanceExecuted.selector, s));
        // Deliberately unchecked: reverts (unregistered / inactive) are
        // expected and are exactly what the invariants below verify never
        // silently "succeed" instead.
        success;
    }

    function fuzz_recordFees(uint256 seed, uint256 amount) public {
        address s = strategistPool[seed % strategistPool.length];
        (bool success,) =
            address(registry).call(abi.encodeWithSelector(registry.recordFeesGenerated.selector, s, amount % 1e24));
        success;
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: a strategist that is registered but currently inactive
    // must reject both recordRebalanceExecuted and recordFeesGenerated —
    // this is a direct, deterministic call (not relying on fuzzer luck),
    // exercising the exact revert path rather than merely hoping the
    // fuzzer stumbles into it via fuzz_recordRebalance.
    // ════════════════════════════════════════════════════════════════════
    function testInactiveStrategistCannotRecord(uint256 seed, uint256 amount) public {
        address s = strategistPool[seed % strategistPool.length];

        if (!registry.isRegisteredStrategist(s)) {
            registry.registerStrategist(s, "inactive-check");
        }
        registry.deactivateStrategist(s);

        (bool successRebalance,) =
            address(registry).call(abi.encodeWithSelector(registry.recordRebalanceExecuted.selector, s));
        assert(!successRebalance);

        (bool successFees,) =
            address(registry).call(abi.encodeWithSelector(registry.recordFeesGenerated.selector, s, amount % 1e24));
        assert(!successFees);

        registry.reactivateStrategist(s); // reset for subsequent runs
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: an unregistered address can never assign a pool, record a
    // rebalance, record fees, or be queried via getStrategistProfile —
    // every entry point must revert, never silently succeed with default
    // zero-values.
    // ════════════════════════════════════════════════════════════════════
    function testUnregisteredStrategistRejectedEverywhere(uint256 poolSeed, uint256 amount) public {
        address neverUsed = address(uint160(0xB000 + (poolSeed % 1000)));
        require(!registry.isRegisteredStrategist(neverUsed), "picked an already-registered address");

        PoolId p = poolIdPool[poolSeed % poolIdPool.length];

        (bool successAssign,) =
            address(registry).call(abi.encodeWithSelector(registry.assignPoolToStrategist.selector, neverUsed, p));
        assert(!successAssign);

        (bool successRebalance,) =
            address(registry).call(abi.encodeWithSelector(registry.recordRebalanceExecuted.selector, neverUsed));
        assert(!successRebalance);

        (bool successFees,) = address(registry)
            .call(abi.encodeWithSelector(registry.recordFeesGenerated.selector, neverUsed, amount % 1e24));
        assert(!successFees);

        (bool successProfile,) =
            address(registry).call(abi.encodeWithSelector(registry.getStrategistProfile.selector, neverUsed));
        assert(!successProfile);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: once registered, an address is registered forever —
    // there is no unregister path in the contract, so
    // isRegisteredStrategist must never flip from true back to false.
    // ════════════════════════════════════════════════════════════════════
    function echidna_registered_strategist_never_unregisters() public view returns (bool) {
        for (uint256 i = 0; i < strategistPool.length; i++) {
            address s = strategistPool[i];
            if (everRegistered[s] && !registry.isRegisteredStrategist(s)) {
                return false;
            }
        }
        return true;
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: poolStrategist[p] and the owner's own _strategistPools
    // list (via getStrategistPools) must always agree — every pool with a
    // non-zero owner must appear in that owner's pool list.
    // ════════════════════════════════════════════════════════════════════
    function echidna_pool_owner_consistency() public view returns (bool) {
        for (uint256 i = 0; i < poolIdPool.length; i++) {
            PoolId p = poolIdPool[i];
            address owner_ = registry.poolStrategist(p);
            if (owner_ == address(0)) continue;

            PoolId[] memory ownerPools = registry.getStrategistPools(owner_);
            bool found = false;
            for (uint256 j = 0; j < ownerPools.length; j++) {
                if (PoolId.unwrap(ownerPools[j]) == PoolId.unwrap(p)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: getAllStrategists() never contains the same address twice.
    // ════════════════════════════════════════════════════════════════════
    function echidna_no_duplicate_strategists_in_list() public view returns (bool) {
        address[] memory all = registry.getAllStrategists();
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = i + 1; j < all.length; j++) {
                if (all[i] == all[j]) return false;
            }
        }
        return true;
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: reassignPool never leaves a pool attributed to its old
    // strategist's list after moving to a new one — i.e. after any
    // successful reassignment, the pool must appear in the new owner's
    // list and must NOT still appear in the previous owner's list.
    // ════════════════════════════════════════════════════════════════════
    function testReassignPoolFullyMovesOwnership(uint256 pSeed, uint256 s1Seed, uint256 s2Seed) public {
        PoolId p = poolIdPool[pSeed % poolIdPool.length];
        address s1 = strategistPool[s1Seed % strategistPool.length];
        address s2 = strategistPool[s2Seed % strategistPool.length];
        require(s1 != s2, "need two distinct strategists");

        if (!registry.isRegisteredStrategist(s1)) registry.registerStrategist(s1, "s1");
        if (!registry.isRegisteredStrategist(s2)) registry.registerStrategist(s2, "s2");

        if (registry.poolStrategist(p) == address(0)) {
            registry.assignPoolToStrategist(s1, p);
        }
        address oldOwner = registry.poolStrategist(p);
        require(oldOwner != address(0) && oldOwner != s2, "pool not in a movable state");

        registry.reassignPool(p, s2);

        assert(registry.poolStrategist(p) == s2);

        PoolId[] memory oldOwnerPools = registry.getStrategistPools(oldOwner);
        for (uint256 i = 0; i < oldOwnerPools.length; i++) {
            assert(PoolId.unwrap(oldOwnerPools[i]) != PoolId.unwrap(p));
        }

        PoolId[] memory newOwnerPools = registry.getStrategistPools(s2);
        bool foundInNew = false;
        for (uint256 i = 0; i < newOwnerPools.length; i++) {
            if (PoolId.unwrap(newOwnerPools[i]) == PoolId.unwrap(p)) {
                foundInNew = true;
                break;
            }
        }
        assert(foundInNew);
    }

    // ════════════════════════════════════════════════════════════════════
    // Property: an already-assigned pool always rejects a second, direct
    // assignment (PoolAlreadyAssigned) — the only way to move a pool is
    // through reassignPool, never through assignPoolToStrategist again.
    // ════════════════════════════════════════════════════════════════════
    function testDoubleAssignAlwaysReverts(uint256 pSeed, uint256 s1Seed, uint256 s2Seed) public {
        PoolId p = poolIdPool[pSeed % poolIdPool.length];
        address s1 = strategistPool[s1Seed % strategistPool.length];
        address s2 = strategistPool[s2Seed % strategistPool.length];

        if (!registry.isRegisteredStrategist(s1)) registry.registerStrategist(s1, "s1");
        if (!registry.isRegisteredStrategist(s2)) registry.registerStrategist(s2, "s2");

        if (registry.poolStrategist(p) == address(0)) {
            registry.assignPoolToStrategist(s1, p);
        }

        (bool success,) =
            address(registry).call(abi.encodeWithSelector(registry.assignPoolToStrategist.selector, s2, p));
        assert(!success);
    }
}

/*//////////////////////////////////////////////////////////////////////////
    See echidna.yaml (same directory) for the required config:
    testMode: assertion, chainId: 31337.
//////////////////////////////////////////////////////////////////////////*/