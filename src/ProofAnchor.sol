// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProofAnchor
/// @notice A public, append-only list of batch roots. Each entry is (root, count, time): the Merkle root of a batch
///         of job proofs, how many proofs it covers and when it was written. Anyone can read; only the coordinator
///         can write. It never holds, receives or sends money.
/// @dev Specification: docs/proof-anchor-spec.md. `root` is opaque to this contract; how leaves and paths are built
///      is defined off-chain. There is no payable function, no receive or fallback, no external call, no
///      delegatecall and no selfdestruct. It does not interact with GPUChainEscrow in any way.
contract ProofAnchor is Ownable {
    /// @notice One anchored batch.
    /// @param root Merkle root of the batch's proofs (non-zero).
    /// @param count Number of proofs in the batch (non-zero).
    /// @param time `block.timestamp` when the batch was written.
    struct Batch {
        bytes32 root;
        uint64 count;
        uint64 time;
    }

    /// @notice The only address that may write a batch.
    address public coordinator;

    /// @notice Number of batches written so far. Ids run from 0 to `batchCount - 1`.
    uint256 public batchCount;

    mapping(uint256 id => Batch) private _batches;
    /// @dev root => id + 1; zero means "not anchored".
    mapping(bytes32 root => uint256) private _idPlusOne;

    /// @notice A batch was written.
    /// @param id Its sequential id.
    /// @param root Its Merkle root.
    /// @param count Number of proofs it covers.
    /// @param time Block timestamp of the write.
    event BatchAnchored(uint256 indexed id, bytes32 indexed root, uint64 count, uint64 time);

    /// @notice The coordinator address was replaced.
    /// @param coordinator The new coordinator.
    event CoordinatorUpdated(address indexed coordinator);

    /// @notice A zero address was given where one is not allowed.
    error ZeroAddress();
    /// @notice The caller is not the coordinator.
    error NotCoordinator();
    /// @notice The root is zero.
    error EmptyRoot();
    /// @notice The count is zero.
    error EmptyBatch();
    /// @notice This root is already anchored.
    error AlreadyAnchored();
    /// @notice No batch has this id.
    error UnknownBatch();
    /// @notice Renouncing ownership is disabled so the coordinator can always be rotated.
    error RenounceDisabled();

    /// @param owner_ Address that may replace the coordinator (a team-held address).
    /// @param coordinator_ The first coordinator address (non-zero).
    constructor(address owner_, address coordinator_) Ownable(owner_) {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorUpdated(coordinator_);
    }

    /// @notice Write one batch. Callable only by the coordinator. Entries can never be changed or removed.
    /// @param root Merkle root of the batch (non-zero, not already anchored).
    /// @param count Number of proofs in the batch (non-zero).
    /// @return id The new batch's sequential id.
    function anchor(bytes32 root, uint64 count) external returns (uint256 id) {
        if (msg.sender != coordinator) revert NotCoordinator();
        if (root == bytes32(0)) revert EmptyRoot();
        if (count == 0) revert EmptyBatch();
        if (_idPlusOne[root] != 0) revert AlreadyAnchored();

        id = batchCount;
        batchCount = id + 1;
        _idPlusOne[root] = id + 1;
        uint64 time = uint64(block.timestamp);
        _batches[id] = Batch({root: root, count: count, time: time});
        emit BatchAnchored(id, root, count, time);
    }

    /// @notice Read one batch.
    /// @param id The batch id (must be below `batchCount`).
    /// @return root The batch's Merkle root.
    /// @return count Number of proofs it covers.
    /// @return time Block timestamp when it was written.
    function getBatch(uint256 id) external view returns (bytes32 root, uint64 count, uint64 time) {
        if (id >= batchCount) revert UnknownBatch();
        Batch storage b = _batches[id];
        return (b.root, b.count, b.time);
    }

    /// @notice Ask whether a root has been anchored, and in which batch.
    /// @param root The root to look up.
    /// @return found True if the root is anchored.
    /// @return id Its batch id (zero when `found` is false; check `found`).
    function isAnchored(bytes32 root) external view returns (bool found, uint256 id) {
        uint256 stored = _idPlusOne[root];
        if (stored == 0) return (false, 0);
        return (true, stored - 1);
    }

    /// @notice Replace the coordinator, for example to rotate its key. Callable only by the owner.
    /// @param newCoordinator The new coordinator (non-zero).
    function setCoordinator(address newCoordinator) external onlyOwner {
        if (newCoordinator == address(0)) revert ZeroAddress();
        coordinator = newCoordinator;
        emit CoordinatorUpdated(newCoordinator);
    }

    /// @notice Always reverts. Without an owner the coordinator could never be rotated.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
