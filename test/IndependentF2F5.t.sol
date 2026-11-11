// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Independent adversarial / boundary tests for the F2 and F5 fixes.
/// @dev Written for Piyush's 2026-11-07 review request. Deliberately does NOT reuse the
///      existing test base, actors, or amounts: own deployment, own verifier keys,
///      own budget/bond/window values, so a mistake shared with the original tests
///      cannot hide here. No production contract code is changed by this file.
///
/// F2 (arbiter snapshot): the arbiter is frozen into the job at funding time.
///   Angles NOT covered by AttackerReview.t.sol:
///   - two live disputes carrying different snapshot arbiters at the same time;
///   - a swap that happens between attestation and the dispute being opened;
///   - several swaps in a row before resolution (A1 -> A2 -> A3);
///   - bond destination on BOTH outcomes after a swap (client-upheld and forfeited);
///   - arbiter-timeout settlement after a swap (new arbiter has no way in);
///   - admin boundaries: zero-address arbiter, non-owner setArbiter.
///
/// F5 (no activation after deadline):
///   - exact-second boundaries: deadline-1 ok, deadline reverts, deadline+1 reverts;
///   - createJob deadline == now reverts, == now+1 works;
///   - check ordering: non-coordinator, wrong state, already refunded;
///   - the escape hatch still works at its own exact boundary (deadline + 1 hour).
contract IndependentBase is Test {
    GPUChainEscrow internal escrow;
    MockUSDC internal usdc;

    address internal owner = makeAddr("ind-owner");
    address internal coordinator = makeAddr("ind-coordinator");
    address internal arbiterOne = makeAddr("ind-arbiter-one");
    address internal arbiterTwo = makeAddr("ind-arbiter-two");
    address internal arbiterThree = makeAddr("ind-arbiter-three");
    address internal client = makeAddr("ind-client");
    address internal workerA = makeAddr("ind-worker-a");
    address internal workerB = makeAddr("ind-worker-b");
    address internal outsider = makeAddr("ind-outsider");

    uint256[3] internal vKeys;
    address[3] internal vAddrs;

    uint256 internal constant BUDGET = 7_500_000; // 7.5 USDC, differs from existing tests on purpose
    uint256 internal constant BOND = 1_000_000; // matches the deployed disputeBond (1 USDC)
    uint64 internal constant WINDOW = 2 hours; // differs from existing tests on purpose
    uint64 internal constant T0 = 1_700_000_000; // fixed clock start for exact boundary work

    function setUp() public virtual {
        vm.warp(T0);
        uint256[3] memory keys = [uint256(0xD15EA5E), uint256(0xFEED), uint256(0xBADDCAFE)];
        address[3] memory addrs = [vm.addr(keys[0]), vm.addr(keys[1]), vm.addr(keys[2])];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        vKeys = keys;
        vAddrs = addrs;

        usdc = new MockUSDC();
        address[] memory verifiers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            verifiers[i] = addrs[i];
        }
        escrow = new GPUChainEscrow(IERC20(address(usdc)), owner, coordinator, arbiterOne, verifiers, 2, BOND);

        usdc.mint(client, 200_000_000);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _fund(bytes32 id, uint64 dl) internal {
        vm.prank(client);
        escrow.createJob(id, keccak256("ind-spec"), keccak256("ind-policy"), BUDGET, dl, WINDOW);
    }

    function _activate(bytes32 id) internal {
        vm.prank(coordinator);
        escrow.markActive(id);
    }

    /// Passing verdict: workerA 3 USDC, workerB 3.5 USDC, client refund 1 USDC. Total = BUDGET.
    function _passVerdict(bytes32 id) internal view returns (GPUChainEscrow.Verdict memory v) {
        address[] memory payees = new address[](2);
        payees[0] = workerA;
        payees[1] = workerB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3_000_000;
        amounts[1] = 3_500_000;
        v = GPUChainEscrow.Verdict({
            jobId: id,
            passed: true,
            finalCheckpoint: keccak256("ind-final"),
            lineageRoot: keccak256("ind-lineage"),
            qualityReport: keccak256("ind-report"),
            payees: payees,
            amounts: amounts,
            refund: 1_000_000,
            expiry: uint64(block.timestamp + 6 hours)
        });
    }

    function _sign(GPUChainEscrow.Verdict memory v, uint256 key) internal view returns (bytes memory) {
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(key, escrow.hashVerdict(v));
        return abi.encodePacked(sigR, sigS, sigV);
    }

    function _attest(bytes32 id) internal {
        GPUChainEscrow.Verdict memory v = _passVerdict(id);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, vKeys[0]);
        sigs[1] = _sign(v, vKeys[1]);
        escrow.submitAttestation(v, sigs);
    }

    function _dispute(bytes32 id) internal {
        vm.prank(client);
        escrow.dispute(id);
    }

    /// Drives one job all the way to an open dispute under the CURRENT global arbiter.
    function _disputed(bytes32 id, uint64 dl) internal {
        _fund(id, dl);
        _activate(id);
        _attest(id);
        _dispute(id);
    }

    /// The verdict's own split, reused by an arbiter who upholds the numbers but rules on the bond.
    function _verdictSplit() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = 3_000_000;
        amounts[1] = 3_500_000;
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalWithdrawable());
    }
}

