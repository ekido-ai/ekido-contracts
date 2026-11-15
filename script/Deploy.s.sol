// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

/// Testnet and Anvil only. Reads addresses from the environment (see .env.example).
/// Anvil (chain 31337) deploys MockUSDC. Otherwise USDC_ADDRESS is used.
/// Only DEPLOYER_PRIVATE_KEY is needed on the deploy machine. For the coordinator, arbiter and verifiers the
/// script takes an address (COORDINATOR_ADDRESS, ARBITER_ADDRESS, VERIFIER_1_ADDRESS ...) and falls back to the
/// address of the matching *_PRIVATE_KEY only when the address variable is unset.
contract Deploy is Script {
    function _role(string memory addressName, string memory keyName) internal view returns (address) {
        address given = vm.envOr(addressName, address(0));
        if (given != address(0)) return given;
        return vm.addr(vm.envUint(keyName));
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address coordinator = _role("COORDINATOR_ADDRESS", "COORDINATOR_PRIVATE_KEY");
        address arbiter = _role("ARBITER_ADDRESS", "ARBITER_PRIVATE_KEY");

        address[] memory verifiers = new address[](3);
        verifiers[0] = _role("VERIFIER_1_ADDRESS", "VERIFIER_1_PRIVATE_KEY");
        verifiers[1] = _role("VERIFIER_2_ADDRESS", "VERIFIER_2_PRIVATE_KEY");
        verifiers[2] = _role("VERIFIER_3_ADDRESS", "VERIFIER_3_PRIVATE_KEY");

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
