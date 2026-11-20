// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProofAnchor} from "../src/ProofAnchor.sol";

contract ProofAnchorTest is Test {
    ProofAnchor internal anchor;
    address internal owner = address(0xA11CE);
    address internal coordinator = address(0xC00D);
    address internal stranger = address(0xBAD);

    event BatchAnchored(uint256 indexed id, bytes32 indexed root, uint64 count, uint64 time);
    event CoordinatorUpdated(address indexed coordinator);

    function setUp() public {
        anchor = new ProofAnchor(owner, coordinator);
    }

    // ---- constructor
    function test_constructorSetsOwnerAndCoordinator() public view {
        assertEq(anchor.owner(), owner);
        assertEq(anchor.coordinator(), coordinator);
        assertEq(anchor.batchCount(), 0);
    }

    function test_constructorRejectsZeroCoordinator() public {
        vm.expectRevert(ProofAnchor.ZeroAddress.selector);
        new ProofAnchor(owner, address(0));
    }

    // ---- anchor
    function test_coordinatorAnchorsABatchAndAnyoneCanRead() public {
        vm.warp(1_800_000_000);
        vm.expectEmit(true, true, false, true);
        emit BatchAnchored(0, bytes32(uint256(1)), 7, 1_800_000_000);
        vm.prank(coordinator);
        uint256 id = anchor.anchor(bytes32(uint256(1)), 7);
        assertEq(id, 0);
        assertEq(anchor.batchCount(), 1);

        vm.prank(stranger); // reads need no permission
        (bytes32 root, uint64 count, uint64 time) = anchor.getBatch(0);
        assertEq(root, bytes32(uint256(1)));
        assertEq(count, 7);
        assertEq(time, 1_800_000_000);
    }

    function test_idsAreSequentialAndTimesAreRecordedPerBatch() public {
        vm.startPrank(coordinator);
        vm.warp(100);
        assertEq(anchor.anchor(bytes32(uint256(11)), 1), 0);
        vm.warp(200);
        assertEq(anchor.anchor(bytes32(uint256(12)), 2), 1);
        vm.stopPrank();
        (,, uint64 t0) = anchor.getBatch(0);
        (bytes32 r1, uint64 c1, uint64 t1) = anchor.getBatch(1);
        assertEq(t0, 100);
        assertEq(r1, bytes32(uint256(12)));
        assertEq(c1, 2);
        assertEq(t1, 200);
        assertEq(anchor.batchCount(), 2);
    }

    function test_anchorFromAnotherAddressIsRefused() public {
        vm.prank(stranger);
        vm.expectRevert(ProofAnchor.NotCoordinator.selector);
        anchor.anchor(bytes32(uint256(1)), 1);
        assertEq(anchor.batchCount(), 0);
    }

    function test_theOwnerCannotAnchorUnlessItIsTheCoordinator() public {
        vm.prank(owner);
        vm.expectRevert(ProofAnchor.NotCoordinator.selector);
        anchor.anchor(bytes32(uint256(1)), 1);
    }

    function test_anchorRejectsEmptyRootEmptyCountAndDuplicates() public {
        vm.startPrank(coordinator);
        vm.expectRevert(ProofAnchor.EmptyRoot.selector);
        anchor.anchor(bytes32(0), 1);
        vm.expectRevert(ProofAnchor.EmptyBatch.selector);
        anchor.anchor(bytes32(uint256(1)), 0);
        anchor.anchor(bytes32(uint256(1)), 1);
        vm.expectRevert(ProofAnchor.AlreadyAnchored.selector);
        anchor.anchor(bytes32(uint256(1)), 5);
        vm.stopPrank();
        assertEq(anchor.batchCount(), 1);
    }

    function test_largestCountFitsAndBatchesCannotBeChanged() public {
        vm.prank(coordinator);
        anchor.anchor(bytes32(uint256(9)), type(uint64).max);
        (, uint64 count,) = anchor.getBatch(0);
        assertEq(count, type(uint64).max);
    }

    // ---- reads
    function test_getBatchRevertsForAnUnknownId() public {
        vm.expectRevert(ProofAnchor.UnknownBatch.selector);
        anchor.getBatch(0);
        vm.prank(coordinator);
        anchor.anchor(bytes32(uint256(1)), 1);
        vm.expectRevert(ProofAnchor.UnknownBatch.selector);
        anchor.getBatch(1);
    }

    function test_isAnchored() public {
        (bool found, uint256 id) = anchor.isAnchored(bytes32(uint256(5)));
        assertFalse(found);
        assertEq(id, 0);
        vm.startPrank(coordinator);
        anchor.anchor(bytes32(uint256(4)), 1);
        anchor.anchor(bytes32(uint256(5)), 1);
        vm.stopPrank();
        (found, id) = anchor.isAnchored(bytes32(uint256(5)));
        assertTrue(found);
        assertEq(id, 1);
        (found, id) = anchor.isAnchored(bytes32(uint256(4)));
        assertTrue(found);
        assertEq(id, 0);
        (found,) = anchor.isAnchored(bytes32(uint256(6)));
        assertFalse(found);
    }

    // ---- setCoordinator
    function test_ownerRotatesTheCoordinator() public {
        address next = address(0xC0DE);
        vm.expectEmit(true, false, false, true);
        emit CoordinatorUpdated(next);
        vm.prank(owner);
        anchor.setCoordinator(next);
        assertEq(anchor.coordinator(), next);

        vm.prank(coordinator); // the old one is now refused
        vm.expectRevert(ProofAnchor.NotCoordinator.selector);
        anchor.anchor(bytes32(uint256(1)), 1);
        vm.prank(next);
        anchor.anchor(bytes32(uint256(1)), 1);
    }

    function test_setCoordinatorRefusesOthersAndZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        anchor.setCoordinator(address(1));
        vm.prank(coordinator); // the coordinator is not the owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, coordinator));
        anchor.setCoordinator(address(1));
        vm.prank(owner);
        vm.expectRevert(ProofAnchor.ZeroAddress.selector);
        anchor.setCoordinator(address(0));
        assertEq(anchor.coordinator(), coordinator);
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(ProofAnchor.RenounceDisabled.selector);
        anchor.renounceOwnership();
        assertEq(anchor.owner(), owner);
    }

    // ---- it never holds money
    function test_plainEtherTransfersAreRefused() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(anchor).call{value: 1 wei}("");
        assertFalse(ok);
        (ok,) = address(anchor).call{value: 1 wei}(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        assertEq(address(anchor).balance, 0);
    }

    function test_noFunctionAcceptsEther() public {
        vm.deal(coordinator, 1 ether);
        vm.startPrank(coordinator);
        (bool ok,) =
            address(anchor).call{value: 1 wei}(abi.encodeCall(ProofAnchor.anchor, (bytes32(uint256(1)), uint64(1))));
        assertFalse(ok);
        vm.stopPrank();
        vm.prank(owner);
        (ok,) = address(anchor).call{value: 1 wei}(abi.encodeCall(ProofAnchor.setCoordinator, (address(3))));
        assertFalse(ok);
        assertEq(address(anchor).balance, 0);
    }

    // ---- fuzz
    function testFuzz_onlyTheCoordinatorCanWriteAndWhatIsWrittenIsRead(address caller, bytes32 root, uint64 count)
        public
    {
        vm.assume(root != bytes32(0) && count != 0);
        vm.prank(caller);
        if (caller != coordinator) {
            vm.expectRevert(ProofAnchor.NotCoordinator.selector);
            anchor.anchor(root, count);
            return;
        }
        uint256 id = anchor.anchor(root, count);
        (bytes32 r, uint64 c,) = anchor.getBatch(id);
        assertEq(r, root);
        assertEq(c, count);
        (bool found, uint256 at) = anchor.isAnchored(root);
        assertTrue(found);
        assertEq(at, id);
    }
}
