// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @title BucketTree — Sparse Lazy Multiplicative Segment Tree for LMSR Buckets
/// @notice Stores WAD-scaled exp weights as leaf values. Supports O(log n) range
///         multiplicative updates and O(log n) range sum queries.
/// @dev Node packing: sum (256 bits, slot 1) + pendingFactor|childPtr (256 bits, slot 2).
///      Sparse: nodes allocated on first write via mapping(uint32 => Node).
///      Unallocated nodes default to (rangeSize * defaultLeafValue).
///
///      Correlated with:
///        - Signals Protocol: LazyMulSegmentTree (same tree pattern, factor bounds, flush logic)
///        - Sui implementation: SparseDistribution (sparse storage concept, on-demand allocation)
library BucketTree {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_FACTOR = 0.01e18;   // 1%  — floor for multiplicative factor
    uint256 internal constant MAX_FACTOR = 100e18;     // 100x — ceiling for multiplicative factor
    uint256 internal constant FLUSH_THRESHOLD = 1e21;  // Push down when pending > 1000 WAD
    uint256 internal constant UNDERFLOW_THRESHOLD = 1e15; // Push down when pending < 0.001 WAD

    error TreeNotInitialized();
    error TreeAlreadyInitialized();
    error TreeSizeZero();
    error TreeSizeTooLarge();
    error InvalidRange(uint32 lo, uint32 hi);
    error IndexOutOfBounds(uint32 index, uint32 size);
    error InvalidFactor(uint256 factor);
    error FactorOverflow();

    /// @dev 2 storage slots per node:
    ///   Slot 1: sum (uint256)       — subtree sum of exp weights (WAD-scaled)
    ///   Slot 2: pendingFactor|childPtr — lazy factor (uint192) + packed child IDs (uint64)
    struct Node {
        uint256 sum;
        uint192 pendingFactor; // WAD = identity (1e18). Composed lazily on range updates.
        uint64 childPtr;       // Packed: leftId (uint32) | rightId (uint32)
    }

    struct Tree {
        mapping(uint32 => Node) nodes;
        uint32 rootId;            // Root node ID (always allocated after init)
        uint32 nextId;            // Allocation counter for sparse nodes
        uint32 leafCount;         // Total leaves (= bucketCount)
        uint256 rootSum;          // Cached Σ all leaf values — always current after mutations
        uint256 defaultLeafValue; // Initial value per leaf for sparse defaults
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          PUBLIC API
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Initialize tree with uniform leaf values
    /// @param tree Storage reference to tree
    /// @param _leafCount Number of leaves (= bucketCount)
    /// @param _defaultLeafValue Initial WAD value per leaf, e.g. exp((q+phantom)/alpha)
    function init(
        Tree storage tree,
        uint32 _leafCount,
        uint256 _defaultLeafValue
    ) internal {
        if (_leafCount == 0) revert TreeSizeZero();
        if (tree.leafCount != 0) revert TreeAlreadyInitialized();
        if (_leafCount > type(uint32).max / 2) revert TreeSizeTooLarge();

        tree.leafCount = _leafCount;
        tree.defaultLeafValue = _defaultLeafValue;
        tree.nextId = 0;
        tree.rootId = _allocNode(tree, 0, _leafCount - 1);
        tree.rootSum = tree.nodes[tree.rootId].sum;
    }

    /// @notice Apply multiplicative factor to leaves [lo, hi] inclusive
    /// @dev O(log n) via lazy propagation. rootSum updated atomically.
    /// @param tree Storage reference to tree
    /// @param lo Start leaf index (inclusive)
    /// @param hi End leaf index (inclusive)
    /// @param factor Multiplicative factor in WAD (1e18 = no change)
    function applyFactor(
        Tree storage tree,
        uint32 lo,
        uint32 hi,
        uint256 factor
    ) internal {
        if (tree.leafCount == 0) revert TreeNotInitialized();
        if (lo > hi) revert InvalidRange(lo, hi);
        if (hi >= tree.leafCount) revert IndexOutOfBounds(hi, tree.leafCount);
        if (factor < MIN_FACTOR || factor > MAX_FACTOR) revert InvalidFactor(factor);

        _applyFactorRecursive(tree, tree.rootId, 0, tree.leafCount - 1, lo, hi, factor);
    }

    /// @notice Query sum of leaf values in range [lo, hi] inclusive
    /// @dev O(log n), read-only. Uses accumulated factor pattern (no storage writes).
    function rangeSum(
        Tree storage tree,
        uint32 lo,
        uint32 hi
    ) internal view returns (uint256) {
        if (tree.leafCount == 0) revert TreeNotInitialized();
        if (lo > hi) revert InvalidRange(lo, hi);
        if (hi >= tree.leafCount) revert IndexOutOfBounds(hi, tree.leafCount);

        return _rangeSumRecursive(tree, tree.rootId, 0, tree.leafCount - 1, lo, hi, WAD);
    }

    /// @notice Get a single leaf's current value — O(log n)
    function leafValue(Tree storage tree, uint32 leafId) internal view returns (uint256) {
        if (leafId >= tree.leafCount) revert IndexOutOfBounds(leafId, tree.leafCount);
        return _rangeSumRecursive(tree, tree.rootId, 0, tree.leafCount - 1, leafId, leafId, WAD);
    }

    /// @notice Total sum of all leaves — O(1) from cached rootSum
    function totalSum(Tree storage tree) internal view returns (uint256) {
        return tree.rootSum;
    }

    /// @notice Rebuild tree from an array of per-leaf values (used for alpha decay)
    /// @dev O(n log n). Resets entire tree and rebuilds bottom-up.
    /// @param tree Storage reference to tree (must already be initialized)
    /// @param values Array of WAD-scaled leaf values, length must equal leafCount
    function seedWithValues(Tree storage tree, uint256[] memory values) internal {
        if (tree.leafCount == 0) revert TreeNotInitialized();
        uint32 lc = tree.leafCount;
        require(values.length == uint256(lc), "BucketTree: length mismatch");

        // Reset allocation counter (old nodes become garbage — mapping slots stay but are unused)
        tree.nextId = 0;

        (uint32 rootId, uint256 total) = _buildFromArray(tree, 0, lc - 1, values);
        tree.rootId = rootId;
        tree.rootSum = total;
    }

    /// @notice Rebuild tree with a new leaf count and values (used for expansion)
    /// @dev O(n log n). Resets tree and rebuilds with potentially different leaf count.
    /// @param tree Storage reference to tree (must already be initialized)
    /// @param newLeafCount New number of leaves
    /// @param values Array of WAD-scaled leaf values, length must equal newLeafCount
    function rebuildWithSize(Tree storage tree, uint32 newLeafCount, uint256[] memory values) internal {
        if (tree.leafCount == 0) revert TreeNotInitialized();
        if (newLeafCount == 0) revert TreeSizeZero();
        if (newLeafCount > type(uint32).max / 2) revert TreeSizeTooLarge();
        require(values.length == uint256(newLeafCount), "BucketTree: length mismatch");

        tree.leafCount = newLeafCount;
        tree.defaultLeafValue = 0; // Expanded trees use 0 for inactive leaves
        tree.nextId = 0;

        (uint32 rootId, uint256 total) = _buildFromArray(tree, 0, newLeafCount - 1, values);
        tree.rootId = rootId;
        tree.rootSum = total;
    }

    /// @notice Set a single leaf's value directly — O(log n)
    /// @dev Used for bucket activation (inactive → phantom weight).
    ///      Pushes down lazy factors on the path, sets leaf sum, pulls up sums.
    /// @param tree Storage reference to tree
    /// @param leafId Leaf index to set
    /// @param newValue New WAD-scaled value for the leaf
    function setLeaf(Tree storage tree, uint32 leafId, uint256 newValue) internal {
        if (tree.leafCount == 0) revert TreeNotInitialized();
        if (leafId >= tree.leafCount) revert IndexOutOfBounds(leafId, tree.leafCount);

        _setLeafRecursive(tree, tree.rootId, 0, tree.leafCount - 1, leafId, newValue);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       RECURSIVE CORE
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Apply factor to range [lo,hi] within node covering [l,r].
    ///      Follows Signals Protocol pattern: pre-flush → scale → set pending.
    function _applyFactorRecursive(
        Tree storage tree,
        uint32 nodeId,
        uint32 l,
        uint32 r,
        uint32 lo,
        uint32 hi,
        uint256 factor
    ) private {
        if (r < lo || l > hi) return;
        if (nodeId == 0) return;

        Node storage node = tree.nodes[nodeId];

        // ── Fully covered by [lo, hi] ──
        if (l >= lo && r <= hi) {
            // Leaf: scale sum directly, no lazy needed
            if (l == r) {
                node.sum = _mulWad(node.sum, factor);
                if (nodeId == tree.rootId) tree.rootSum = node.sum;
                return;
            }

            // Internal node fully covered
            uint256 priorPending = uint256(node.pendingFactor);
            uint256 combinedPending = _combineFactor(priorPending, factor);

            // Pre-flush: if combined pending would exceed threshold, push down OLD
            // pending first. After push, node.sum = correct pre-factor sum, pending = WAD.
            if (
                priorPending != WAD &&
                (combinedPending > FLUSH_THRESHOLD || combinedPending < UNDERFLOW_THRESHOLD)
            ) {
                _pushDown(tree, nodeId, l, r);
                priorPending = WAD; // pending is WAD after push
            }

            // Scale sum by factor — now node.sum = correct post-factor sum
            node.sum = _mulWad(node.sum, factor);

            // Compute final pending
            uint256 newPending = _combineFactor(priorPending, factor);

            // Post-check: if newPending still exceeds threshold (edge case),
            // push down factor and reset pending
            if (newPending > FLUSH_THRESHOLD || newPending < UNDERFLOW_THRESHOLD) {
                node.pendingFactor = uint192(factor);
                _pushDown(tree, nodeId, l, r);
                node.pendingFactor = uint192(WAD);
            } else {
                if (newPending > type(uint192).max) revert FactorOverflow();
                node.pendingFactor = uint192(newPending);
            }

            if (nodeId == tree.rootId) tree.rootSum = node.sum;
            return;
        }

        // ── Partially covered: push down, recurse, pull up ──
        _pushDown(tree, nodeId, l, r);

        uint32 mid = l + (r - l) / 2;
        (uint32 leftId, uint32 rightId) = _unpackChildPtr(node.childPtr);

        if (lo <= mid) {
            if (leftId == 0) leftId = _allocNode(tree, l, mid);
            _applyFactorRecursive(tree, leftId, l, mid, lo, hi, factor);
        }
        if (hi > mid) {
            if (rightId == 0) rightId = _allocNode(tree, mid + 1, r);
            _applyFactorRecursive(tree, rightId, mid + 1, r, lo, hi, factor);
        }

        node.childPtr = _packChildPtr(leftId, rightId);

        // Pull up: recompute sum from children
        uint256 leftSum = leftId != 0 ? tree.nodes[leftId].sum : _defaultSum(tree, l, mid);
        uint256 rightSum = rightId != 0 ? tree.nodes[rightId].sum : _defaultSum(tree, mid + 1, r);
        node.sum = leftSum + rightSum;

        if (nodeId == tree.rootId) tree.rootSum = node.sum;
    }

    /// @dev Read-only range sum with accumulated factor (no storage writes).
    ///      accFactor carries un-pushed pending factors from ancestors.
    function _rangeSumRecursive(
        Tree storage tree,
        uint32 nodeId,
        uint32 l,
        uint32 r,
        uint32 lo,
        uint32 hi,
        uint256 accFactor
    ) private view returns (uint256) {
        // Unallocated node — compute from defaults
        if (nodeId == 0) {
            if (r < lo || l > hi) return 0;
            uint32 overlapL = lo > l ? lo : l;
            uint32 overlapR = hi < r ? hi : r;
            return _mulWad(_defaultSum(tree, overlapL, overlapR), accFactor);
        }

        if (r < lo || l > hi) return 0;

        // Fully covered — node.sum already correct, multiply by ancestor factor
        if (l >= lo && r <= hi) {
            return _mulWad(tree.nodes[nodeId].sum, accFactor);
        }

        // Partially covered — compose this node's pending into accFactor
        uint256 newAcc = _combineFactor(accFactor, uint256(tree.nodes[nodeId].pendingFactor));
        uint32 mid = l + (r - l) / 2;
        (uint32 leftId, uint32 rightId) = _unpackChildPtr(tree.nodes[nodeId].childPtr);

        uint256 leftSum = _rangeSumRecursive(tree, leftId, l, mid, lo, hi, newAcc);
        uint256 rightSum = _rangeSumRecursive(tree, rightId, mid + 1, r, lo, hi, newAcc);

        return leftSum + rightSum;
    }

    /// @dev Set a single leaf's value. Push down pending factors on the path,
    ///      set the leaf, then pull up sums.
    function _setLeafRecursive(
        Tree storage tree,
        uint32 nodeId,
        uint32 l,
        uint32 r,
        uint32 leafId,
        uint256 newValue
    ) private {
        if (nodeId == 0) return;

        Node storage node = tree.nodes[nodeId];

        // Leaf reached
        if (l == r) {
            node.sum = newValue;
            if (nodeId == tree.rootId) tree.rootSum = newValue;
            return;
        }

        // Push down lazy before descending
        _pushDown(tree, nodeId, l, r);

        uint32 mid = l + (r - l) / 2;
        (uint32 leftId, uint32 rightId) = _unpackChildPtr(node.childPtr);

        if (leafId <= mid) {
            if (leftId == 0) leftId = _allocNode(tree, l, mid);
            _setLeafRecursive(tree, leftId, l, mid, leafId, newValue);
        } else {
            if (rightId == 0) rightId = _allocNode(tree, mid + 1, r);
            _setLeafRecursive(tree, rightId, mid + 1, r, leafId, newValue);
        }

        node.childPtr = _packChildPtr(leftId, rightId);

        // Pull up: recompute sum from children
        uint256 leftSum = leftId != 0 ? tree.nodes[leftId].sum : _defaultSum(tree, l, mid);
        uint256 rightSum = rightId != 0 ? tree.nodes[rightId].sum : _defaultSum(tree, mid + 1, r);
        node.sum = leftSum + rightSum;

        if (nodeId == tree.rootId) tree.rootSum = node.sum;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       NODE OPERATIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Push pending factor to children. Allocates children if needed.
    ///      After push: node.pendingFactor = WAD, node.sum unchanged (via pull-up).
    function _pushDown(Tree storage tree, uint32 nodeId, uint32 l, uint32 r) private {
        if (nodeId == 0 || l == r) return;

        Node storage node = tree.nodes[nodeId];
        uint256 pending = uint256(node.pendingFactor);
        if (pending == WAD) return;

        uint32 mid = l + (r - l) / 2;
        (uint32 leftId, uint32 rightId) = _unpackChildPtr(node.childPtr);

        if (leftId == 0) leftId = _allocNode(tree, l, mid);
        if (rightId == 0) rightId = _allocNode(tree, mid + 1, r);

        _applyFactorToChild(tree, leftId, pending, l, mid);
        _applyFactorToChild(tree, rightId, pending, mid + 1, r);

        node.childPtr = _packChildPtr(leftId, rightId);
        node.pendingFactor = uint192(WAD);

        // Pull up: recompute sum from now-correct children
        node.sum = tree.nodes[leftId].sum + tree.nodes[rightId].sum;
        if (nodeId == tree.rootId) tree.rootSum = node.sum;
    }

    /// @dev Apply factor to a child during push-down, with recursive flush if needed.
    ///      Follows Signals' _applyFactorToChildWithFlush pattern.
    function _applyFactorToChild(
        Tree storage tree,
        uint32 nodeId,
        uint256 factor,
        uint32 l,
        uint32 r
    ) private {
        if (nodeId == 0 || factor == WAD) return;

        Node storage node = tree.nodes[nodeId];
        uint256 priorPending = uint256(node.pendingFactor);
        uint256 newPending = _combineFactor(priorPending, factor);

        // Recursive flush if combined pending exceeds threshold
        if (
            r > l &&
            priorPending != WAD &&
            (newPending > FLUSH_THRESHOLD || newPending < UNDERFLOW_THRESHOLD)
        ) {
            _pushDown(tree, nodeId, l, r);
            newPending = factor;
        } else if (newPending > type(uint192).max) {
            revert FactorOverflow();
        }

        node.sum = _mulWad(node.sum, factor);
        node.pendingFactor = uint192(newPending);

        if (nodeId == tree.rootId) tree.rootSum = node.sum;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                         ALLOCATION
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Allocate a new node with default sum for range [l, r]
    function _allocNode(Tree storage tree, uint32 l, uint32 r) private returns (uint32 newId) {
        newId = ++tree.nextId;
        Node storage node = tree.nodes[newId];
        node.pendingFactor = uint192(WAD);
        node.sum = _defaultSum(tree, l, r);
    }

    /// @dev Default sum for unallocated range [l, r] = (r - l + 1) * defaultLeafValue
    function _defaultSum(Tree storage tree, uint32 l, uint32 r) private view returns (uint256) {
        unchecked {
            return uint256(r - l + 1) * tree.defaultLeafValue;
        }
    }

    /// @dev Build tree bottom-up from an array of leaf values
    function _buildFromArray(
        Tree storage tree,
        uint32 l,
        uint32 r,
        uint256[] memory values
    ) private returns (uint32 nodeId, uint256 sum) {
        nodeId = _allocNode(tree, l, r);
        Node storage node = tree.nodes[nodeId];

        if (l == r) {
            node.sum = values[uint256(l)];
            return (nodeId, values[uint256(l)]);
        }

        uint32 mid = l + (r - l) / 2;
        (uint32 leftId, uint256 leftSum) = _buildFromArray(tree, l, mid, values);
        (uint32 rightId, uint256 rightSum) = _buildFromArray(tree, mid + 1, r, values);

        node.childPtr = _packChildPtr(leftId, rightId);
        sum = leftSum + rightSum;
        node.sum = sum;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        MATH HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev WAD multiply: (a * b) / WAD. Uses Math.mulDiv for overflow safety.
    function _mulWad(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        if (b == WAD) return a;
        if (a == WAD) return b;
        return Math.mulDiv(a, b, WAD);
    }

    /// @dev Combine two WAD-scaled factors: (a * b) / WAD
    function _combineFactor(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == WAD) return b;
        if (b == WAD) return a;
        if (a == 0 || b == 0) return 0;
        return Math.mulDiv(a, b, WAD);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     CHILD POINTER PACKING
    // ═══════════════════════════════════════════════════════════════════

    function _packChildPtr(uint32 left, uint32 right) private pure returns (uint64) {
        return (uint64(left) << 32) | uint64(right);
    }

    function _unpackChildPtr(uint64 packed) private pure returns (uint32 left, uint32 right) {
        left = uint32(packed >> 32);
        right = uint32(packed);
    }
}
