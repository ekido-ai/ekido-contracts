// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

contract ProviderRegistryTest is Test {
    ProviderRegistry internal registry;
    address internal owner = makeAddr("owner");
    address internal coordinator = makeAddr("coordinator");
    address internal provider = makeAddr("provider");

    function setUp() public {
        registry = new ProviderRegistry(owner, coordinator);
    }

    function test_registerOnce() public {
        vm.startPrank(provider);
        registry.register(keccak256("meta"));
        assertTrue(registry.getProvider(provider).registered);
        vm.expectRevert(ProviderRegistry.AlreadyRegistered.selector);
        registry.register(keccak256("meta2"));
        vm.stopPrank();
    }

    function test_onlyRegisteredUpdatesMetadata() public {
        vm.prank(provider);
        vm.expectRevert(ProviderRegistry.NotRegistered.selector);
        registry.updateMetadata(keccak256("x"));
    }

    function test_onlyCoordinatorAnchorsPassport() public {
        vm.prank(provider);
        registry.register(keccak256("meta"));
        vm.prank(provider);
        vm.expectRevert(ProviderRegistry.NotCoordinator.selector);
        registry.anchorPassport(provider, keccak256("self-issued"));

        vm.prank(coordinator);
        registry.anchorPassport(provider, keccak256("passport"));
        assertEq(registry.getProvider(provider).passportRoot, keccak256("passport"));
    }

    function test_cannotAnchorUnregistered() public {
        vm.prank(coordinator);
        vm.expectRevert(ProviderRegistry.NotRegistered.selector);
        registry.anchorPassport(provider, keccak256("passport"));
    }

    function test_onlyOwnerSetsCoordinator() public {
        vm.prank(provider);
        vm.expectRevert();
        registry.setCoordinator(provider);
    }

    // ------------------------------------------------------------ events and stored values

    event ProviderRegistered(address indexed provider, bytes32 metadataHash);
    event ProviderUpdated(address indexed provider, bytes32 metadataHash);
    event PassportAnchored(address indexed provider, bytes32 passportRoot);
    event CoordinatorUpdated(address coordinator);

    function test_registerStoresTheHashAndEmitsProviderRegistered() public {
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistered(provider, keccak256("meta"));
        vm.prank(provider);
        registry.register(keccak256("meta"));

        ProviderRegistry.Provider memory p = registry.getProvider(provider);
        assertTrue(p.registered);
        assertEq(p.metadataHash, keccak256("meta"));
        assertEq(p.passportRoot, bytes32(0));
    }

    function test_updateMetadataChangesTheStoredHashAndEmitsProviderUpdated() public {
        vm.startPrank(provider);
        registry.register(keccak256("old"));

        vm.expectEmit(true, false, false, true);
        emit ProviderUpdated(provider, keccak256("new"));
        registry.updateMetadata(keccak256("new"));
        vm.stopPrank();

        assertEq(registry.getProvider(provider).metadataHash, keccak256("new"));
    }

    function test_updateMetadataKeepsTheAnchoredPassport() public {
        vm.prank(provider);
        registry.register(keccak256("old"));
        vm.prank(coordinator);
        registry.anchorPassport(provider, keccak256("passport"));

        vm.prank(provider);
        registry.updateMetadata(keccak256("new"));

        assertEq(registry.getProvider(provider).passportRoot, keccak256("passport"));
    }

    function test_anchorPassportEmitsPassportAnchored() public {
        vm.prank(provider);
        registry.register(keccak256("meta"));

        vm.expectEmit(true, false, false, true);
        emit PassportAnchored(provider, keccak256("passport"));
        vm.prank(coordinator);
        registry.anchorPassport(provider, keccak256("passport"));
    }

    function test_setCoordinatorEmitsAndTheNewCoordinatorTakesOver() public {
        address newCoordinator = makeAddr("newCoordinator");
        vm.prank(provider);
        registry.register(keccak256("meta"));

        vm.expectEmit(false, false, false, true);
        emit CoordinatorUpdated(newCoordinator);
        vm.prank(owner);
        registry.setCoordinator(newCoordinator);

        assertEq(registry.coordinator(), newCoordinator);
        vm.prank(coordinator);
        vm.expectRevert(ProviderRegistry.NotCoordinator.selector);
        registry.anchorPassport(provider, keccak256("old-coordinator"));
        vm.prank(newCoordinator);
        registry.anchorPassport(provider, keccak256("passport"));
    }

    function test_setCoordinatorToZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.setCoordinator(address(0));
        assertEq(registry.coordinator(), coordinator);
    }
}
