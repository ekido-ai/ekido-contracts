// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdJson} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GPUChainEscrow} from "../src/GPUChainEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// Proves Python's signatures are accepted by the contract, using the shared vector file
/// produced by packages/gpuchain_core/tests/generate_verdict_vector.py.
contract SignatureVectorTest is Test {
    using stdJson for string;

    string internal json;
    GPUChainEscrow internal escrow;
    MockUSDC internal usdc;
    address internal client = makeAddr("client");
    address internal coordinator = makeAddr("coordinator");

    function setUp() public {
        json = vm.readFile("../docs/schemas/vectors/verdict_vector.json");
        vm.chainId(json.readUint(".chain_id"));
        usdc = new MockUSDC();

        address[] memory verifiers = json.readAddressArray(".cases[0].signers");
        address target = json.readAddress(".contract");
        // Deploy at the vector's address, because the digest commits to the contract address.
        deployCodeTo(
            "GPUChainEscrow.sol:GPUChainEscrow",
            abi.encode(IERC20(address(usdc)), address(this), coordinator, address(this), verifiers, uint256(2), uint256(0)),
            target
        );
        escrow = GPUChainEscrow(target);
    }

    function _verdict(uint256 index) internal view returns (GPUChainEscrow.Verdict memory v) {
        string memory base = string.concat(".cases[", vm.toString(index), "].verdict");
        v.jobId = json.readBytes32(string.concat(base, ".jobId"));
        v.passed = json.readBool(string.concat(base, ".passed"));
        v.finalCheckpoint = json.readBytes32(string.concat(base, ".finalCheckpoint"));
        v.lineageRoot = json.readBytes32(string.concat(base, ".lineageRoot"));
        v.qualityReport = json.readBytes32(string.concat(base, ".qualityReport"));
        v.payees = json.readAddressArray(string.concat(base, ".payees"));
        v.amounts = json.readUintArray(string.concat(base, ".amounts"));
        v.refund = json.readUint(string.concat(base, ".refund"));
        v.expiry = uint64(json.readUint(string.concat(base, ".expiry")));
    }

    function _digest(uint256 index) internal view returns (bytes32) {
        return json.readBytes32(string.concat(".cases[", vm.toString(index), "].digest"));
    }

    function test_digestMatchesPython() public view {
        assertEq(escrow.hashVerdict(_verdict(0)), _digest(0), "passed verdict");
        assertEq(escrow.hashVerdict(_verdict(1)), _digest(1), "failed verdict with empty arrays");
    }

    function test_pythonSignaturesRecoverToExpectedSigners() public view {
        for (uint256 c; c < 2; ++c) {
            string memory base = string.concat(".cases[", vm.toString(c), "]");
            address[] memory signers = json.readAddressArray(string.concat(base, ".signers"));
            for (uint256 i; i < signers.length; ++i) {
                bytes memory signature = json.readBytes(string.concat(base, ".signatures[", vm.toString(i), "]"));
                assertEq(ECDSA.recover(_digest(c), signature), signers[i]);
            }
        }
    }

    function _ascendingSignatures(uint256 c, uint256 count) internal view returns (bytes[] memory out) {
        string memory base = string.concat(".cases[", vm.toString(c), "]");
        address[] memory signers = json.readAddressArray(string.concat(base, ".signers"));
        uint256[] memory order = new uint256[](signers.length);
        for (uint256 i; i < order.length; ++i) {
            order[i] = i;
        }
        for (uint256 i; i < order.length; ++i) {
            for (uint256 j = i + 1; j < order.length; ++j) {
                if (signers[order[j]] < signers[order[i]]) {
                    (order[i], order[j]) = (order[j], order[i]);
                }
            }
        }
        out = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = json.readBytes(string.concat(base, ".signatures[", vm.toString(order[i]), "]"));
        }
    }

    function test_contractAcceptsPythonAttestationAndPays() public {
        GPUChainEscrow.Verdict memory v = _verdict(0);
        uint256 budget = v.amounts[0] + v.amounts[1] + v.refund;
        usdc.mint(client, budget);

        vm.warp(1_800_000_000);
        vm.startPrank(client);
        usdc.approve(address(escrow), budget);
        escrow.createJob(v.jobId, 0, 0, budget, uint64(block.timestamp + 1 days), 1 hours);
        vm.stopPrank();
        vm.prank(coordinator);
        escrow.markActive(v.jobId);

        escrow.submitAttestation(v, _ascendingSignatures(0, 2));
        vm.warp(block.timestamp + 1 hours);
        escrow.finalize(v.jobId);

        assertEq(escrow.withdrawable(v.payees[0]), v.amounts[0]);
        assertEq(escrow.withdrawable(v.payees[1]), v.amounts[1]);
        assertEq(escrow.withdrawable(client), v.refund);
    }
}