// --------------------------------------------------------------------- F2 --

contract F2SnapshotArbiterIndependentTest is IndependentBase {
    bytes32 internal constant JOB_A = keccak256("ind-job-a");
    bytes32 internal constant JOB_B = keccak256("ind-job-b");

    /// Two disputes alive at once, each pinned to a different arbiter.
    /// Neither arbiter can touch the other's job; each bond follows its own snapshot.
    function test_F2_twoLiveDisputes_twoDifferentSnapshotArbiters() public {
        _disputed(JOB_A, T0 + 2 days); // snapshot: arbiterOne

        vm.prank(owner);
        escrow.setArbiter(arbiterTwo);
        _disputed(JOB_B, T0 + 2 days); // snapshot: arbiterTwo

        assertEq(escrow.getJob(JOB_A).arbiter, arbiterOne);
        assertEq(escrow.getJob(JOB_B).arbiter, arbiterTwo);
        assertEq(escrow.arbiter(), arbiterTwo);

        // Cross-resolution must fail both ways.
        vm.prank(arbiterTwo);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, false);

        vm.prank(arbiterOne);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB_B, _verdictSplit(), 1_000_000, true);

        // Each snapshot arbiter resolves its own job.
        // JOB_A: client NOT upheld -> bond forfeits to arbiterOne (the snapshot), not arbiterTwo.
        vm.prank(arbiterOne);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, false);
        assertEq(escrow.withdrawable(arbiterOne), BOND);
        assertEq(escrow.withdrawable(arbiterTwo), 0);

        // JOB_B: client upheld -> bond returns to the client, nobody else.
        // (The client also receives JOB_B's own verdict refund of 1_000_000 here.)
        uint256 clientBefore = escrow.withdrawable(client);
        vm.prank(arbiterTwo);
        escrow.resolveDispute(JOB_B, _verdictSplit(), 1_000_000, true);
        assertEq(escrow.withdrawable(client), clientBefore + 1_000_000 + BOND);
        assertEq(escrow.withdrawable(arbiterTwo), 0);
        _solvent();
    }

    /// Swap lands AFTER attestation but BEFORE the client opens the dispute.
    /// The funding-time arbiter must still own the dispute: the snapshot is taken
    /// in createJob, not in dispute().
    function test_F2_swapBetweenAttestationAndDispute_snapshotStillWins() public {
        _fund(JOB_A, T0 + 2 days);
        _activate(JOB_A);
        _attest(JOB_A);

        vm.prank(owner);
        escrow.setArbiter(arbiterTwo);

        _dispute(JOB_A);
        assertEq(escrow.getJob(JOB_A).arbiter, arbiterOne);

        vm.prank(arbiterTwo);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, false);

        vm.prank(arbiterOne);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, false);
        assertEq(escrow.withdrawable(arbiterOne), BOND);
        _solvent();
    }

    /// A1 -> A2 -> A3 before anyone resolves: only A1 (funding time) may resolve,
    /// even though the contract's current arbiter is now A3.
    function test_F2_multipleSwaps_onlyFundingTimeArbiterResolves() public {
        _disputed(JOB_A, T0 + 2 days);

        vm.prank(owner);
        escrow.setArbiter(arbiterTwo);
        vm.prank(owner);
        escrow.setArbiter(arbiterThree);
        assertEq(escrow.arbiter(), arbiterThree);
        assertEq(escrow.getJob(JOB_A).arbiter, arbiterOne);

        vm.prank(arbiterTwo);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, true);

        vm.prank(arbiterThree);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, true);

        vm.prank(arbiterOne);
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, true);
        _solvent();
    }

    /// After a swap, if the (snapshot) arbiter stays silent for 3 days the timeout
    /// path settles on the original verdict and returns the bond to the client.
    /// The new global arbiter gets nothing and cannot reopen anything afterwards.
    function test_F2_timeoutAfterSwap_bondToClient_newArbiterLockedOut() public {
        _disputed(JOB_A, T0 + 4 days);

        vm.prank(owner);
        escrow.setArbiter(arbiterTwo);

        uint256 clientBefore = escrow.withdrawable(client);
        vm.warp(block.timestamp + 3 days);
        escrow.finalizeAfterArbiterTimeout(JOB_A); // anyone may call

        // Verdict's refund (1 USDC) + the returned bond (1 USDC).
        assertEq(escrow.withdrawable(client), clientBefore + 1_000_000 + BOND);
        assertEq(escrow.withdrawable(arbiterTwo), 0);
        assertEq(escrow.withdrawable(arbiterOne), 0);
        assertEq(uint8(escrow.getJob(JOB_A).state), uint8(GPUChainEscrow.State.Settled));

        vm.prank(arbiterTwo);
        vm.expectRevert(); // job no longer Disputed; nothing left to resolve
        escrow.resolveDispute(JOB_A, _verdictSplit(), 1_000_000, false);
        _solvent();
    }

    /// Admin boundary cases around setArbiter itself.
    function test_F2_setArbiterBoundaries() public {
        vm.prank(owner);
        vm.expectRevert(GPUChainEscrow.ZeroAddress.selector);
        escrow.setArbiter(address(0));

        vm.prank(outsider);
        vm.expectRevert(); // Ownable: not the owner
        escrow.setArbiter(arbiterTwo);

        assertEq(escrow.arbiter(), arbiterOne); // unchanged by either failed call
    }
}

