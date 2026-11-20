// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProofAnchor} from "../src/ProofAnchor.sol";

/// Deploys ProofAnchor only (it shares nothing with GPUChainEscrow). Testnet and Anvil only.
/// Needs DEPLOYER_PRIVATE_KEY, plus PROOF_ANCHOR_OWNER (a team-held address) and COORDINATOR_ADDRESS.
contract DeployProofAnchor is Script {
    function run() external returns (ProofAnchor anchor) {
        require(block.chainid == 84532 || block.chainid == 31337, "Base Sepolia or Anvil only");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("PROOF_ANCHOR_OWNER");
        address coordinator = vm.envAddress("COORDINATOR_ADDRESS");

        vm.startBroadcast(deployerKey);
        anchor = new ProofAnchor(owner, coordinator);
        vm.stopBroadcast();

        console2.log("ProofAnchor", address(anchor));
        console2.log("owner", owner);
        console2.log("coordinator", coordinator);
    }
}
