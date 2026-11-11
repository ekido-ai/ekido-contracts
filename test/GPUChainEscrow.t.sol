// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract EscrowTestBase is Test {
    GPUChainEscrow internal escrow;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal coordinator = makeAddr("coordinator");
    address internal arbiter = makeAddr("arbiter");
    address internal client = makeAddr("client");
    address internal providerA = makeAddr("providerA");
    address internal providerB = makeAddr("providerB");
    address internal stranger = makeAddr("stranger");

    uint256[3] internal verifierKeys;
    address[3] internal verifierAddrs;

    bytes32 internal constant JOB = keccak256("job-1");
    uint256 internal constant BUDGET = 5_000_000;
    uint256 internal constant BOND = 1_000_000;
    uint64 internal constant WINDOW = 1 hours;
    uint64 internal deadline;

    function setUp() public virtual {
        // Sorted by address, because attestations must list signers in ascending order.
        uint256[3] memory keys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)];
        address[3] memory addrs = [vm.addr(keys[0]), vm.addr(keys[1]), vm.addr(keys[2])];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        verifierKeys = keys;
        verifierAddrs = addrs;

        usdc = new MockUSDC();
        address[] memory verifiers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            verifiers[i] = addrs[i];
        }
        escrow = new GPUChainEscrow(IERC20(address(usdc)), owner, coordinator, arbiter, verifiers, 2, BOND);

        deadline = uint64(block.timestamp + 1 days);
        usdc.mint(client, 100_000_000);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _create(bytes32 id) internal {
        vm.prank(client);
        escrow.createJob(id, keccak256("spec"), keccak256("policy"), BUDGET, deadline, WINDOW);
    }

    function _active(bytes32 id) internal {
        _create(id);
        vm.prank(coordinator);
        escrow.markActive(id);
    }

    /// Provider A earned 2 USDC and B earned 2.5 USDC. The client gets 0.5 USDC back.
    function _verdict(bytes32 id) internal view returns (GPUChainEscrow.Verdict memory v) {
        address[] memory payees = new address[](2);
        payees[0] = providerA;
        payees[1] = providerB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2_000_000;
        amounts[1] = 2_500_000;
        v = GPUChainEscrow.Verdict({
            jobId: id,
            passed: true,
            finalCheckpoint: keccak256("final"),
            lineageRoot: keccak256("lineage"),
            qualityReport: keccak256("report"),
            payees: payees,
            amounts: amounts,
            refund: 500_000,
            expiry: uint64(block.timestamp + 1 hours)
        });
    }

    function _failVerdict(bytes32 id) internal view returns (GPUChainEscrow.Verdict memory v) {
        v = _verdict(id);
        v.passed = false;
        v.payees = new address[](0);
        v.amounts = new uint256[](0);
        v.refund = BUDGET;
    }

    function _sign(GPUChainEscrow.Verdict memory v, uint256 key) internal view returns (bytes memory) {
        (uint8 r, bytes32 s, bytes32 t) = vm.sign(key, escrow.hashVerdict(v));
        return abi.encodePacked(s, t, r);
    }

    function _sigs(GPUChainEscrow.Verdict memory v) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(v, verifierKeys[0]);
        sigs[1] = _sign(v, verifierKeys[1]);
    }

    function _attested(bytes32 id) internal {
        _active(id);
        GPUChainEscrow.Verdict memory v = _verdict(id);
        escrow.submitAttestation(v, _sigs(v));
    }

    function _assertSolvent() internal view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalWithdrawable());
    }
}