// --------------------------------------------------------------------- F5 --

contract F5DeadlineBoundaryIndependentTest is IndependentBase {
    bytes32 internal constant JOB_X = keccak256("ind-job-x");

    /// The exact second matters: deadline - 1 activates, deadline reverts, deadline + 1 reverts.
    function test_F5_markActive_exactDeadlineBoundaries() public {
        uint64 dl = T0 + 100;
        _fund(JOB_X, dl);

        vm.warp(dl); // exactly at the deadline: too late
        vm.prank(coordinator);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.markActive(JOB_X);

        vm.warp(dl + 1);
        vm.prank(coordinator);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.markActive(JOB_X);

        vm.warp(dl - 1); // one second before: still allowed
        vm.prank(coordinator);
        escrow.markActive(JOB_X);
        assertEq(uint8(escrow.getJob(JOB_X).state), uint8(GPUChainEscrow.State.Active));
    }

    /// createJob has its own boundary: a deadline of "right now" is already dead.
    function test_F5_createJob_deadlineNowOrPastReverts_deadlinePlusOneWorks() public {
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.createJob(JOB_X, keccak256("s"), keccak256("p"), BUDGET, uint64(block.timestamp), WINDOW);

        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.createJob(JOB_X, keccak256("s"), keccak256("p"), BUDGET, uint64(block.timestamp) - 1, WINDOW);

        _fund(JOB_X, uint64(block.timestamp) + 1);
        _activate(JOB_X); // now < deadline, so activation still fits
        assertEq(uint8(escrow.getJob(JOB_X).state), uint8(GPUChainEscrow.State.Active));
    }

    /// Check ordering: who calls and what state the job is in are judged before/regardless
    /// of the deadline, so an attacker learns nothing extra from the deadline error.
    function test_F5_markActive_checkOrdering() public {
        uint64 dl = T0 + 100;
        _fund(JOB_X, dl);

        // A stranger gets NotCoordinator even inside the valid window.
        vm.prank(outsider);
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.markActive(JOB_X);

        // A job that does not exist reports WrongState(None), not BadDeadline.
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.None));
        escrow.markActive(keccak256("ind-no-such-job"));

        // Once Active, a second activation is WrongState even after the deadline passes.
        _activate(JOB_X);
        vm.warp(dl + 10);
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Active));
        escrow.markActive(JOB_X);
    }

    /// The F5 fix must not trap funds: a job nobody activated can still be refunded
    /// through the permissionless path, at its own exact boundary (deadline + 1 hour).
    function test_F5_unactivatedJob_timeoutRefundExactBoundary() public {
        uint64 dl = T0 + 100;
        _fund(JOB_X, dl);

        vm.warp(dl + 1 hours - 1); // one second before the grace period ends
        vm.expectRevert(GPUChainEscrow.TooEarly.selector);
        escrow.claimTimeoutRefund(JOB_X);

        vm.warp(dl + 1 hours); // exactly at the boundary: refund opens
        escrow.claimTimeoutRefund(JOB_X);
        assertEq(uint8(escrow.getJob(JOB_X).state), uint8(GPUChainEscrow.State.Refunded));
        assertEq(escrow.withdrawable(client), BUDGET);

        // And activation stays impossible afterwards.
        vm.prank(coordinator);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Refunded));
        escrow.markActive(JOB_X);
        _solvent();
    }
}
