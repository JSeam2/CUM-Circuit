// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoseidonT3} from "./Poseidon.sol";

interface IWithdrawalVerifier {
    function verify(bytes calldata _proof, uint256[] calldata _publicInputs) external view returns (bool);
}

/**
 * @title PrivateVault
 * @notice Simplified private vault using ZK proofs for withdrawals with on-chain Merkle tree computation using Poseidon hash
 * @dev On-chain Merkle tree computation - deposits compute root on-chain, withdrawals verified with ZK proofs
 */
abstract contract PrivateVault {
    // Verifier contract for withdrawals
    IWithdrawalVerifier public immutable withdrawalVerifier;

    // Root history to allow for multiple claims
    uint256 public immutable ROOT_HISTORY_SIZE = 30;

    struct Vault {
        uint256 currentLeafIndex;
        uint256 denomination;
        bytes32 currentRoot;
        bytes32[] rootHistory;
        mapping(bytes32 => bool) nullifierSpent;
        mapping(bytes32 => bool) commitmentUsed;
        mapping(bytes32 => bool) knownRoots;
        // Merkle tree storage: level => index => hash
        mapping(uint256 => mapping(uint256 => bytes32)) tree;
        uint256 treeDepth;
    }

    mapping(address => Vault) public vaults;

    // Events
    event NewVaultDenomination(address indexed token, uint256 newDenomination);

    event PrivateDeposit(
        bytes32 indexed commitment,
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot,
        uint256 leafIndex
    );

    event PrivateWithdrawal(
        bytes32 indexed nullifierHash,
        address indexed recipient,
        bytes32 indexed merkleRoot
    );

    // Errors
    error InvalidWithdrawalVerifier();
    error InvalidCommitment();
    error CommitmentAlreadyUsed();
    error NullifierSpent();
    error InvalidWithdrawalProof();
    error InvalidRecipient();
    error InvalidRoot();
    error InvalidLeafIndex();

    constructor(
        address _withdrawalVerifier,
        uint256 _treeDepth,
        bytes32[] memory _initialRoots,
        address[] memory _tokenAddresses,
        uint256[] memory _denominations
    ) {
        if (_withdrawalVerifier == address(0)) revert InvalidWithdrawalVerifier();

        withdrawalVerifier = IWithdrawalVerifier(_withdrawalVerifier);

        // Populate vaults
        uint256 tokenAddressLen = _tokenAddresses.length;
        for (uint256 i = 0; i < tokenAddressLen; ) {
            address token = _tokenAddresses[i];
            uint256 newDenomination = _denominations[i];

            Vault storage vault = vaults[token];
            vault.denomination = newDenomination;
            vault.treeDepth = _treeDepth;
            bytes32 initialRoot = _initialRoots[i];
            vault.currentRoot = initialRoot;
            vault.rootHistory.push(initialRoot);
            vault.knownRoots[initialRoot] = true;

            emit NewVaultDenomination(token, newDenomination);

            // unlikely for overflow
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal function to handle private deposits.
     * NOTE: Reentrancy protection should be applied in the derived contract.
     * NOTE: Fund transfer mechanisms should be implemented in the derived contract
     * You will need to handle the fixed denominations.
     * @param token The token address being deposited. address(0) for ETH
     * @param commitment The commitment being inserted
     */
    function _privateDeposit(
        address token,
        bytes32 commitment
    ) internal {
        if (commitment == bytes32(0)) revert InvalidCommitment();

        Vault storage vault = vaults[token];

        if (vault.commitmentUsed[commitment]) revert CommitmentAlreadyUsed();

        bytes32 oldRoot = vault.currentRoot;
        uint256 leafIndex = vault.currentLeafIndex;

        // Compute new root on-chain using Poseidon
        bytes32 newRoot = _computeNewRoot(vault, commitment);

        // Mark commitment as used
        vault.commitmentUsed[commitment] = true;

        // Update the Merkle root
        _updateRoot(vault, newRoot);

        emit PrivateDeposit(commitment, oldRoot, newRoot, leafIndex);
    }

    /**
     * @notice Internal function to handle private withdrawals h
     * NOTE: Reentrancy protection should be applied in the derived contract.
     * NOTE: Fund transfer mechanisms should be implemented in the derived contract.
     * You will need to handle the fixed denominations.
     * @dev Verifies ZK proof of commitment inclusion
     * @param proof ZK proof from Noir withdrawal circuit
     * @param token The token address being deposited. address(0) for ETH
     * @param merkleRoot The Merkle root being proven against
     * @param nullifierHash Hash of the nullifier (prevents double spending)
     * @param recipient Address to receive the withdrawn funds
     * @param relayer Address of the relayer (if any)
     * @param fee Fee amount to pay the relayer
     */
    function _privateWithdraw(
        bytes calldata proof,
        address token,
        bytes32 merkleRoot,
        bytes32 nullifierHash,
        address recipient,
        address relayer,
        uint256 fee
    ) internal {
        Vault storage vault = vaults[token];
        if (vault.nullifierSpent[nullifierHash]) revert NullifierSpent();
        if (!vault.knownRoots[merkleRoot]) revert InvalidRoot();

        // Verify the withdrawal proof
        // Public inputs: (merkle_root, nullifier_hash, recipient)
        uint256[] memory publicInputs = new uint256[](5);
        publicInputs[0] = uint256(merkleRoot);
        publicInputs[1] = uint256(nullifierHash);
        publicInputs[2] = uint256(uint160(recipient));
        publicInputs[3] = uint256(uint160(relayer));
        publicInputs[4] = fee;

        if(!withdrawalVerifier.verify(proof, publicInputs)) revert InvalidWithdrawalProof();

        // Mark nullifier as spent
        vault.nullifierSpent[nullifierHash] = true;

        emit PrivateWithdrawal(nullifierHash, recipient, merkleRoot);
    }

    /**
     * @notice change denomination of a given token in a vault to account for balance changes in a main vault
     * @param token The token address
     * @param newDenomination The new denomination
     */
    function setDenomination(address token, uint256 newDenomination) internal {
        Vault storage vault = vaults[token];
        vault.denomination = newDenomination;
        emit NewVaultDenomination(token, newDenomination);
    }

    /**
     * @notice Check if a nullifier has been spent
     * @param token The token address
     * @param nullifierHash The nullifier hash to check
     */
    function isNullifierSpent(address token, bytes32 nullifierHash) public view returns (bool) {
        Vault storage vault = vaults[token];
        return vault.nullifierSpent[nullifierHash];
    }

    /**
     * @notice Check if a commitment has been used
     * @param token The token address
     * @param commitment The commitment to check
     */
    function isCommitmentUsed(address token, bytes32 commitment) public view returns (bool) {
        Vault storage vault = vaults[token];
        return vault.commitmentUsed[commitment];
    }

    /**
     *   @dev Helper for Merkle Logic. Returns the last root
     *   @param token The token address
     */
    function getLastRoot(address token) public view returns (bytes32) {
        Vault storage vault = vaults[token];
        return vault.currentRoot;
    }

    /**
     * @notice Helper for Merkle Logic. Check if a root is known (current or recent)
     * @param token The token address
     * @param _root The Merkle root to check
     */
    function isKnownRoot(address token, bytes32 _root) public view returns (bool) {
        Vault storage vault = vaults[token];
        return vault.knownRoots[_root];
    }

    /**
     * @notice Helper for Merkle Logic. Get the current Merkle root for a given token
     * @param token The token address
     */
    function getCurrentRoot(address token) external view returns (bytes32) {
        Vault storage vault = vaults[token];
        return vault.currentRoot;
    }

    /**
     * @notice Helper for Merkle Logic. Get the current leaf index
     * @param token The token address
     */
    function getCurrentLeafIndex(address token) external view returns (uint256) {
        Vault storage vault = vaults[token];
        return vault.currentLeafIndex;
    }

    /**
     * @notice Helper for Merkle Logic. Get the number of stored roots
     * @param token The token address
     */
    function getRootHistoryLength(address token) external view returns (uint256) {
        Vault storage vault = vaults[token];
        return vault.rootHistory.length;
    }

    /**
     * @notice Compute new Merkle root by inserting a leaf at the current leaf index
     * @param vault The vault struct
     * @param _leaf The leaf value (commitment) to insert
     * @return The new Merkle root
     */
    function _computeNewRoot(Vault storage vault, bytes32 _leaf) internal returns (bytes32) {
        uint256 leafIndex = vault.currentLeafIndex;

        // Store the leaf at level 0
        vault.tree[0][leafIndex] = _leaf;

        bytes32 currentHash = _leaf;
        uint256 currentIndex = leafIndex;

        // Hash up the tree
        for (uint256 level = 0; level < vault.treeDepth; level++) {
            bytes32 left;
            bytes32 right;

            if (currentIndex % 2 == 0) {
                // Current node is left child
                left = currentHash;
                right = vault.tree[level][currentIndex + 1];
            } else {
                // Current node is right child
                left = vault.tree[level][currentIndex - 1];
                right = currentHash;
            }

            // Compute parent hash using PoseidonT3
            uint[2] memory inputs = [uint256(left), uint256(right)];
            currentHash = bytes32(PoseidonT3.hash(inputs));

            // Move to parent level
            currentIndex = currentIndex / 2;

            // Store the hash at the next level
            vault.tree[level + 1][currentIndex] = currentHash;
        }

        return currentHash;
    }

    /**
     * @notice Helper for Merkle Logic. Update the Merkle root after computing on-chain
     * @param vault The vault struct
     * @param _newRoot The new Merkle root
     */
    function _updateRoot(Vault storage vault, bytes32 _newRoot) internal {
        if (_newRoot == bytes32(0)) revert InvalidRoot();

        // Update current root
        vault.currentRoot = _newRoot;
        vault.knownRoots[_newRoot] = true;

        // Add to history
        vault.rootHistory.push(_newRoot);

        // Keep only last ROOT_HISTORY_SIZE roots
        if (vault.rootHistory.length > ROOT_HISTORY_SIZE) {
            bytes32 expiredRoot = vault.rootHistory[vault.rootHistory.length - ROOT_HISTORY_SIZE - 1];
            delete vault.knownRoots[expiredRoot];
        }

        ++vault.currentLeafIndex;
    }
}
