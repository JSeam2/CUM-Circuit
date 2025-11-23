// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PoseidonT3} from "../src/Poseidon.sol";

/**
 * @title GetMerklePath
 * @notice Script to query Merkle path from a deployed PrivateVault
 * @dev This script requires direct storage access to read the Merkle tree
 *
 * Usage:
 *   Get path for a commitment by its leaf index:
 *     forge script script/GetMerklePath.s.sol:GetMerklePath \
 *       -s "run(address,address,uint256,uint256,uint256)" \
 *       <VAULT_ADDRESS> <TOKEN_ADDRESS> <LEAF_INDEX> <TREE_DEPTH> <SECRET> \
 *       --rpc-url <RPC_URL>
 *
 * Example:
 *   forge script script/GetMerklePath.s.sol:GetMerklePath \
 *     -s "run(address,address,uint256,uint256,uint256)" \
 *     0x1234... 0x0 5 20 11111111 \
 *     --rpc-url http://localhost:8545
 */
contract GetMerklePath is Script {

    // Storage slot calculation for nested mappings in PrivateVault
    // vaults[token].tree[level][index]
    function getTreeStorageSlot(
        address token,
        uint256 level,
        uint256 index
    ) internal pure returns (bytes32) {
        // vaults mapping is at slot 0
        // First, get the slot for vaults[token]
        bytes32 vaultSlot = keccak256(abi.encode(token, uint256(0)));

        // Vault struct layout:
        // 0: currentLeafIndex
        // 1: denomination
        // 2: currentRoot
        // 3: rootHistory (dynamic array)
        // 4: nullifierUsed (mapping)
        // 5: commitmentUsed (mapping)
        // 6: knownRoots (mapping)
        // 7: tree (nested mapping: level => index => hash)
        // 8: treeDepth
        // 9: depositCount
        // 10: withdrawalCount

        // tree mapping is at offset 7 within the Vault struct
        bytes32 treeSlot = bytes32(uint256(vaultSlot) + 7);

        // Now get tree[level]
        bytes32 levelSlot = keccak256(abi.encode(level, treeSlot));

        // Finally get tree[level][index]
        bytes32 indexSlot = keccak256(abi.encode(index, levelSlot));

        return indexSlot;
    }

    function run(
        address vaultAddress,
        address token,
        uint256 leafIndex,
        uint256 treeDepth,
        uint256 secret,
        uint256 nullifier
    ) public view {
        console.log("=== Querying Merkle Path from Vault ===");
        console.log("");
        console.log("Vault Address:", vaultAddress);
        console.log("Token Address:", token);
        console.log("Leaf Index:", leafIndex);
        console.log("Tree Depth:", treeDepth);
        console.log("");

        // Compute commitment to verify
        uint[2] memory commitmentInputs = [secret, nullifier];
        bytes32 commitment = bytes32(PoseidonT3.hash(commitmentInputs));
        console.log("Expected Commitment:");
        console.logBytes32(commitment);
        console.log("");

        // Arrays to store path
        uint256[] memory pathIndices = new uint256[](treeDepth);
        bytes32[] memory pathElements = new bytes32[](treeDepth);

        uint256 currentIndex = leafIndex;

        // Build the Merkle path
        for (uint256 level = 0; level < treeDepth; level++) {
            uint256 siblingIndex;

            if (currentIndex % 2 == 0) {
                // Current is left child, sibling is right
                pathIndices[level] = 0;
                siblingIndex = currentIndex + 1;
            } else {
                // Current is right child, sibling is left
                pathIndices[level] = 1;
                siblingIndex = currentIndex - 1;
            }

            // Read sibling from storage
            bytes32 storageSlot = getTreeStorageSlot(token, level, siblingIndex);
            bytes32 siblingValue = vm.load(vaultAddress, storageSlot);
            pathElements[level] = siblingValue;

            // Move to parent level
            currentIndex = currentIndex / 2;
        }

        console.log("=== Merkle Path Retrieved ===");
        console.log("");

        // Print path_indices for Prover.toml
        console.log("path_indices = [");
        for (uint256 i = 0; i < treeDepth; i++) {
            if (i == treeDepth - 1) {
                console.log('  "%d"', pathIndices[i]);
            } else {
                console.log('  "%d",', pathIndices[i]);
            }
        }
        console.log("]");
        console.log("");

        // Print path_elements for Prover.toml
        console.log("path_elements = [");
        for (uint256 i = 0; i < treeDepth; i++) {
            if (i == treeDepth - 1) {
                console.log('  "%x"', uint256(pathElements[i]));
            } else {
                console.log('  "%x",', uint256(pathElements[i]));
            }
        }
        console.log("]");
        console.log("");

        // Verify the path by recomputing root
        bytes32 currentHash = commitment;
        for (uint256 i = 0; i < treeDepth; i++) {
            bytes32 left;
            bytes32 right;

            if (pathIndices[i] == 0) {
                left = currentHash;
                right = pathElements[i];
            } else {
                left = pathElements[i];
                right = currentHash;
            }

            uint[2] memory inputs = [uint256(left), uint256(right)];
            currentHash = bytes32(PoseidonT3.hash(inputs));
        }

        console.log("=== Verification ===");
        console.log("Computed Root:");
        console.logBytes32(currentHash);
        console.log("");
        console.log("Note: Compare this root with the vault's getCurrentRoot()");
        console.log("If they match, the path is correct!");
    }
}
