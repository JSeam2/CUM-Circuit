# CUM Circuits for Private Deposit & Withdrawal

Circuits for Cleverly Using Money (CUM). Noir-based zero-knowledge proof circuit for private deposits and withdrawals using Merkle tree inclusion proofs.

This repository is designed for use with other ERC4626 vaults for private DeFi, but may be repurposed for other use cases.

## Overview

This circuit enables:
1. **Private Deposits**: Users commit `Poseidon2Hash(nullifier + secret)` to a Merkle tree
2. **Private Withdrawals**: Users prove they have a valid deposit without revealing which one
3. **Double-Spend Prevention**: Nullifier hashes prevent the same deposit from being withdrawn twice

**Important**: Uses Poseidon2 hash function for compatibility between Noir circuit and Solidity contracts.

## Circuit Architecture

### Public Inputs
- `merkle_root`: Root of the Merkle tree containing all deposits
- `nullifier_hash`: Hash of the unique nullifier (prevents double spending)
- `recipient`: Ethereum address receiving the withdrawal

### Private Inputs
- `nullifier`: Secret value used to compute commitment and nullifier hash
- `secret`: Second secret value used to compute commitment
- `merkle_path`: Sibling nodes for Merkle proof (depth 20)
- `path_indices`: Left/right path indicators for Merkle proof

### Circuit Logic

1. **Commitment Computation**: `commitment = Poseidon2Hash(nullifier, secret)`
2. **Merkle Inclusion Proof**: Verify commitment exists in the tree using Poseidon2
3. **Nullifier Verification**: Verify `nullifier_hash = Poseidon2Hash(nullifier)`
4. **Recipient Binding**: Recipient is a public input, binding proof to specific address

## Usage

### Testing the Circuit

```bash
# Run all tests
nargo test
```

### Compiling the Circuit

```bash
# Compile the circuit
nargo compile
```

### Generating Verifier with Barretenberg (bb)

Noir uses Barretenberg as its proving backend. To generate a Solidity verifier:

```bash
# Step 1: Compile the circuit to get the artifact
nargo compile

# Step 2: Generate the Solidity verifier using bb
bb write_vk -b ./target/cum_circuit.json
bb contract

# This generates UltraVerifier.sol which can be deployed to Ethereum
```

Alternatively, if you have `@noir-lang/backend_barretenberg` installed:

```bash
# Generate proof
nargo prove

# Generate Solidity verifier (legacy method)
bb write_vk -b ./target/cum_circuit.json
bb contract -o ./contracts/
```

### Creating Commitments and Proofs

#### 1. Generate a Commitment (for deposit)

```bash
cd scripts
npm install
node generate_commitment.js generate
```

This will output:
- `nullifier`: Keep this private!
- `secret`: Keep this private!
- `commitment`: Submit this to the contract's deposit function

#### 2. Create Prover.toml

Create `Prover.toml` with your private inputs:

```toml
nullifier = "0x123..."
secret = "0x456..."
merkle_path = ["0x0", "0x0", ...] # 20 values
path_indices = [0, 0, ...] # 20 values (0 or 1)
merkle_root = "0x789..."
nullifier_hash = "0xabc..."
recipient = "0xdef..."
```

#### 3. Generate the Proof

```bash
nargo prove
```

This creates `proofs/cum_circuit.proof` which can be submitted to the contract.

#### 4. Verify the Proof (optional, for testing)

```bash
nargo verify
```

## Integration with Ethereum

### Deposit Flow

1. User generates random `nullifier` and `secret` (keep private!)
2. Compute `commitment = Poseidon2Hash(nullifier, secret)` using the JS utility
3. Call smart contract's `deposit()` function with commitment
4. Contract adds commitment to Merkle tree using Poseidon2

### Withdrawal Flow

1. User computes `nullifier_hash = Poseidon2Hash(nullifier)` using the JS utility
2. User builds Merkle proof showing their commitment is in the tree
3. User generates ZK proof with this circuit
4. User submits proof, merkle_root, nullifier_hash, and recipient to contract
5. Contract verifies:
   - Merkle root is known (recent root)
   - Proof is valid (using Solidity verifier)
   - Nullifier hash hasn't been used before
6. Contract marks nullifier_hash as spent and sends funds to recipient

