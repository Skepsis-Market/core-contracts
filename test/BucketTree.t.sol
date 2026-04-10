// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BucketTree} from "../src/BucketTree.sol";

/// @dev Wrapper contract to test library reverts via external calls
contract BucketTreeWrapper {
    using BucketTree for BucketTree.Tree;
    BucketTree.Tree internal tree;

    function init(uint32 leafCount, uint256 defaultLeafValue) external {
        tree.init(leafCount, defaultLeafValue);
    }
    function applyFactor(uint32 lo, uint32 hi, uint256 factor) external {
        tree.applyFactor(lo, hi, factor);
    }
    function rangeSum(uint32 lo, uint32 hi) external view returns (uint256) {
        return tree.rangeSum(lo, hi);
    }
    function leafValue(uint32 leafId) external view returns (uint256) {
        return tree.leafValue(leafId);
    }
    function totalSum() external view returns (uint256) {
        return tree.totalSum();
    }
    function seedWithValues(uint256[] memory values) external {
        tree.seedWithValues(values);
    }
    function setLeaf(uint32 leafId, uint256 newValue) external {
        tree.setLeaf(leafId, newValue);
    }
    function getNextId() external view returns (uint32) { return tree.nextId; }
    function getLeafCount() external view returns (uint32) { return tree.leafCount; }
    function getRootId() external view returns (uint32) { return tree.rootId; }
    function getDefaultLeafValue() external view returns (uint256) { return tree.defaultLeafValue; }
}