contract CreateAndCancelTest is EscrowTestBase {
    function test_createLocksBudget() public {
        _create(JOB);
        assertEq(usdc.balanceOf(address(escrow)), BUDGET);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Funded));
        assertEq(escrow.totalLocked(), BUDGET);
    }

    function test_rejectsDuplicateJob() public {
        _create(JOB);
        vm.expectRevert(GPUChainEscrow.JobExists.selector);
        _create(JOB);
    }

    function test_rejectsBadInputs() public {
        vm.startPrank(client);
        vm.expectRevert(GPUChainEscrow.ZeroBudget.selector);
        escrow.createJob(JOB, 0, 0, 0, deadline, WINDOW);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.createJob(JOB, 0, 0, BUDGET, uint64(block.timestamp), WINDOW);
        vm.expectRevert(GPUChainEscrow.BadDisputeWindow.selector);
        escrow.createJob(JOB, 0, 0, BUDGET, deadline, 0);
        vm.expectRevert(GPUChainEscrow.BadDisputeWindow.selector);
        escrow.createJob(JOB, 0, 0, BUDGET, deadline, 8 days);
        vm.stopPrank();
    }

    function test_clientCanCancelBeforeStart() public {
        _create(JOB);
        vm.prank(client);
        escrow.cancel(JOB);
        assertEq(escrow.withdrawable(client), BUDGET);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }

    function test_onlyClientCancels() public {
        _create(JOB);
        vm.prank(stranger);
        vm.expectRevert(GPUChainEscrow.NotClient.selector);
        escrow.cancel(JOB);
    }

    function test_cannotCancelAfterStart() public {
        _active(JOB);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Active));
        escrow.cancel(JOB);
    }
}

contract CoordinatorLimitsTest is EscrowTestBase {
    function test_onlyCoordinatorMarksActive() public {
        _create(JOB);
        vm.prank(stranger);
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.markActive(JOB);
    }

    function test_onlyCoordinatorAnchors() public {
        _active(JOB);
        vm.prank(stranger);
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.anchorEvent(JOB, 1, 1, keccak256("x"));
    }

    function test_anchorChangesNothing() public {
        _active(JOB);
        uint256 locked = escrow.totalLocked();
        vm.expectEmit(true, true, false, true);
        emit GPUChainEscrow.JobAnchor(JOB, 1, 2, keccak256("x"));
        vm.prank(coordinator);
        escrow.anchorEvent(JOB, 1, 2, keccak256("x"));
        assertEq(escrow.totalLocked(), locked);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Active));
    }

    function test_coordinatorAloneCannotSettle() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        vm.prank(coordinator);
        vm.expectRevert(GPUChainEscrow.NotEnoughSignatures.selector);
        escrow.submitAttestation(v, new bytes[](0));
    }

    function test_coordinatorKeyIsNotAVerifier() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        // A key outside the set is rejected even when the count is right.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, verifierKeys[0]);
        sigs[1] = _sign(v, 0xDEAD);
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }
}

