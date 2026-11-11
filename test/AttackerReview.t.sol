// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {EscrowTestBase} from "./GPUChainEscrow.t.sol";

/// @dev Like real USDC, this token can refuse transfers to a blacklisted address.
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Black", "BLK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// Attacker review by Arvind (5 Nov 2026), against Piyush's GPUChainEscrow.
/// `test_poc_*` PASS when the weakness is REAL. After a fix, invert them into "the attack reverts".
/// `test_holds_*` PASS when a defence works, and must keep passing. F2 and F5 are fixed and inverted.
/// F1, F3, F4 and F6 are waiting on the team's decision, so their `poc` tests still pass.
contract AttackerReviewTest is EscrowTestBase {
    bytes32 internal constant JOB2 = keccak256("job-2");
    address internal evil = makeAddr("evil");

    // ============================================================ weaknesses

    /// F1 (Medium): the client picks `deadline`, and a refund opens at deadline + 1h even if the job is
    /// still running. A verdict that was already signed but not yet submitted then fails, and providers get 0.
    function test_poc_F1_clientRefundsBeforeLateVerdictLands() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.expiry = uint64(deadline + 2 days); // verdict stays valid past the refund point
        bytes[] memory sigs = _sigs(v); // verifiers already signed

        vm.warp(deadline + 1 hours); // earliest moment refund opens
        vm.prank(client);
        escrow.claimTimeoutRefund(JOB); // client wins the race

        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Refunded));
        escrow.submitAttestation(v, sigs); // valid quorum, too late
        assertEq(escrow.withdrawable(client), BUDGET);
        assertEq(escrow.withdrawable(providerA), 0);
        assertEq(escrow.withdrawable(providerB), 0);
    }

    /// F2, fixed: the arbiter is snapshotted when a job is funded, so a swap can't reach an open dispute.
    function test_holds_F2_ownerCannotSwapArbiterMidDispute() public {
        _attested(JOB);
        vm.prank(client);
        escrow.dispute(JOB);

        vm.prank(owner);
        escrow.setArbiter(evil);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = BUDGET; // everything to provider A: B would lose 2.5, the client the 0.5 refund
        amounts[1] = 0;
        vm.prank(evil);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB, amounts, 0, false);

        // The arbiter from funding time still decides, and a forfeited bond goes to them.
        amounts[0] = 2_000_000;
        amounts[1] = 2_500_000;
        vm.prank(arbiter);
        escrow.resolveDispute(JOB, amounts, 500_000, false);
        assertEq(escrow.withdrawable(arbiter), BOND);
        assertEq(escrow.withdrawable(evil), 0);
        _assertSolvent();
    }

    /// F2's other half: a new arbiter does apply to jobs funded after the swap.
    function test_holds_F2_newArbiterAppliesToNewJobs() public {
        _create(JOB);
        vm.prank(owner);
        escrow.setArbiter(evil);
        _create(JOB2);
        assertEq(escrow.getJob(JOB).arbiter, arbiter);
        assertEq(escrow.getJob(JOB2).arbiter, evil);
    }

    /// F3 (Medium, griefing): a dispute costs the client nothing if the arbiter stays silent, because the bond
    /// comes back. Any client can delay every provider payout by ARBITER_TIMEOUT (3 days) for free.
    function test_poc_F3_freeDisputeDelaysProviderPayoutThreeDays() public {
        _attested(JOB);
        vm.prank(client);
        escrow.dispute(JOB);

        vm.warp(block.timestamp + WINDOW + 1); // normal finalize time has passed
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Disputed));
        escrow.finalize(JOB);
        assertEq(escrow.withdrawable(providerA), 0); // providers still unpaid

        vm.warp(block.timestamp + 3 days);
        escrow.finalizeAfterArbiterTimeout(JOB);
        assertEq(escrow.withdrawable(client), 500_000 + BOND); // refund AND the bond back: it cost nothing
        assertEq(escrow.withdrawable(providerA), 2_000_000);
    }

    /// F4 (Medium-Low): job IDs are global and first come, first served. An attacker who sees a pending
    /// createJob can take the same ID for 1 unit and cancel. The client's call reverts and the ID is burned.
    function test_poc_F4_attackerSquatsJobId() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 10);
        vm.startPrank(attacker);
        usdc.approve(address(escrow), type(uint256).max);
        escrow.createJob(JOB, 0, 0, 1, deadline, WINDOW);
        escrow.cancel(JOB);
        vm.stopPrank();

        vm.expectRevert(GPUChainEscrow.JobExists.selector);
        _create(JOB); // the real client can never use this ID again
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Cancelled));
    }

    /// F5, fixed: an expired job can't be activated, and the client can still take the money back.
    function test_holds_F5_cannotActivateAfterDeadline() public {
        _create(JOB);
        vm.warp(deadline);
        vm.prank(coordinator);
        vm.expectRevert(GPUChainEscrow.BadDeadline.selector);
        escrow.markActive(JOB);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Funded));
        vm.prank(client);
        escrow.cancel(JOB);
        assertEq(escrow.withdrawable(client), BUDGET);
    }

    /// F6 (Low): `setCoordinator`, `setArbiter` and `setVerifiers` have one key (the owner) and no delay.
    /// Existing tests never call setArbiter or setCoordinator. This pins down what they do today.
    function test_poc_F6_ownerSwapIsInstantAndUntested() public {
        vm.startPrank(owner);
        escrow.setCoordinator(evil);
        escrow.setArbiter(evil);
        vm.stopPrank();
        assertEq(escrow.coordinator(), evil);
        assertEq(escrow.arbiter(), evil);

        _create(JOB);
        vm.prank(coordinator); // old coordinator is locked out at once
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.markActive(JOB);
    }

    // =========================================================== defences

    /// The coordinator can freeze a Funded job before the client cancels (F2 in my first review), but it
    /// cannot steal, and the client recovers the money without it.
    function test_holds_coordinatorCanDelayButNotStealAndTimeoutRefundWorks() public {
        _create(JOB);
        vm.prank(coordinator);
        escrow.markActive(JOB);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Active));
        escrow.cancel(JOB);

        vm.warp(deadline + 1 hours - 1);
        vm.expectRevert(GPUChainEscrow.TooEarly.selector);
        escrow.claimTimeoutRefund(JOB);

        vm.warp(deadline + 1 hours);
        vm.prank(stranger); // anyone can trigger it
        escrow.claimTimeoutRefund(JOB);
        assertEq(escrow.withdrawable(client), BUDGET);
        assertEq(escrow.withdrawable(coordinator), 0);
        _assertSolvent();
    }

    function test_holds_signaturesCannotBeReplayedOnAnotherJob() public {
        _active(JOB);
        _active(JOB2);
        bytes[] memory sigs = _sigs(_verdict(JOB));
        vm.expectRevert(); // recovered signers are not the verifiers
        escrow.submitAttestation(_verdict(JOB2), sigs);
    }

    function test_holds_signaturesCannotBeReplayedOnAnotherChain() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.chainId(999);
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_signaturesCannotBeReplayedOnAnotherDeployment() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);

        address[] memory vs = new address[](3);
        for (uint256 i; i < 3; ++i) vs[i] = verifierAddrs[i];
        GPUChainEscrow other =
            new GPUChainEscrow(IERC20(address(usdc)), owner, coordinator, arbiter, vs, 2, BOND);
        vm.prank(client);
        usdc.approve(address(other), type(uint256).max);
        vm.prank(client);
        other.createJob(JOB, keccak256("spec"), keccak256("policy"), BUDGET, deadline, WINDOW);
        vm.prank(coordinator);
        other.markActive(JOB);
        vm.expectRevert(); // different verifyingContract in the EIP-712 domain
        other.submitAttestation(v, sigs);
    }

    function test_holds_sameVerdictCannotBeSubmittedTwice() public {
        _attested(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Attested));
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_oneVerifierCannotCountTwice() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, verifierKeys[0]);
        sigs[1] = _sign(v, verifierKeys[0]);
        vm.expectRevert(GPUChainEscrow.SignersNotAscending.selector);
        escrow.submitAttestation(v, sigs);
    }

    /// Same signer twice, second copy with the malleable high-s form. Must still revert.
    function test_holds_highSMalleableCopyIsRejected() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(verifierKeys[0], escrow.hashVerdict(v));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flipped = vv == 27 ? 28 : 27;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = abi.encodePacked(r, s, vv);
        sigs[1] = abi.encodePacked(r, highS, flipped);
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_nonVerifierSignaturesAreRejected() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, 0xBAD1);
        sigs[1] = _sign(v, 0xBAD2);
        vm.expectRevert(); // UnknownVerifier or SignersNotAscending, depending on address order
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_oneSignatureIsNotAQuorum() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(v, verifierKeys[0]);
        vm.expectRevert(GPUChainEscrow.NotEnoughSignatures.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_changingAnyFieldAfterSigningBreaksTheQuorum() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        v.payees[0] = evil; // redirect provider A's pay
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);

        v = _verdict(JOB);
        v.amounts[0] = 2_500_000;
        v.amounts[1] = 2_000_000; // swap amounts, same total
        vm.expectRevert();
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_amountsMustEqualBudgetEvenWithValidSignatures() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        v.refund = 600_000; // 100k too much, verifiers "signed" it
        bytes[] memory sigs = _sigs(v);
        vm.expectRevert(GPUChainEscrow.AmountsDoNotMatchBudget.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_expiredVerdictIsRejected() public {
        _active(JOB);
        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = _sigs(v);
        vm.warp(v.expiry + 1);
        vm.expectRevert(GPUChainEscrow.VerdictExpired.selector);
        escrow.submitAttestation(v, sigs);
    }

    function test_holds_strangerCannotMoveOrDisputeOrResolve() public {
        _attested(JOB);
        vm.startPrank(stranger);
        vm.expectRevert(GPUChainEscrow.NotClient.selector);
        escrow.dispute(JOB);
        vm.expectRevert(GPUChainEscrow.NotArbiter.selector);
        escrow.resolveDispute(JOB, new uint256[](2), BUDGET, true);
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.markActive(JOB);
        vm.expectRevert(GPUChainEscrow.NotCoordinator.selector);
        escrow.anchorEvent(JOB, 1, 1, bytes32(0));
        vm.expectRevert(); // Ownable
        escrow.setArbiter(stranger);
        vm.stopPrank();
    }

    function test_holds_disputeCannotBeOpenedTwiceOrAfterWindow() public {
        _attested(JOB);
        vm.startPrank(client);
        escrow.dispute(JOB);
        vm.expectRevert(abi.encodeWithSelector(GPUChainEscrow.WrongState.selector, GPUChainEscrow.State.Disputed));
        escrow.dispute(JOB);
        vm.stopPrank();

        _attested(JOB2);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.WindowClosed.selector);
        escrow.dispute(JOB2);
    }

    function test_holds_arbiterCannotPayOutsideBudgetOrToNewPayees() public {
        _attested(JOB);
        vm.prank(client);
        escrow.dispute(JOB);

        uint256[] memory tooMuch = new uint256[](2);
        tooMuch[0] = BUDGET;
        tooMuch[1] = 1;
        vm.prank(arbiter);
        vm.expectRevert(GPUChainEscrow.AmountsDoNotMatchBudget.selector);
        escrow.resolveDispute(JOB, tooMuch, 0, true);

        vm.prank(arbiter);
        vm.expectRevert(GPUChainEscrow.LengthMismatch.selector);
        escrow.resolveDispute(JOB, new uint256[](3), BUDGET, true); // cannot add payees
    }

    function test_holds_withdrawTwiceReverts() public {
        _attested(JOB);
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize(JOB);
        vm.startPrank(providerA);
        escrow.withdraw();
        vm.expectRevert(GPUChainEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
        vm.stopPrank();
        _assertSolvent();
    }

    /// Pull payments: a payee the token refuses to pay (like a USDC blacklist) cannot block anyone else.
    function test_holds_blacklistedPayeeDoesNotBlockOthers() public {
        BlacklistToken bt = new BlacklistToken();
        address[] memory vs = new address[](3);
        for (uint256 i; i < 3; ++i) vs[i] = verifierAddrs[i];
        GPUChainEscrow e = new GPUChainEscrow(IERC20(address(bt)), owner, coordinator, arbiter, vs, 2, BOND);
        bt.mint(client, 10 * BUDGET);
        vm.prank(client);
        bt.approve(address(e), type(uint256).max);
        vm.prank(client);
        e.createJob(JOB, keccak256("spec"), keccak256("policy"), BUDGET, deadline, WINDOW);
        vm.prank(coordinator);
        e.markActive(JOB);

        GPUChainEscrow.Verdict memory v = _verdict(JOB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signFor(e, v, verifierKeys[0]);
        sigs[1] = _signFor(e, v, verifierKeys[1]);
        e.submitAttestation(v, sigs);
        vm.warp(block.timestamp + WINDOW);
        e.finalize(JOB);

        bt.setBlocked(providerA, true);
        vm.prank(providerA);
        vm.expectRevert("blacklisted");
        e.withdraw();
        assertEq(e.withdrawable(providerA), 2_000_000); // credit is kept

        vm.prank(providerB);
        e.withdraw();
        vm.prank(client);
        e.withdraw();
        assertEq(bt.balanceOf(providerB), 2_500_000);
    }

    function _signFor(GPUChainEscrow e, GPUChainEscrow.Verdict memory v, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(key, e.hashVerdict(v));
        return abi.encodePacked(r, s, vv);
    }
}