/// @title BucketTree Tests — Sparse Lazy Multiplicative Segment Tree
/// @dev Validates init, factor application, range queries, lazy propagation,
///      sparse allocation, flush thresholds, and seedWithValues.
contract BucketTreeTest is Test {
    using BucketTree for BucketTree.Tree;

    uint256 constant WAD = 1e18;

    BucketTree.Tree internal tree;
    BucketTreeWrapper internal wrapper;

    function setUp() public {
        wrapper = new BucketTreeWrapper();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        INIT TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_init_basicSetup() public {
        tree.init(19, WAD);

        assertEq(tree.leafCount, 19);
        assertEq(tree.totalSum(), 19 * WAD);
        assertEq(tree.defaultLeafValue, WAD);
        assertTrue(tree.rootId != 0);
    }

    function test_init_withCustomDefaultValue() public {
        // Simulate exp((1000000 + 1) * 1e18 / 100000000) ≈ exp(0.01) ≈ 1.01005e18
        uint256 initialExp = 1_010050167084168000; // exp(0.01) in WAD
        tree.init(19, initialExp);

        assertEq(tree.leafCount, 19);
        assertEq(tree.totalSum(), 19 * initialExp);
        assertEq(tree.leafValue(0), initialExp);
        assertEq(tree.leafValue(18), initialExp);
    }

    function test_init_singleLeaf() public {
        tree.init(1, WAD);

        assertEq(tree.leafCount, 1);
        assertEq(tree.totalSum(), WAD);
        assertEq(tree.leafValue(0), WAD);
    }

    function test_init_twoLeaves() public {
        tree.init(2, WAD);

        assertEq(tree.leafCount, 2);
        assertEq(tree.totalSum(), 2 * WAD);
        assertEq(tree.leafValue(0), WAD);
        assertEq(tree.leafValue(1), WAD);
    }

    function test_init_revertOnZero() public {
        vm.expectRevert(BucketTree.TreeSizeZero.selector);
        wrapper.init(0, WAD);
    }

    function test_init_revertOnDoubleInit() public {
        wrapper.init(10, WAD);
        vm.expectRevert(BucketTree.TreeAlreadyInitialized.selector);
        wrapper.init(10, WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     SINGLE FACTOR TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_applyFactor_singleLeaf() public {
        tree.init(19, WAD);

        // Double leaf 5
        tree.applyFactor(5, 5, 2 * WAD);

        assertEq(tree.leafValue(5), 2 * WAD);
        assertEq(tree.leafValue(0), WAD); // Other leaves unchanged
        assertEq(tree.leafValue(18), WAD);
        assertEq(tree.totalSum(), 20 * WAD); // 18 * 1 + 1 * 2 = 20
    }

    function test_applyFactor_fullRange() public {
        tree.init(19, WAD);

        // Triple all leaves
        tree.applyFactor(0, 18, 3 * WAD);

        assertEq(tree.leafValue(0), 3 * WAD);
        assertEq(tree.leafValue(9), 3 * WAD);
        assertEq(tree.leafValue(18), 3 * WAD);
        assertEq(tree.totalSum(), 57 * WAD); // 19 * 3 = 57
    }

    function test_applyFactor_subRange() public {
        tree.init(19, WAD);

        // 5x to buckets [3, 7]
        tree.applyFactor(3, 7, 5 * WAD);

        // 5 buckets at 5.0, 14 buckets at 1.0
        assertEq(tree.leafValue(3), 5 * WAD);
        assertEq(tree.leafValue(7), 5 * WAD);
        assertEq(tree.leafValue(2), WAD); // Before range
        assertEq(tree.leafValue(8), WAD); // After range
        assertEq(tree.totalSum(), (14 + 25) * WAD); // 39 * WAD
    }

    function test_applyFactor_fractionalFactor() public {
        tree.init(4, WAD);

        // Halve leaf 0
        tree.applyFactor(0, 0, WAD / 2);

        assertEq(tree.leafValue(0), WAD / 2);
        assertEq(tree.totalSum(), WAD / 2 + 3 * WAD); // 3.5 * WAD
    }

    function test_applyFactor_identityFactor() public {
        tree.init(4, WAD);

        // Factor = 1.0 should be a no-op
        tree.applyFactor(0, 3, WAD);

        assertEq(tree.totalSum(), 4 * WAD);
        assertEq(tree.leafValue(0), WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   MULTI-FACTOR COMPOSITION
    // ═══════════════════════════════════════════════════════════════════

    function test_multipleFactors_sequential() public {
        tree.init(4, WAD);

        // 2x on [0,3], then 3x on [0,3]
        tree.applyFactor(0, 3, 2 * WAD);
        tree.applyFactor(0, 3, 3 * WAD);

        // Each leaf: 1 * 2 * 3 = 6
        assertEq(tree.leafValue(0), 6 * WAD);
        assertEq(tree.totalSum(), 24 * WAD);
    }

    function test_multipleFactors_overlappingRanges() public {
        tree.init(8, WAD);

        // 2x on [0,3]
        tree.applyFactor(0, 3, 2 * WAD);
        // 3x on [2,5]
        tree.applyFactor(2, 5, 3 * WAD);

        // Leaf 0: 2.0 (only first factor)
        // Leaf 2: 6.0 (both factors)
        // Leaf 3: 6.0 (both factors)
        // Leaf 4: 3.0 (only second factor)
        // Leaf 6: 1.0 (no factors)
        assertEq(tree.leafValue(0), 2 * WAD);
        assertEq(tree.leafValue(1), 2 * WAD);
        assertEq(tree.leafValue(2), 6 * WAD);
        assertEq(tree.leafValue(3), 6 * WAD);
        assertEq(tree.leafValue(4), 3 * WAD);
        assertEq(tree.leafValue(5), 3 * WAD);
        assertEq(tree.leafValue(6), WAD);
        assertEq(tree.leafValue(7), WAD);
        // Total: 2+2+6+6+3+3+1+1 = 24
        assertEq(tree.totalSum(), 24 * WAD);
    }

    function test_multipleFactors_manySequential() public {
        tree.init(4, WAD);

        // Apply 10 sequential 1.1x factors to full range
        for (uint256 i = 0; i < 10; i++) {
            tree.applyFactor(0, 3, 1.1e18); // 1.1 WAD
        }

        // 1.1^10 ≈ 2.5937424601
        uint256 expected = 2_593742460100000000; // Approx
        uint256 actual = tree.leafValue(0);
        // Allow 1 basis point tolerance for rounding
        assertApproxEqRel(actual, expected, 1e14); // 0.01% tolerance
        assertApproxEqRel(tree.totalSum(), 4 * expected, 1e14);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      RANGE SUM QUERIES
    // ═══════════════════════════════════════════════════════════════════

    function test_rangeSum_fullRange() public {
        tree.init(8, WAD);
        tree.applyFactor(0, 3, 2 * WAD);

        assertEq(tree.rangeSum(0, 7), tree.totalSum());
    }

    function test_rangeSum_partialRange() public {
        tree.init(8, WAD);
        tree.applyFactor(0, 3, 2 * WAD);

        // [0,3]: all at 2.0 = 8 WAD
        assertEq(tree.rangeSum(0, 3), 8 * WAD);
        // [4,7]: all at 1.0 = 4 WAD
        assertEq(tree.rangeSum(4, 7), 4 * WAD);
        // [2,5]: 2 at 2.0 + 2 at 1.0 = 6 WAD
        assertEq(tree.rangeSum(2, 5), 6 * WAD);
    }

    function test_rangeSum_singleBucket() public {
        tree.init(8, WAD);
        tree.applyFactor(3, 3, 5 * WAD);

        assertEq(tree.rangeSum(3, 3), 5 * WAD);
        assertEq(tree.rangeSum(2, 2), WAD);
    }

    function test_rangeSum_consistentWithTotalSum() public {
        tree.init(19, WAD);

        // Apply various factors
        tree.applyFactor(0, 4, 2 * WAD);
        tree.applyFactor(5, 9, 3 * WAD);
        tree.applyFactor(10, 14, 4 * WAD);
        tree.applyFactor(15, 18, 5 * WAD);

        // Sum of all sub-ranges should equal totalSum
        uint256 sum = tree.rangeSum(0, 4) + tree.rangeSum(5, 9) +
                      tree.rangeSum(10, 14) + tree.rangeSum(15, 18);
        assertEq(sum, tree.totalSum());
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    SPARSE ALLOCATION
    // ═══════════════════════════════════════════════════════════════════

    function test_sparse_noUnnecessaryAllocation() public {
        tree.init(100, WAD);

        uint32 initialNextId = tree.nextId;

        // Apply factor to full range — no children allocated (lazy at root)
        tree.applyFactor(0, 99, 2 * WAD);

        // Only root should exist, no new nodes allocated
        assertEq(tree.nextId, initialNextId);
        assertEq(tree.totalSum(), 200 * WAD);
    }

    function test_sparse_partialAllocatesOnDemand() public {
        tree.init(100, WAD);

        uint32 initialNextId = tree.nextId;

        // Factor on sub-range forces allocation of intermediate nodes
        tree.applyFactor(50, 60, 3 * WAD);

        // Should have allocated some nodes (at least path from root to leaves)
        assertTrue(tree.nextId > initialNextId);

        // But results should still be correct
        assertEq(tree.leafValue(50), 3 * WAD);
        assertEq(tree.leafValue(49), WAD);
        assertEq(tree.totalSum(), (89 + 33) * WAD); // 89 * 1 + 11 * 3 = 122
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      FACTOR BOUNDS
    // ═══════════════════════════════════════════════════════════════════

    function test_factorBounds_revertBelowMin() public {
        wrapper.init(4, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.InvalidFactor.selector, 0.009e18));
        wrapper.applyFactor(0, 3, 0.009e18);
    }

    function test_factorBounds_revertAboveMax() public {
        wrapper.init(4, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.InvalidFactor.selector, 101e18));
        wrapper.applyFactor(0, 3, 101e18);
    }

    function test_factorBounds_minFactorAllowed() public {
        tree.init(4, WAD);

        // MIN_FACTOR = 0.01e18 should work
        tree.applyFactor(0, 0, 0.01e18);
        assertEq(tree.leafValue(0), 0.01e18);
    }

    function test_factorBounds_maxFactorAllowed() public {
        tree.init(4, WAD);

        // MAX_FACTOR = 100e18 should work
        tree.applyFactor(0, 0, 100e18);
        assertEq(tree.leafValue(0), 100 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     FLUSH THRESHOLD
    // ═══════════════════════════════════════════════════════════════════

    function test_flushThreshold_manyFactorsNoCorruption() public {
        tree.init(4, WAD);

        // Apply MAX_FACTOR (100x) 5 times to full range
        // pending would be 100^5 = 1e10 WAD without flush
        // With flush threshold at 1e21 WAD, flushes happen along the way
        for (uint256 i = 0; i < 5; i++) {
            tree.applyFactor(0, 3, 100e18);
        }

        // Each leaf: 1 * 100^5 = 1e10
        uint256 expected = 1e10 * WAD;
        assertApproxEqRel(tree.leafValue(0), expected, 1e14);
        assertApproxEqRel(tree.totalSum(), 4 * expected, 1e14);
    }

    function test_flushThreshold_smallFactorsNoCorruption() public {
        tree.init(4, WAD);

        // Apply MIN_FACTOR (0.01x) 3 times to full range
        // pending would be 0.01^3 = 1e-6 WAD without flush
        // With underflow threshold at 1e15 WAD, flushes happen
        for (uint256 i = 0; i < 3; i++) {
            tree.applyFactor(0, 3, 0.01e18);
        }

        // Each leaf: 1 * 0.01^3 = 1e-6
        uint256 expected = 1e12; // 1e-6 * 1e18 = 1e12
        assertApproxEqRel(tree.leafValue(0), expected, 1e14);
        assertApproxEqRel(tree.totalSum(), 4 * expected, 1e14);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     INDEX VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_revert_loGreaterThanHi() public {
        wrapper.init(10, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.InvalidRange.selector, 5, 3));
        wrapper.applyFactor(5, 3, 2 * WAD);
    }

    function test_revert_indexOutOfBounds() public {
        wrapper.init(10, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.IndexOutOfBounds.selector, 10, 10));
        wrapper.applyFactor(0, 10, 2 * WAD);
    }

    function test_revert_rangeSumOutOfBounds() public {
        wrapper.init(10, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.IndexOutOfBounds.selector, 10, 10));
        wrapper.rangeSum(0, 10);
    }

    function test_leafValueOutOfBounds_returnsZero() public {
        wrapper.init(10, WAD);
        // Out-of-range leaves return 0 (inactive) instead of reverting
        assertEq(wrapper.leafValue(10), 0);
        assertEq(wrapper.leafValue(100), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    SEED WITH VALUES
    // ═══════════════════════════════════════════════════════════════════

    function test_seedWithValues_basic() public {
        tree.init(4, WAD);

        uint256[] memory values = new uint256[](4);
        values[0] = 10 * WAD;
        values[1] = 20 * WAD;
        values[2] = 30 * WAD;
        values[3] = 40 * WAD;

        tree.seedWithValues(values);

        assertEq(tree.leafValue(0), 10 * WAD);
        assertEq(tree.leafValue(1), 20 * WAD);
        assertEq(tree.leafValue(2), 30 * WAD);
        assertEq(tree.leafValue(3), 40 * WAD);
        assertEq(tree.totalSum(), 100 * WAD);
    }

    function test_seedWithValues_thenApplyFactor() public {
        tree.init(4, WAD);

        uint256[] memory values = new uint256[](4);
        values[0] = 2 * WAD;
        values[1] = 4 * WAD;
        values[2] = 6 * WAD;
        values[3] = 8 * WAD;

        tree.seedWithValues(values);

        // Double leaves [1,2]
        tree.applyFactor(1, 2, 2 * WAD);

        assertEq(tree.leafValue(0), 2 * WAD);
        assertEq(tree.leafValue(1), 8 * WAD);
        assertEq(tree.leafValue(2), 12 * WAD);
        assertEq(tree.leafValue(3), 8 * WAD);
        assertEq(tree.totalSum(), 30 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       SET LEAF
    // ═══════════════════════════════════════════════════════════════════

    function test_setLeaf_basic() public {
        tree.init(4, WAD);

        tree.setLeaf(2, 5 * WAD);

        assertEq(tree.leafValue(2), 5 * WAD);
        assertEq(tree.totalSum(), WAD + WAD + 5 * WAD + WAD); // 8 WAD
    }

    function test_setLeaf_afterFactors() public {
        tree.init(4, WAD);

        // Apply 3x to [0,3]
        tree.applyFactor(0, 3, 3 * WAD);

        // All leaves at 3 WAD now
        assertEq(tree.leafValue(0), 3 * WAD);

        // Override leaf 1 to 10 WAD
        tree.setLeaf(1, 10 * WAD);

        assertEq(tree.leafValue(1), 10 * WAD);
        assertEq(tree.leafValue(0), 3 * WAD); // Unaffected
        assertEq(tree.leafValue(2), 3 * WAD);
        assertEq(tree.leafValue(3), 3 * WAD);
        assertEq(tree.totalSum(), 3 * WAD + 10 * WAD + 3 * WAD + 3 * WAD); // 19 WAD
    }

    function test_setLeaf_zeroToNonzero() public {
        // Simulate expansion: tree initialized with defaultLeafValue = 0
        tree.init(8, 0);

        assertEq(tree.totalSum(), 0);
        assertEq(tree.leafValue(3), 0);

        // Activate bucket 3 with phantom weight
        uint256 phantomWeight = 1_010050167084168000; // exp(0.01) in WAD
        tree.setLeaf(3, phantomWeight);

        assertEq(tree.leafValue(3), phantomWeight);
        assertEq(tree.totalSum(), phantomWeight);

        // Activate bucket 5 too
        tree.setLeaf(5, phantomWeight);

        assertEq(tree.leafValue(5), phantomWeight);
        assertEq(tree.totalSum(), 2 * phantomWeight);

        // Other leaves still 0
        assertEq(tree.leafValue(0), 0);
        assertEq(tree.leafValue(7), 0);
    }

    function test_setLeaf_preservesOtherLeaves() public {
        tree.init(19, WAD);

        // Apply various factors
        tree.applyFactor(0, 4, 2 * WAD);
        tree.applyFactor(10, 14, 3 * WAD);

        uint256 totalBefore = tree.totalSum();
        uint256 leaf0Before = tree.leafValue(0);
        uint256 leaf10Before = tree.leafValue(10);

        // Set leaf 7 (which has factor 1.0)
        tree.setLeaf(7, 42 * WAD);

        // Other leaves must not change
        assertEq(tree.leafValue(0), leaf0Before);
        assertEq(tree.leafValue(10), leaf10Before);
        assertEq(tree.leafValue(7), 42 * WAD);
        // Total = totalBefore - oldLeaf7 + newLeaf7
        assertEq(tree.totalSum(), totalBefore - WAD + 42 * WAD);
    }

    function test_setLeaf_revertOutOfBounds() public {
        wrapper.init(10, WAD);

        vm.expectRevert(abi.encodeWithSelector(BucketTree.IndexOutOfBounds.selector, 10, 10));
        wrapper.setLeaf(10, 5 * WAD);
    }

    function test_setLeaf_thenApplyFactor() public {
        tree.init(4, 0); // All zeros

        // Activate leaf 1
        tree.setLeaf(1, 2 * WAD);
        assertEq(tree.totalSum(), 2 * WAD);

        // Apply factor to range including the activated leaf
        tree.applyFactor(0, 3, 3 * WAD);

        // Leaf 1: 2 * 3 = 6. Others: 0 * 3 = 0
        assertEq(tree.leafValue(1), 6 * WAD);
        assertEq(tree.leafValue(0), 0);
        assertEq(tree.totalSum(), 6 * WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  REALISTIC LMSR VALUES
    // ═══════════════════════════════════════════════════════════════════

    function test_realisticValues_btcMarket() public {
        // BTC market: 19 buckets, alpha = 100 USDC (6 dec), initial shares = ~526 USDC each
        // exp((526_315790 + 1) * 1e18 / 100_000000) ≈ exp(5.263) ≈ 193.24
        uint256 initialExp = 193_244867985523410000; // ~193.24 WAD (example value)
        tree.init(19, initialExp);

        // Total: 19 * 193.24 ≈ 3671.6
        assertEq(tree.totalSum(), 19 * initialExp);

        // Buy 10 shares on bucket 5: factor = exp(10_000000 * 1e18 / 100_000000) = exp(0.1) ≈ 1.10517
        uint256 buyFactor = 1_105170918075647600; // exp(0.1) in WAD
        tree.applyFactor(5, 5, buyFactor);

        // Bucket 5 should be initialExp * buyFactor
        uint256 expected5 = _mulWad(initialExp, buyFactor);
        assertApproxEqRel(tree.leafValue(5), expected5, 1e14);

        // Other buckets unchanged
        assertEq(tree.leafValue(0), initialExp);
        assertEq(tree.leafValue(18), initialExp);
    }

    function test_realisticValues_rangeBuy() public {
        uint256 initialExp = 1_010050167084168000; // exp(0.01) in WAD
        tree.init(19, initialExp);

        // Buy across buckets [3,7]: 5 buckets, factor = exp(Δq/alpha)
        uint256 factor = 1_284025416687741500; // exp(0.25) in WAD
        tree.applyFactor(3, 7, factor);

        // Verify range sum for [3,7] = 5 * initialExp * factor
        uint256 expectedRange = 5 * _mulWad(initialExp, factor);
        assertApproxEqRel(tree.rangeSum(3, 7), expectedRange, 1e14);

        // Verify totalSum = 14 * initialExp + 5 * initialExp * factor
        uint256 expectedTotal = 14 * initialExp + expectedRange;
        assertApproxEqRel(tree.totalSum(), expectedTotal, 1e14);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════════════

    function test_gas_applyFactor_singleLeaf() public {
        tree.init(19, WAD);
        uint256 gasBefore = gasleft();
        tree.applyFactor(5, 5, 2 * WAD);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("applyFactor single leaf (19-leaf tree):", gasUsed);
    }

    function test_gas_applyFactor_10Leaves() public {
        tree.init(19, WAD);
        uint256 gasBefore = gasleft();
        tree.applyFactor(3, 12, 2 * WAD);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("applyFactor 10 leaves (19-leaf tree):", gasUsed);
    }

    function test_gas_applyFactor_allLeaves() public {
        tree.init(19, WAD);
        uint256 gasBefore = gasleft();
        tree.applyFactor(0, 18, 2 * WAD);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("applyFactor all 19 leaves:", gasUsed);
    }

    function test_gas_totalSum() public {
        tree.init(19, WAD);
        tree.applyFactor(0, 18, 2 * WAD);
        uint256 gasBefore = gasleft();
        tree.totalSum();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("totalSum (cached):", gasUsed);
    }

    function test_gas_rangeSum_10() public {
        tree.init(19, WAD);
        tree.applyFactor(3, 12, 2 * WAD);
        uint256 gasBefore = gasleft();
        tree.rangeSum(3, 12);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("rangeSum 10 leaves (19-leaf tree):", gasUsed);
    }

    function test_gas_leafValue() public {
        tree.init(19, WAD);
        tree.applyFactor(5, 5, 2 * WAD);
        uint256 gasBefore = gasleft();
        tree.leafValue(5);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("leafValue (19-leaf tree):", gasUsed);
    }

    function test_gas_100Leaves_singleFactor() public {
        tree.init(100, WAD);
        uint256 gasBefore = gasleft();
        tree.applyFactor(50, 50, 2 * WAD);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("applyFactor single leaf (100-leaf tree):", gasUsed);
    }

    function test_gas_100Leaves_rangeFactor() public {
        tree.init(100, WAD);
        uint256 gasBefore = gasleft();
        tree.applyFactor(20, 70, 2 * WAD);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("applyFactor 51 leaves (100-leaf tree):", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       HELPER
    // ═══════════════════════════════════════════════════════════════════

    function _mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }
}
