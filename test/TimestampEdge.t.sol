// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Edge-case evidence for the timestamp-window review (Piyush, 2026-11-07).
/// @dev These tests DOCUMENT current behaviour; they do not propose or apply any fix.
///      They check whether the contract itself enforces any minimum dispute window,
///      minimum deadline lead, or minimum verdict-expiry lead. (It enforces none of
///      the three beyond non-zero / not-in-the-past.)
contract TimestampEdgeTest is Test {
    GPUChainEscrow internal escrow;
    MockUSDC internal usdc;

    address internal owner = makeAddr("edge-owner");
    address internal coordinator = makeAddr("edge-coordinator");
    address internal arbiter = makeAddr("edge-arbiter");
    address internal client = makeAddr("edge-client");
    address internal worker = makeAddr("edge-worker");

    uint256[3] internal vKeys;
    uint256 internal constant BUDGET = 4_000_000;
    uint256 internal constant BOND = 1_000_000;
    uint64 internal constant T0 = 1_700_000_000;

    bytes32 internal constant JOB = keccak256("edge-job");

    function setUp() public {
        vm.warp(T0);
        uint256[3] memory keys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)];
        address[3] memory addrs = [vm.addr(keys[0]), vm.addr(keys[1]), vm.addr(keys[2])];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (addrs[j] < addrs[i]) {
                    (addrs[j], addrs[i]) = (addrs[i], addrs[j]);
                    (keys[j], keys[i]) = (keys[i], keys[j]);
                }
            }
        }
        vKeys = keys;

        usdc = new MockUSDC();
        address[] memory verifiers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            verifiers[i] = addrs[i];
        }
        escrow = new GPUChainEscrow(IERC20(address(usdc)), owner, coordinator, arbiter, verifiers, 2, BOND);
        usdc.mint(client, 100_000_000);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _createWith(uint64 dl, uint64 window) internal {
        vm.prank(client);
        escrow.createJob(JOB, keccak256("s"), keccak256("p"), BUDGET, dl, window);
    }

    function _verdict(uint64 expiry) internal view returns (GPUChainEscrow.Verdict memory v) {
        address[] memory payees = new address[](1);
        payees[0] = worker;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BUDGET;
        v = GPUChainEscrow.Verdict({
            jobId: JOB,
            passed: true,
            finalCheckpoint: keccak256("f"),
            lineageRoot: keccak256("l"),
            qualityReport: keccak256("q"),
            payees: payees,
            amounts: amounts,
            refund: 0,
            expiry: expiry
        });
    }

    function _sign(GPUChainEscrow.Verdict memory v, uint256 key) internal view returns (bytes memory) {
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(key, escrow.hashVerdict(v));
        return abi.encodePacked(sigR, sigS, sigV);
    }

    function _attest(uint64 expiry) internal {
        GPUChainEscrow.Verdict memory v = _verdict(expiry);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, vKeys[0]);
        sigs[1] = _sign(v, vKeys[1]);
        escrow.submitAttestation(v, sigs);
    }

    // ------------------------------------------------------------ windows --

    /// disputeWindow boundary: 0 reverts, 1 second is ACCEPTED, 7 days ok, 7 days + 1s reverts.
    function test_edge_disputeWindow_minimumIsOneSecond() public {
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.BadDisputeWindow.selector);
        escrow.createJob(JOB, keccak256("s"), keccak256("p"), BUDGET, T0 + 1 days, 0);

        _createWith(T0 + 1 days, 1); // a ONE-SECOND dispute window is valid today
        assertEq(escrow.getJob(JOB).disputeWindow, 1);
    }

    function test_edge_disputeWindow_maxBoundary() public {
        _createWith(T0 + 9 days, 7 days); // exactly MAX_DISPUTE_WINDOW: ok

        bytes32 job2 = keccak256("edge-job-2");
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.BadDisputeWindow.selector);
        escrow.createJob(job2, keccak256("s"), keccak256("p"), BUDGET, T0 + 9 days, 7 days + 1);
    }

    /// With a 1-second window, the dispute is only possible inside that single second:
    /// one second of inclusion delay and the opportunity is gone, verdict stands.
    function test_edge_oneSecondWindow_practicalDisputeLoss() public {
        _createWith(T0 + 1 days, 1);
        vm.prank(coordinator);
        escrow.markActive(JOB);
        _attest(uint64(block.timestamp + 1 hours)); // disputeEnd = now + 1s

        vm.warp(block.timestamp + 2); // a single block later
        vm.prank(client);
        vm.expectRevert(GPUChainEscrow.WindowClosed.selector);
        escrow.dispute(JOB);

        // The verdict now simply finalizes; the client never had a usable chance.
        escrow.finalize(JOB);
        assertEq(escrow.withdrawable(worker), BUDGET);
    }

    // ------------------------------------------------------------ deadline --

    /// A deadline one second in the future is accepted (only past/now is rejected).
    function test_edge_deadline_oneSecondLeadAccepted() public {
        _createWith(T0 + 1, 1 hours);
        assertEq(escrow.getJob(JOB).deadline, T0 + 1);
    }

    // -------------------------------------------------------------- expiry --

    /// Verdict expiry has NO minimum lead: an expiry of "right now" is accepted in the
    /// same block, and one second later the very same verdict is expired.
    function test_edge_verdictExpiry_noMinimumLead() public {
        _createWith(T0 + 1 days, 1 hours);
        vm.prank(coordinator);
        escrow.markActive(JOB);

        GPUChainEscrow.Verdict memory v = _verdict(uint64(block.timestamp)); // expiry == now
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(v, vKeys[0]);
        sigs[1] = _sign(v, vKeys[1]);

        vm.warp(block.timestamp + 1); // 1 second later: same verdict is dead
        vm.expectRevert(GPUChainEscrow.VerdictExpired.selector);
        escrow.submitAttestation(v, sigs);

        vm.warp(T0); // back at the signing second: accepted
        escrow.submitAttestation(v, sigs);
        assertEq(uint8(escrow.getJob(JOB).state), uint8(GPUChainEscrow.State.Attested));
    }
}
