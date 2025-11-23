#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script to generate ZK proof for withdrawal
# Usage: ./generate_proof.sh

set -e

echo -e "${BLUE}=== ZK Proof Generation Script ===${NC}"
echo ""

# Check if Prover.toml exists
if [ ! -f "Prover.toml" ]; then
    echo -e "${RED}Error: Prover.toml not found!${NC}"
    echo "Please create Prover.toml with your proof inputs."
    echo ""
    echo "Example Prover.toml:"
    echo "===================="
    cat << EOF
secret = "0x0a98ac7"
nullifier = "0x0153158e"
path_indices = ["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]
path_elements = ["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]
merkle_root = "0x11e9f7f14277f0e660ab3721d67ae3341f351b9fc8a9f10a0bc76b74835d1c6f"
nullifier_hash = "0x08f38ef6f469742cf38723ea167d6a503a669fc7c2ade5bc3f69cbb93877c770"
recipient = "0x1234567890"
relayer = "0x0"
fee = "0x0"
EOF
    echo "===================="
    exit 1
fi

echo -e "${GREEN}Step 1: Compiling circuit...${NC}"
if ! command -v nargo &> /dev/null; then
    echo -e "${RED}Error: nargo not found!${NC}"
    echo "Please install Noir: https://noir-lang.org/docs/getting_started/installation/"
    exit 1
fi

nargo compile

echo ""
echo -e "${GREEN}Step 2: Executing witness...${NC}"
nargo execute witness

echo ""
echo -e "${GREEN}Step 3: Generating proof with bb (Barretenberg)...${NC}"
if ! command -v bb &> /dev/null; then
    echo -e "${YELLOW}Warning: bb not found. Trying with bb.js...${NC}"

    # Check if node and bb.js are available
    if ! command -v node &> /dev/null; then
        echo -e "${RED}Error: node not found!${NC}"
        echo "Please install Node.js or bb (Barretenberg CLI)"
        exit 1
    fi

    if [ ! -f "prove.js" ]; then
        echo -e "${RED}Error: prove.js not found!${NC}"
        exit 1
    fi

    echo -e "${GREEN}Using node prove.js...${NC}"
    node prove.js | tee proof_output.txt

    echo ""
    echo -e "${GREEN}Proof generation complete!${NC}"
    echo -e "${YELLOW}Note: When using prove.js, the proof is printed to console.${NC}"
    echo -e "${YELLOW}Check proof_output.txt for the output.${NC}"
else
    # Using bb CLI
    bb prove -b ./target/cum_circuit.json -w ./target/witness.gz -o ./target --oracle_hash keccak

    echo ""
    echo -e "${GREEN}Step 4: Converting proof to hex...${NC}"
    PROOF_HEX=$(xxd -p ./target/proof | tr -d '\n')

    echo ""
    echo -e "${GREEN}=== Proof Generated Successfully! ===${NC}"
    echo ""
    echo -e "${BLUE}Proof (hex):${NC}"
    echo "$PROOF_HEX"
    echo ""
    echo -e "${BLUE}Proof length:${NC} $((${#PROOF_HEX} / 2)) bytes"
    echo ""

    # Read public inputs
    echo -e "${BLUE}Public inputs:${NC}"
    xxd -p ./target/public_inputs | tr -d '\n'
    echo ""
    echo ""

    # Save to file for easy access
    echo "$PROOF_HEX" > proof.hex
    echo -e "${GREEN}Proof saved to: proof.hex${NC}"
fi

echo ""
echo -e "${BLUE}=== Next Steps ===${NC}"
echo "1. Use this proof in your smart contract withdrawal function"
echo "2. Make sure to include all public inputs (merkle_root, nullifier_hash, recipient, relayer, fee)"
echo ""
echo -e "${GREEN}Optional: Verify proof locally${NC}"
echo "  bb verify -p ./target/proof -k ./target/vk --oracle_hash keccak"
