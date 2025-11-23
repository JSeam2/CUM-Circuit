// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PoseidonT3} from "../src/Poseidon.sol";

/**
 * @title GenerateCommitment
 * @notice Script to generate commitments and nullifier hashes for the private vault
 * @dev Usage:
 *   Generate new random values:
 *     forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run()"
 *
 *   Generate from specific values:
 *     forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run(uint256,uint256)" <secret> <nullifier>
 *
 *   Example:
 *     forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run(uint256,uint256)" 11111111 22222222
 */
contract GenerateCommitment is Script {
    function run() public view {
        // Generate random secret and nullifier
        uint256 secret = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "secret")));
        uint256 nullifier = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "nullifier")));

        _generateAndPrint(secret, nullifier);
    }

    function run(uint256 secret, uint256 nullifier) public view {
        _generateAndPrint(secret, nullifier);
    }

    function _generateAndPrint(uint256 secret, uint256 nullifier) internal view {
        // Compute commitment: hash(secret, nullifier)
        uint[2] memory commitmentInputs = [secret, nullifier];
        bytes32 commitment = bytes32(PoseidonT3.hash(commitmentInputs));

        // Compute nullifier hash: hash(nullifier, 0)
        uint[2] memory nullifierHashInputs = [nullifier, 0];
        bytes32 nullifierHash = bytes32(PoseidonT3.hash(nullifierHashInputs));

        // Print results
        console.log("=== Commitment Generation ===");
        console.log("");
        console.log("IMPORTANT: Keep secret and nullifier PRIVATE!");
        console.log("");
        console.log("Private Inputs (DO NOT SHARE):");
        console.log("  secret       =", secret);
        console.log("  nullifier    =", nullifier);
        console.log("");
        console.log("Public Values (safe to share):");
        console.log("  commitment   =");
        console.logBytes32(commitment);
        console.log("  nullifierHash=");
        console.logBytes32(nullifierHash);
        console.log("");
        console.log("=== For Prover.toml ===");
        console.log('secret = "%x"', secret);
        console.log('nullifier = "%x"', nullifier);
        console.log('nullifier_hash = "%x"', uint256(nullifierHash));
        console.log("");
        console.log("=== For Deposit ===");
        console.log("Use this commitment for deposit:");
        console.logBytes32(commitment);
    }
}