contract AttestationTest is EscrowTestBase {
    function test_quorumMovesToAttested() public {
        _attested(JOB);
        GPUChainEscrow.Job memory job = escrow.getJob(JOB);
        assertEq(uint8(job.state), uint8(GPUChainEscrow.State.Attested));
        assertEq(job.disputeEnd, block.timestamp + WINDOW);
        assertEq(escrow.withdrawable(providerA), 0, "no money moves until the window closes");
    }

    function test_rejectsBelowQuorum() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(v, verifierKeys[0]);
        vm.expectRevert(GPUChainEscrow.NotEnoughSignatures.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsDuplicateSigner() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, verifierKeys[0]);
        sigs[1] = _sign(v, verifierKeys[0]);
        vm.expectRevert(GPUChainEscrow.SignersNotAscending.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsDescendingSigners() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, verifierKeys[1]);
        sigs[1] = _sign(v, verifierKeys[0]);
        vm.expectRevert(GPUChainEscrow.SignersNotAscending.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsNonVerifierSigner() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        uint256 outsider = 0xBAD;
        address outsiderAddr = vm.addr(outsider);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(v, outsider);
        // Quorum check passes only with 2, so pad with a real signer in the right order.
        bytes[] memory two = new bytes[](2);
        if (outsiderAddr < verifierAddrs[2]) {
            two[0] = sigs[0];
            two[1] = _sign(v, verifierKeys[2]);
        } else {
            two[0] = _sign(v, verifierKeys[2]);
            two[1] = sigs[0];
        }
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.UnknownVerifier.selector, outsiderAddr));
        escrow.submitAttestation(v, two);
    }

    function test_rejectsTamperedPayouts() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        // Same total, so only the signature check can catch the swap.
        v.amounts[0] = 2_500_000;
        v.amounts[1] = 2_000_000;
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsAmountsNotMatchingBudget() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.refund = v.refund + 1;
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.AmountsDoNotMatchBudget.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsExpiredVerdict() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.warp(v.expiry + 1);
        vm.expectRevert(GPUChainEscrow.VerdictExpired.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsTooManyPayees() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.payees = new address[](9);
        v.amounts = new uint256[](9);
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.TooManyPayees.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsZeroPayee() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.payees[0] = address(0);
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.ZeroPayee.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsFailedVerdictThatPaysSomeone() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.passed = false;
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.FailedVerdictHasPayees.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_rejectsBeforeActive() public {
        _create(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Funded));
        escrow.submitAttestation(v, sigs);
    }

    function test_cannotReplayOnSameJob() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        escrow.submitAttestation(v, sigs);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Attested));
        escrow.submitAttestation(v, sigs);
    }

    function test_cannotReplayOnAnotherJob() public {
        bytes32 other = keccak256("job-2");
        _active(JOB);
        _active(other);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        v.jobId = other;
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_cannotReplayOnAnotherChain() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_cannotReplayOnAnotherContract() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);

        address[] memory verifiers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            verifiers[i] = verifierAddrs[i];
        }
        GPUChainEscrow second = new GPUChainEscrow(IERC20(address(usdc)), owner, coordinator, arbiter, verifiers, 2, BOND);
        vm.prank(client);
        usdc.approve(address(second), type(uint256).max);
        vm.prank(client);
        second.createJob(JOB, 0, 0, BUDGET, deadline, WINDOW);
        vm.prank(coordinator);
        second.markActive(JOB);

        vm.expectRevert();
        second.submitAttestation(v, sigs);
    }

    function test_rejectsMalleableSignature() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes32 digest = escrow.hashVerdict(v);
        (uint8 r, bytes32 s, bytes32 t) = vm.sign(verifierKeys[0], digest);
        // The other valid point on the curve for the same message, which OpenZeppelin must reject.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(s, bytes32(n - uint256(t)), r == 27 ? uint8(28) : uint8(27));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = flipped;
        sigs[1] = _sign(v, verifierKeys[1]);
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_verifierSetSnapshotSurvivesRotation() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);

        address[] memory replacement = new address[](1);
        replacement[0] = makeAddr("newVerifier");
        vm.prank(owner);
        escrow.setVerifiers(replacement, 1);

        escrow.submitAttestation(v, sigs);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Attested));
    }

    function test_newJobsUseRotatedSet() public {
        address[] memory replacement = new address[](1);
        uint256 key = 0x1234;
        replacement[0] = vm.addr(key);
        vm.prank(owner);
        escrow.setVerifiers(replacement, 1);

        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(v, key);
        escrow.submitAttestation(v, sigs);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Attested));
    }

    function test_onlyOwnerRotatesVerifiers() public {
        address[] memory replacement = new address[](1);
        replacement[0] = stranger;
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setVerifiers(replacement, 1);
    }

    function test_rejectsBadVerifierSets() public {
        address[] memory two = new address[](2);
        two[0] = stranger;
        two[1] = stranger;
        vm.startPrank(owner);
        vm.expectRevert(GPUChainEscrow.BadVerifierSet.selector);
        escrow.setVerifiers(two, 2); // Duplicate would make a 2-of-2 really 1 person.
        vm.expectRevert(GPUChainEscrow.BadVerifierSet.selector);
        escrow.setVerifiers(new address[](0), 0);
        two[1] = coordinator;
        vm.expectRevert(GPUChainEscrow.BadVerifierSet.selector);
        escrow.setVerifiers(two, 3);
        vm.expectRevert(GPUChainEscrow.BadVerifierSet.selector);
        escrow.setVerifiers(two, 0);
        vm.stopPrank();
    }
}

