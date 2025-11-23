use dep::poseidon::{poseidon};

// Merkle tree depth (must match PrivateVault.sol)
global TREE_DEPTH: u32 = 20;

// Main withdrawal circuit
// This circuit proves that:
// 1. User knows a valid commitment (secret + nullifier) that exists in the Merkle tree
// 2. The nullifier hash is correctly computed
// 3. All public inputs match
fn main(
    // Private inputs
    secret: Field,           // User's secret
    nullifier: Field,        // User's nullifier
    path_indices: [u1; TREE_DEPTH], // Merkle path: 0 = left, 1 = right
    path_elements: [Field; TREE_DEPTH], // Merkle path sibling hashes

    // Public inputs
    merkle_root: pub Field,  // The Merkle root to verify against
    nullifier_hash: pub Field, // Hash of nullifier (prevents double spending)
    recipient: pub Field,    // Recipient address
    relayer: pub Field,      // Relayer address (can be 0)
    fee: pub Field           // Fee for relayer
) {
    // 1. Compute the commitment from secret and nullifier
    let commitment = compute_commitment(secret, nullifier);

    // 2. Verify Merkle proof: commitment is in the tree with given root
    let computed_root = compute_merkle_root(commitment, path_indices, path_elements);
    assert(computed_root == merkle_root, "Invalid Merkle proof");

    // 3. Verify nullifier hash
    let computed_nullifier_hash = compute_nullifier_hash(nullifier);
    assert(computed_nullifier_hash == nullifier_hash, "Invalid nullifier hash");

    // Note: recipient, relayer, and fee are public inputs but not constrained here
    // They are used in the smart contract to determine where to send funds
    // These are verified on-chain in the smart contract
    let _ = recipient;
    let _ = relayer;
    let _ = fee;
}

// Compute commitment from secret and nullifier using Poseidon hash
// Note: We use Poseidon with 2 inputs to match Poseidon.sol's hash function
fn compute_commitment(secret: Field, nullifier: Field) -> Field {
    poseidon::bn254::hash_2([secret, nullifier])
}

// Compute nullifier hash using Poseidon hash
// Note: For single input, we pad with zero to maintain 2-input structure
fn compute_nullifier_hash(nullifier: Field) -> Field {
    poseidon::bn254::hash_2([nullifier, 0])
}

// Compute Merkle root from leaf and path
fn compute_merkle_root(
    leaf: Field,
    path_indices: [u1; TREE_DEPTH],
    path_elements: [Field; TREE_DEPTH]
) -> Field {
    let mut current_hash = leaf;

    for i in 0..TREE_DEPTH {
        let path_element = path_elements[i];
        let is_right = path_indices[i];

        // Determine left and right based on path index
        let (left, right) = if is_right == 0 {
            (current_hash, path_element)
        } else {
            (path_element, current_hash)
        };

        // Hash the pair using Poseidon (2 inputs)
        current_hash = poseidon::bn254::hash_2([left, right]);
    }

    current_hash
}

#[test]
fn test_commitment_computation() {
    let secret = 123;
    let nullifier = 456;

    let commitment = compute_commitment(secret, nullifier);

    // Commitment should be deterministic
    let commitment2 = compute_commitment(secret, nullifier);
    assert(commitment == commitment2);

    // Different inputs should produce different commitments
    let commitment3 = compute_commitment(secret + 1, nullifier);
    assert(commitment != commitment3);
}

#[test]
fn test_nullifier_hash_computation() {
    let nullifier = 789;

    let nullifier_hash = compute_nullifier_hash(nullifier);

    // Should be deterministic
    let nullifier_hash2 = compute_nullifier_hash(nullifier);
    assert(nullifier_hash == nullifier_hash2);

    // Different nullifiers should produce different hashes
    let nullifier_hash3 = compute_nullifier_hash(nullifier + 1);
    assert(nullifier_hash != nullifier_hash3);
}

#[test]
fn test_merkle_root_computation() {
    // Simple test with depth 3
    let leaf = 100;
    let path_indices = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    let path_elements = [200, 300, 400, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    let root = compute_merkle_root(leaf, path_indices, path_elements);

    // Recompute to verify determinism
    let root2 = compute_merkle_root(leaf, path_indices, path_elements);
    assert(root == root2);
}

#[test]
fn test_poseidon_compatibility() {
    // Test vectors from Solidity Poseidon.sol
    // These values must match to ensure compatibility between circuits and contracts

    // Test 1: hash([1, 2]) should equal 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
    let result1 = poseidon::bn254::hash_2([1, 2]);
    let expected1 = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a;
    assert(result1 == expected1, "Poseidon hash([1, 2]) does not match Solidity");

    // Test 2: hash([123, 456])
    let result2 = poseidon::bn254::hash_2([123, 456]);
    // Expected from Solidity PoseidonT3: 0x2b60bf8caa91452f000be587c441f6495f36def6fc4c36f5cc7b5d673f59fd0f
    let expected2 = 0x2b60bf8caa91452f000be587c441f6495f36def6fc4c36f5cc7b5d673f59fd0f;
    assert(result2 == expected2, "Poseidon hash([123, 456]) does not match Solidity");

    // Test 3: Commitment test hash([11111111, 22222222])
    let result3 = poseidon::bn254::hash_2([11111111, 22222222]);
    let expected3 = 0x027d41a203035596e96fda110d73edf92d17ca4c60b28bf72b0f2bc593f226eb;
    assert(result3 == expected3, "Commitment hash does not match Solidity");
}

#[test]
fn test_empty_tree_root() {
    // Compute empty tree root (all leaves are 0)
    // This should match the empty root from PrivateVault.sol
    let mut current_hash = 0;

    for _ in 0..TREE_DEPTH {
        current_hash = poseidon::bn254::hash_2([current_hash, current_hash]);
    }

    // Expected from Solidity: 0x2134e76ac5d21aab186c2be1dd8f84ee880a1e46eaf712f9d371b6df22191f3e
    let expected_root = 0x2134e76ac5d21aab186c2be1dd8f84ee880a1e46eaf712f9d371b6df22191f3e;
    assert(current_hash == expected_root, "Empty tree root does not match Solidity");
}

#[test]
fn test_full_withdrawal_circuit() {
    // Full integration test of the withdrawal circuit
    let secret = 11111111;
    let nullifier = 22222222;

    // Compute commitment
    let commitment = compute_commitment(secret, nullifier);
    // Should be 0x027d41a203035596e96fda110d73edf92d17ca4c60b28bf72b0f2bc593f226eb
    assert(commitment == 0x027d41a203035596e96fda110d73edf92d17ca4c60b28bf72b0f2bc593f226eb);

    // Compute nullifier hash
    let nullifier_hash = compute_nullifier_hash(nullifier);

    // Build a simple Merkle path (commitment at index 0, tree depth 20)
    let path_indices = [0; TREE_DEPTH];
    let mut path_elements = [0; TREE_DEPTH];

    // All siblings are 0 for a tree with single commitment at index 0
    for i in 0..TREE_DEPTH {
        path_elements[i] = 0;
    }

    // Compute merkle root
    let merkle_root = compute_merkle_root(commitment, path_indices, path_elements);

    // Public inputs for withdrawal
    let recipient = 0x1234567890;
    let relayer = 0;
    let fee = 0;

    // Call main function (this would be the actual circuit)
    main(
        secret,
        nullifier,
        path_indices,
        path_elements,
        merkle_root,
        nullifier_hash,
        recipient,
        relayer,
        fee
    );
}