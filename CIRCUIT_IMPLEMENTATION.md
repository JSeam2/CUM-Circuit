# Withdrawal Circuit Implementation

## Overview

This document describes the implementation of the withdrawal circuit for the PrivateVault system using Noir and Poseidon hash functions. This is a port of Tornado Cash V1 into Noir and Poseidon hashing scheme.

## Architecture

### Circuit Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Withdrawal Circuit                        │
│                                                              │
│  Private Inputs:                                            │
│    - secret: User's secret value                            │
│    - nullifier: User's nullifier                            │
│    - path_indices: Merkle tree path (left/right)           │
│    - path_elements: Merkle tree siblings                    │
│                                                              │
│  Public Inputs:                                             │
│    - merkle_root: Current tree root                         │
│    - nullifier_hash: Hash of nullifier                      │
│    - recipient: Withdrawal recipient address                │
│    - relayer: Optional relayer address                      │
│    - fee: Fee for relayer                                   │
│                                                              │
│  Constraints:                                               │
│    1. commitment = Poseidon(secret, nullifier)             │
│    2. computed_root = MerkleProof(commitment, path)        │
│    3. computed_root == merkle_root                         │
│    4. computed_nullifier_hash = Poseidon(nullifier)        │
│    5. computed_nullifier_hash == nullifier_hash            │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Commitment Computation

Commitments are computed using Poseidon hash with 2 inputs:

```noir
commitment = Poseidon([secret, nullifier])
```

**Why this matters:**
- The commitment hides both the secret and nullifier
- Only someone who knows both values can prove ownership
- The commitment is stored in the Merkle tree on-chain

### 2. Nullifier Hash

The nullifier hash prevents double-spending:

```noir
nullifier_hash = Poseidon([nullifier, zero])
```

**Why this matters:**
- The nullifier hash is revealed during withdrawal
- The smart contract tracks spent nullifiers
- Can't link nullifier hash back to commitment without the secret

### 3. Merkle Proof Verification

The circuit verifies the commitment exists in the Merkle tree:

```noir
for each level in tree:
    if path_index[level] == 0:
        hash = Poseidon2([current_hash, sibling])
    else:
        hash = Poseidon2([sibling, current_hash])
    current_hash = hash

assert(current_hash == merkle_root)
```

**Why this matters:**
- Proves the user's commitment is in the tree
- Doesn't reveal which commitment
- Enables privacy-preserving withdrawals

## Poseidon Hash Compatibility

### Noir Implementation
- Uses `std::hash::poseidon::bn254::hash_2` for 2-input hashing
- BN254 curve compatible with Ethereum

### Solidity Implementation
- Uses circomlibjs Poseidon parameters
- 8 full rounds, 57 partial rounds
- Same field as Noir (BN254)

### Compatibility Testing

Test vectors verify that Noir and Solidity produce identical hashes:

| Input | Expected Output (hex) |
|-------|----------------------|
| [1, 2] | 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a |
| [123, 456] | 0x2b5dfc8f49e04ca59bba30f8da8bf66d8bc6eb3f05bfc10e65e8e1a7bbe9fd8f |
| [11111111, 22222222] | 0x027d41a203035596e96fda110d73edf92d17ca4c60b28bf72b0f2bc593f226eb |

Empty tree root (depth 20): `0x2134e76ac5d21aab186c2be1dd8f84ee880a1e46eaf712f9d371b6df22191f3e`

## Public Inputs

The following values are public (visible on-chain):

1. **merkle_root**: The Merkle root being proven against
2. **nullifier_hash**: Prevents double-spending
3. **recipient**: Where to send the withdrawn funds
4. **relayer**: Optional relayer for meta-transactions
5. **fee**: Fee paid to relayer

**Privacy guarantees:**
- Cannot link withdrawal to specific deposit
- Cannot determine which commitment was spent
- Only the nullifier hash is revealed (one-time use)

## Testing

### Unit Tests

1. **test_commitment_computation**: Verifies commitment determinism
2. **test_nullifier_hash_computation**: Verifies nullifier hash determinism
3. **test_merkle_root_computation**: Verifies Merkle proof computation
4. **test_poseidon_compatibility**: Verifies Noir matches Solidity
5. **test_empty_tree_root**: Verifies empty tree initialization
6. **test_full_withdrawal_circuit**: End-to-end integration test

### Running Tests

```bash
# Check circuit compiles
nargo check

# Run all tests
nargo test

# Run specific test
nargo test test_poseidon_compatibility
```

## Integration with Smart Contracts

### On-Chain (Solidity)

1. **Deposit**:
   - User computes commitment off-chain
   - Contract computes new Merkle root using Poseidon
   - Commitment added to tree

2. **Withdrawal**:
   - User generates proof off-chain
   - Contract verifies proof
   - Contract checks nullifier not spent
   - Contract transfers funds to recipient

### Circuit Parameters

- **Tree Depth**: 20 (supports 2^20 = 1,048,576 deposits)
- **Field**: BN254 (bn128)
- **Hash Function**: Poseidon (2-input variant)

## Security Considerations

1. **Nullifier Uniqueness**: Each commitment can only be withdrawn once
2. **Merkle Root Validity**: Only recent roots are accepted (30 root history)
3. **Commitment Privacy**: Cannot reverse engineer secret from commitment
4. **Proof Validity**: Zero-knowledge proof ensures no information leakage

## Gas Costs

| Operation | Approximate Gas Cost |
|-----------|---------------------|
| Poseidon Hash (2 inputs) | ~315,000 gas |
| Deposit (20 hashes) | ~7,000,000 gas |
| Withdrawal Verification | TBD (depends on proof system) |

## Future Improvements

1. **Proof System**: Integrate with Barretenberg backend
2. **Batch Withdrawals**: Support multiple withdrawals in one proof
3. **Optimized Tree**: Consider different tree depths for different use cases
4. **Relayer Network**: Build infrastructure for meta-transactions

## References

- [Poseidon Paper](https://eprint.iacr.org/2019/458.pdf)
- [Noir Documentation](https://noir-lang.org/)
- [Circomlibjs](https://github.com/iden3/circomlibjs)
- [Tornado Cash Circuits](https://github.com/tornadocash/tornado-core)
- [Chance Hudson's Poseidon Solidity Implementation](https://github.com/chancehudson/poseidon-solidity)