contract SettlementTest is EscrowTestBase {
    function test_settlesSplitAfterWindow() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);

        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Settled));
        assertEq(escrow.withdrawable(providerA), 2_000_000);
        assertEq(escrow.withdrawable(providerB), 2_500_000);
        assertEq(escrow.withdrawable(client), 500_000);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }

    function test_cannotFinalizeEarly() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(GPUChainEscrow.WindowStillOpen.selector);
        escrow.finalize(JOB);
    }

    function test_cannotFinalizeTwice() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Settled));
        escrow.finalize(JOB);
        assertEq(escrow.withdrawable(providerA), 2_000_000);
    }

    function test_withdrawPaysExactlyOnce() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);

        vm.prank(providerA);
        escrow.withdraw();
        assertEq(usdc.balanceOf(providerA), 2_000_000);
        vm.prank(providerA);
        vm.expectRevert(GPUChainEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        _assertSolvent();
    }

    function test_failedVerdictRefundsClientInFull() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _failVerdict(JOB);
        escrow.submitAttestation(v, _sigs(v));
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Refunded));
        assertEq(escrow.withdrawable(client), BUDGET);
        _assertSolvent();
    }

    function test_timeoutRefundWorksWithoutCoordinator() public {
        _active(JOB);
        vm.warp(deadline + escrow.REFUND_GRACE());
        vm.prank(stranger);
        escrow.claimTimeoutRefund(JOB);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Refunded));
        assertEq(escrow.withdrawable(client), BUDGET);
        assertEq(escrow.withdrawable(stranger), 0);
        _assertSolvent();
    }

    function test_noTimeoutRefundEarly() public {
        _active(JOB);
        vm.warp(deadline);
        vm.expectRevert(GPUChainEscrow.TooEarly.selector);
        escrow.claimTimeoutRefund(JOB);
    }

    function test_noTimeoutRefundAfterAttestation() public {
        _attested(JOB);
        vm.warp(deadline + escrow.REFUND_GRACE());
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Attested));
        escrow.claimTimeoutRefund(JOB);
    }
}

contract DisputeTest is EscrowTestBase {
    function _disputed() internal {
        _attested(JOB);
        vm.prank(client);
        escrow.dispute(JOB);
    }

    function test_disputeTakesBondAndBlocksFinalize() public {
        _disputed();
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Disputed));
        assertEq(usdc.balanceOf(address(escrow)), BUDGET + BOND);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Disputed));
        escrow.finalize(JOB);
        _assertSolvent();
    }

    function test_onlyClientDisputes() public {
        _attested(JOB);
        vm.prank(stranger);
        vm.expectRevert(GPUChainEscrow.NotClient.selector);
        escrow.dispute(JOB);
    }

    function test_noDisputeAfterWindow() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.WindowClosed.selector);
        escrow.dispute(JOB);
    }

    function test_cannotDisputeFailedVerdict() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _failVerdict(JOB);
        escrow.submitAttestation(v, _sigs(v));
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.NothingToDispute.selector);
        escrow.dispute(JOB);
    }

    function test_upheldDisputeRefundsAndReturnsBond() public {
        _disputed();
        uint256[] memory amounts = new uint256[](2);
        vm.prank(arbiter);
        escrow.resolveDispute(JOB, amounts, BUDGET, true);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Refunded));
        assertEq(escrow.withdrawable(client), BUDGET + BOND);
        assertEq(escrow.withdrawable(providerA), 0);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }

    function test_rejectedDisputeForfeitsBond() public {
        _disputed();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2_000_000;
        amounts[1] = 2_500_000;
        vm.prank(arbiter);
        escrow.resolveDispute(JOB, amounts, 500_000, false);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Settled));
        assertEq(escrow.withdrawable(client), 500_000);
        assertEq(escrow.withdrawable(arbiter), BOND);
        assertEq(escrow.withdrawable(providerB), 2_500_000);
        _assertSolvent();
    }

    function test_onlyArbiterResolves() public {
        _disputed();
        vm.prank(coordinator);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB, new uint256[](2), BUDGET, true);
    }

    function test_arbiterCannotCreateMoney() public {
        _disputed();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = BUDGET;
        vm.prank(arbiter);
        vm.expectRevert(GPUChainEscrow.AmountsDoNotMatchBudget.selector);
        escrow.resolveDispute(JOB, amounts, BUDGET, true);
    }

    function test_silentArbiterLetsVerdictStand() public {
        _disputed();
        vm.warp(block.timestamp + escrow.ARBITER_TIMEOUT() - 1);
        vm.expectRevert(GPUChainEscrow.TooEarly.selector);
        escrow.finalizeAfterArbiterTimeout(JOB);

        vm.warp(block.timestamp + 1);
        escrow.finalizeAfterArbiterTimeout(JOB);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Settled));
        assertEq(escrow.withdrawable(providerA), 2_000_000);
        assertEq(escrow.withdrawable(client), 500_000 + BOND);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }
}

