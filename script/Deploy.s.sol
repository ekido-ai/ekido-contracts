// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

/// Testnet and Anvil only. Reads addresses from the environment (see .env.example).
/// Anvil (chain 31337) deploys MockUSDC. Otherwise USDC_ADDRESS is used.
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address coordinator = vm.addr(vm.envUint("COORDINATOR_PRIVATE_KEY"));
        address arbiter = vm.addr(vm.envUint("ARBITER_PRIVATE_KEY"));

        address[] memory verifiers = new address[](3);
        verifiers[0] = vm.addr(vm.envUint("VERIFIER_1_PRIVATE_KEY"));
        verifiers[1] = vm.addr(vm.envUint("VERIFIER_2_PRIVATE_KEY"));
        verifiers[2] = vm.addr(vm.envUint("VERIFIER_3_PRIVATE_KEY"));

        uint256 quorum = vm.envOr("VERIFIER_QUORUM", uint256(2));
        uint256 bond = vm.envOr("DISPUTE_BOND", uint256(1_000_000));

        vm.startBroadcast(deployerKey);
        address token;
        if (block.chainid == 31337) {
            token = address(new MockUSDC());
        } else {
            token = vm.envAddress("USDC_ADDRESS");
        }
        GPUChainEscrow escrow = new GPUChainEscrow(IERC20(token), deployer, coordinator, arbiter, verifiers, quorum, bond);
        ProviderRegistry registry = new ProviderRegistry(deployer, coordinator);
        vm.stopBroadcast();

        console2.log("chain", block.chainid);
        console2.log("USDC_ADDRESS", token);
        console2.log("ESCROW_ADDRESS", address(escrow));
        console2.log("REGISTRY_ADDRESS", address(registry));
    }
}
