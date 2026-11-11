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
}