/// A token that tries to re-enter withdraw during transfer.
contract ReentrantToken is ERC20 {
    GPUChainEscrow public target;
    bool public attacked;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant", "RE") {}

    function setTarget(GPUChainEscrow target_) external {
        target = target_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) != address(0) && from == address(target) && !attacked) {
            attacked = true;
            (reentrySucceeded,) = address(target).call(abi.encodeWithSelector(GPUChainEscrow.withdraw.selector));
        }
    }
}

contract ReentrancyTest is Test {
    function test_withdrawCannotBeReentered() public {
        ReentrantToken token = new ReentrantToken();
        address[] memory verifiers = new address[](1);
        verifiers[0] = makeAddr("v");
        address client = makeAddr("client");
        GPUChainEscrow escrow = new GPUChainEscrow(IERC20(address(token)), address(this), address(this), address(this), verifiers, 1, 0);
        token.setTarget(escrow);
        token.mint(client, 100);

        vm.startPrank(client);
        token.approve(address(escrow), 100);
        escrow.createJob(keccak256("j"), 0, 0, 100, uint64(block.timestamp + 1), 1);
        escrow.cancel(keccak256("j"));
        escrow.withdraw();
        vm.stopPrank();

        assertTrue(token.attacked(), "the attack must actually have run");
        assertFalse(token.reentrySucceeded());
        assertEq(token.balanceOf(client), 100);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}

contract FuzzTest is EscrowTestBase {
    function testFuzz_settlementConservesFunds(uint256 budget, uint256 a, uint256 b) public {
        budget = bound(budget, 1, 90_000_000);
        a = bound(a, 0, budget);
        b = bound(b, 0, budget - a);
        uint256 refund = budget - a - b;

        vm.prank(client);
        escrow.createJob(JOB, 0, 0, budget, deadline, WINDOW);
        vm.prank(coordinator);
        escrow.markActive(JOB);

        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.amounts[0] = a;
        v.amounts[1] = b;
        v.refund = refund;
        escrow.submitAttestation(v, _sigs(v));
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);

        assertEq(escrow.withdrawable(providerA) + escrow.withdrawable(providerB) + escrow.withdrawable(client), budget);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }

    function testFuzz_wrongTotalAlwaysRejected(uint256 budget, uint256 a, uint256 b, uint256 refund) public {
        budget = bound(budget, 1, 90_000_000);
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        refund = bound(refund, 0, 1e30);
        vm.assume(a + b + refund != budget);

        vm.prank(client);
        escrow.createJob(JOB, 0, 0, budget, deadline, WINDOW);
        vm.prank(coordinator);
        escrow.markActive(JOB);

        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.amounts[0] = a;
        v.amounts[1] = b;
        v.refund = refund;
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.AmountsDoNotMatchBudget.selector);
        escrow.submitAttestation(v, sigs);
    }
}

