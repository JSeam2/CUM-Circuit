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

### Installation
1. Install noirup and use the following version
```bash
noirup --version 1.0.0-beta.14
```

2. Install bbup and use the following version
```bash
bbup --version 3.0.0-nightly.20251030-2
```

3. Install bb.js
```bash
pnpm install
```

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
bb write_vk -b ./target/cum_circuit.json -o ./target --oracle_hash keccak
bb write_solidity_verifier -k ./target/vk -o ./target/Verifier.sol
```

### Quick Start: Helper Scripts

We provide helper scripts to streamline the workflow:

#### Option 1: Complete Workflow Helper

```bash
# Interactive workflow for the complete process
./workflow.sh full-workflow
```

This guides you through:
1. Generating commitment
2. Depositing to vault
3. Preparing proof inputs
4. Generating proof

#### Option 2: Individual Commands

**Generate Commitment:**
```bash
cd ./contracts

# Generate with random values
forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run()"

# Generate with specific values
forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run(uint256,uint256)" 11111111 22222222
```

**Prepare Prover.toml:**
You may also populate Prover.toml directly
```bash
# Interactive helper
./workflow.sh prepare-proof
```

**Generate Proof:**
```bash
# Generate proof from Prover.toml
./workflow.sh prove

# Or use the script directly
./generate_proof.sh
```

### Manual Process: Creating Commitments and Proofs

If you prefer to do things manually:

#### 1. Generate a Commitment (for deposit)

Use the forge script to generate commitments:

```bash
cd contracts
forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run()"
```

This will output:
- `secret`: Keep this PRIVATE!
- `nullifier`: Keep this PRIVATE!
- `commitment`: Submit this to the contract's deposit function
- `nullifier_hash`: Used later for withdrawal proof

#### 2. Create Prover.toml

Create `Prover.toml` with your private inputs:

```toml
# Private inputs (kept secret)
secret = "0xa98ac7"
nullifier = "0x153158e"
path_indices = ["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]
path_elements = ["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]

# Public inputs (visible to everyone)
merkle_root = "0x11e9f7f14277f0e660ab3721d67ae3341f351b9fc8a9f10a0bc76b74835d1c6f"
nullifier_hash = "0x08f38ef6f469742cf38723ea167d6a503a669fc7c2ade5bc3f69cbb93877c770"
recipient = "0x1234567890"
relayer = "0x0"
fee = "0x0"
```

**Notes:**
- For a commitment at index 0 in the tree, use all zeros for `path_indices` and `path_elements`
- `merkle_root` should be obtained from the vault contract after depositing
- `nullifier_hash` can be computed using the forge script or from the circuit

#### 3. Generate the Proof

```bash
# Compile circuit
nargo compile

# Execute witness
nargo execute witness

# Generate proof with bb
bb prove -b ./target/cum_circuit.json -w ./target/witness.gz -o ./target --oracle_hash keccak

# Convert to hex
xxd -p ./target/proof | tr -d '\n' > proof.hex

# Or use bb.js (generates human-readable output)
node prove.js
```

#### 4. Verify the Proof (optional, for testing)

```bash
bb verify -p ./target/proof -k ./target/vk --oracle_hash keccak
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

## Security Considerations

- **Merkle Tree Depth**: Set to 31 levels (supports up to 2^31 = ~2 billion deposits)
- **Nullifier Safety**: Never reuse nullifiers across deposits
- **Secret Management**: Keep nullifier and secret private; loss means loss of funds
- **Trusted Setup**: Noir uses a universal trusted setup (no ceremony needed)
- **Hash Function Compatibility**: CRITICAL - Poseidon2 implementation in Solidity MUST match Noir's implementation exactly
  - Generate test vectors using `scripts/generate_poseidon2.js`
  - Verify Solidity implementation matches test vectors before deployment
  - Mismatched hash implementations will cause all withdrawals to fail