## Smart Contracts

This repository includes abstract base contracts for implementing private vaults:

### PrivateVaultBasePoseidon2.sol

Abstract contract providing private deposit/withdrawal functionality using Poseidon2:
- `_privateDeposit(bytes32 commitment)`: Internal function to add commitments to Merkle tree
- `_privateWithdraw(proof, merkleRoot, nullifierHash, recipient)`: Internal function to verify proofs and mark nullifiers as spent
- Extends `Poseidon2MerkleTree` for incremental Merkle tree with 31-level depth
- Uses Poseidon2 hash to match Noir circuit exactly
- Tracks spent nullifiers to prevent double spends
- Maintains root history for allowing recent roots

### Poseidon2.sol

**IMPORTANT**: This is a placeholder library. You must replace it with actual Poseidon2 implementation:

**Option 1 - Generate from Noir (Recommended)**:
```bash
cd scripts
npm install
node generate_poseidon2.js
```
This generates test vectors from Barretenberg. Then implement Poseidon2.sol to match these test vectors.

**Option 2 - Use existing library**:
Use a verified Poseidon2 Solidity library that matches Noir's parameters (BN254, rate=2).

### ExamplePrivateVault.sol

Example implementation showing how to use `PrivateVaultBase`:
- Public `deposit()` function for ETH deposits
- Public `withdraw()` function for ETH withdrawals
- Extends the base contract with your custom logic

### Usage

Extend `PrivateVaultBase` for your own vault implementations, make sure to include nonReentrant guard to prevent reentracy attacks.

```solidity
contract MyVault is PrivateVaultBase, ReentrancyGuard {
    constructor(address _verifier) PrivateVaultBase(_verifier) {}

    function deposit(bytes32 commitment) external payable nonReentrant {
        // Your custom deposit logic
        _privateDeposit(commitment);
    }

    function withdraw(
        bytes calldata proof,
        bytes32 nullifierHash,
        address payable recipient,
        bytes32 rootToProve
    ) external nonReentrant {
        _privateWithdraw(proof, nullifierHash, recipient, rootToProve);
        // Your custom withdrawal logic
    }
}
```

## Security Considerations

- **Merkle Tree Depth**: Set to 31 levels (supports up to 2^31 = ~2 billion deposits)
- **Nullifier Safety**: Never reuse nullifiers across deposits
- **Secret Management**: Keep nullifier and secret private; loss means loss of funds
- **Trusted Setup**: Noir uses a universal trusted setup (no ceremony needed)
- **Hash Function Compatibility**: CRITICAL - Poseidon2 implementation in Solidity MUST match Noir's implementation exactly
  - Generate test vectors using `scripts/generate_poseidon2.js`
  - Verify Solidity implementation matches test vectors before deployment
  - Mismatched hash implementations will cause all withdrawals to fail

## File Structure

- `src/main.nr`: Main Noir circuit implementation
- `Nargo.toml`: Noir project configuration
- `Prover.toml`: Input values for proof generation (create this)
- `contracts/src/`:
  - `PrivateVaultBasePoseidon2.sol`: Abstract base contract using Poseidon2
  - `Poseidon2MerkleTree.sol`: Incremental Merkle tree with Poseidon2
  - `Poseidon2.sol`: Poseidon2 hash library (needs implementation)
  - `ExamplePrivateVault.sol`: Example vault implementation
  - `UltraVerifier.sol`: Generated Solidity verifier (after running bb)
- `scripts/`:
  - `generate_commitment.js`: Utility to generate commitments using Poseidon2
  - `generate_poseidon2.js`: Generate Poseidon2 test vectors
  - `package.json`: Node.js dependencies
- `target/`: Compiled circuit artifacts

## Circuit Parameters

- Tree Depth: 31 levels (~2 billion deposits)
- Hash Function: Poseidon2 (efficient in ZK circuits, matches Solidity implementation)
- Field: BN254 curve (Ethereum-compatible)

## Next Steps

1. Run `nargo test` to verify circuit logic
2. Run `nargo codegen-verifier` to generate Solidity verifier
3. Deploy verifier contract to Ethereum
4. Build vault contract that uses the verifier
5. Create frontend for deposit/withdrawal UX
# CUM-Circuit