/// Drives the escrow through random valid and invalid actions for the invariant test.
contract Handler is Test {
    GPUChainEscrow internal escrow;
    MockUSDC internal usdc;
    address internal client;
    address internal coordinator;
    address internal arbiter;
    uint256[] internal keys;
    bytes32[] public jobs;
    address internal constant PAYEE_A = address(0xA);
    address internal constant PAYEE_B = address(0xB);
    uint256 internal constant MAX_JOBS = 3;

    // Counts of calls that succeeded, so the test can prove these paths were really exercised.
    uint256 public disputesResolved;
    uint256 public arbiterTimeouts;
    uint256 public settled;
    uint256 public withdrawals;

    constructor(GPUChainEscrow e, MockUSDC u, address c, address coord, address arb, uint256[3] memory sortedKeys) {
        escrow = e;
        usdc = u;
        client = c;
        coordinator = coord;
        arbiter = arb;
        keys.push(sortedKeys[0]);
        keys.push(sortedKeys[1]);
    }

    function _pick(uint256 seed) internal view returns (bytes32) {
        if (jobs.length == 0) return bytes32(0);
        return jobs[seed % jobs.length];
    }

    function create(uint256 budget) external {
        // Few jobs per run, so random calls actually reach late states like Disputed.
        if (jobs.length >= MAX_JOBS) return;
        budget = bound(budget, 1, 1_000_000);
        bytes32 id = keccak256(abi.encode(jobs.length, block.timestamp));
        vm.prank(client);
        escrow.createJob(id, 0, 0, budget, uint64(block.timestamp + 1 days), 1 hours);
        jobs.push(id);
    }

    function activate(uint256 seed) external {
        vm.prank(coordinator);
        escrow.markActive(_pick(seed));
    }

    function cancel(uint256 seed) external {
        vm.prank(client);
        escrow.cancel(_pick(seed));
    }

    function attest(uint256 seed, uint256 toA) external {
        bytes32 id = _pick(seed);
        uint256 budget = escrow.getJob(id).budget;
        toA = bound(toA, 0, budget);
        address[] memory payees = new address[](2);
        payees[0] = PAYEE_A;
        payees[1] = PAYEE_B;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = toA;
        amounts[1] = budget - toA;
        GPUChainEscrow.Verdict memory v = GPUChainEscrow.Verdict(id, true, 0, 0, 0, payees, amounts, 0, uint64(block.timestamp + 1 hours));
        bytes32 digest = escrow.hashVerdict(v);
        bytes[] memory sigs = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 r, bytes32 s, bytes32 t) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(s, t, r);
        }
        escrow.submitAttestation(v, sigs);
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 0, 4 days));
    }

    function warpShort(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 0, 10 minutes));
    }

    function finalize(uint256 seed) external {
        escrow.finalize(_pick(seed));
        settled++;
    }

    function dispute(uint256 seed) external {
        vm.prank(client);
        escrow.dispute(_pick(seed));
    }

    function resolve(uint256 seed, bool upheld) external {
        bytes32 id = _pick(seed);
        uint256[] memory amounts = new uint256[](2);
        uint256 budget = escrow.getJob(id).budget;
        vm.prank(arbiter);
        escrow.resolveDispute(id, amounts, budget, upheld);
        disputesResolved++;
    }

    function timeoutArbiter(uint256 seed) external {
        escrow.finalizeAfterArbiterTimeout(_pick(seed));
        arbiterTimeouts++;
    }

    function timeoutRefund(uint256 seed) external {
        escrow.claimTimeoutRefund(_pick(seed));
    }

    function withdrawClient() external {
        vm.prank(client);
        escrow.withdraw();
        withdrawals++;
    }

    function withdrawPayee(bool a) external {
        vm.prank(a ? PAYEE_A : PAYEE_B);
        escrow.withdraw();
        withdrawals++;
    }
}

contract InvariantTest is EscrowTestBase {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        usdc.mint(client, 1e18);
        handler = new Handler(escrow, usdc, client, coordinator, arbiter, verifierKeys);
        targetContract(address(handler));
    }

    function invariant_contractIsAlwaysSolvent() public view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked() + escrow.totalWithdrawable());
    }

    function afterInvariant() public view {
        // Printed in verbose runs, so a passing invariant can be checked for real coverage.
        console2.log("settled", handler.settled());
        console2.log("disputesResolved", handler.disputesResolved());
        console2.log("arbiterTimeouts", handler.arbiterTimeouts());
        console2.log("withdrawals", handler.withdrawals());
    }
}
