#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Complete workflow script for private vault operations
# Usage: ./workflow.sh [command]
# Commands:
#   generate-commitment [secret] [nullifier]  - Generate commitment from secret and nullifier
#   prepare-proof                              - Helper to prepare Prover.toml
#   prove                                      - Generate ZK proof
#   help                                       - Show this help

set -e

function show_help() {
    echo -e "${BLUE}=== Private Vault Workflow Script ===${NC}"
    echo ""
    echo "Commands:"
    echo "  ${GREEN}generate-commitment [secret] [nullifier]${NC}"
    echo "    Generate commitment and nullifier hash"
    echo "    If secret/nullifier not provided, generates random values"
    echo ""
    echo "  ${GREEN}prepare-proof${NC}"
    echo "    Interactive helper to prepare Prover.toml file"
    echo ""
    echo "  ${GREEN}prove${NC}"
    echo "    Generate ZK proof from Prover.toml"
    echo ""
    echo "  ${GREEN}full-workflow${NC}"
    echo "    Complete workflow: commitment -> deposit -> proof"
    echo ""
    echo "Examples:"
    echo "  ./workflow.sh generate-commitment"
    echo "  ./workflow.sh generate-commitment 11111111 22222222"
    echo "  ./workflow.sh prepare-proof"
    echo "  ./workflow.sh prove"
}

function generate_commitment() {
    echo -e "${CYAN}=== Generating Commitment ===${NC}"
    echo ""

    cd contracts

    if [ -z "$1" ] || [ -z "$2" ]; then
        echo -e "${YELLOW}Generating random secret and nullifier...${NC}"
        forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run()" --silent
    else
        echo -e "${YELLOW}Using provided values...${NC}"
        forge script script/GenerateCommitment.s.sol:GenerateCommitment -s "run(uint256,uint256)" "$1" "$2" --silent
    fi

    cd ..
}

function prepare_proof() {
    echo -e "${CYAN}=== Preparing Prover.toml ===${NC}"
    echo ""
    echo "This helper will guide you through creating a Prover.toml file."
    echo ""

    # Ask for inputs
    read -p "Enter secret (hex, e.g., 0xa98ac7): " SECRET
    read -p "Enter nullifier (hex, e.g., 0x153158e): " NULLIFIER
    read -p "Enter merkle_root (hex): " MERKLE_ROOT
    read -p "Enter nullifier_hash (hex): " NULLIFIER_HASH
    read -p "Enter recipient address (hex): " RECIPIENT
    read -p "Enter relayer address (hex, or 0x0 for none): " RELAYER
    read -p "Enter fee (hex, or 0x0 for none): " FEE

    # Ask about merkle path
    echo ""
    echo "For a commitment at index 0 in an empty tree, use all zeros."
    read -p "Is your commitment at index 0? (y/n): " IS_INDEX_ZERO

    if [ "$IS_INDEX_ZERO" = "y" ]; then
        PATH_INDICES='["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]'
        PATH_ELEMENTS='["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"]'
    else
        echo "Please enter path_indices (20 values: 0 or 1)"
        read -p "path_indices (JSON array): " PATH_INDICES
        echo "Please enter path_elements (20 hex values)"
        read -p "path_elements (JSON array): " PATH_ELEMENTS
    fi

    # Create Prover.toml
    cat > Prover.toml << EOF
# Private inputs (kept secret)
secret = "${SECRET}"
nullifier = "${NULLIFIER}"
path_indices = ${PATH_INDICES}
path_elements = ${PATH_ELEMENTS}

# Public inputs (visible to everyone)
merkle_root = "${MERKLE_ROOT}"
nullifier_hash = "${NULLIFIER_HASH}"
recipient = "${RECIPIENT}"
relayer = "${RELAYER}"
fee = "${FEE}"
EOF

    echo ""
    echo -e "${GREEN}Prover.toml created successfully!${NC}"
    echo ""
    echo "Contents:"
    cat Prover.toml
}

function prove() {
    echo -e "${CYAN}=== Generating Proof ===${NC}"
    echo ""

    if [ ! -f "./generate_proof.sh" ]; then
        echo -e "${RED}Error: generate_proof.sh not found!${NC}"
        exit 1
    fi

    ./generate_proof.sh
}

function full_workflow() {
    echo -e "${BLUE}=== Complete Private Vault Workflow ===${NC}"
    echo ""
    echo -e "${YELLOW}This will guide you through:${NC}"
    echo "  1. Generate commitment"
    echo "  2. Show how to deposit"
    echo "  3. Prepare proof inputs"
    echo "  4. Generate proof"
    echo ""
    read -p "Continue? (y/n): " CONTINUE

    if [ "$CONTINUE" != "y" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo -e "${GREEN}Step 1: Generate Commitment${NC}"
    generate_commitment

    echo ""
    echo -e "${YELLOW}Step 2: Deposit${NC}"
    echo "Use the commitment from Step 1 to call the deposit function on your vault contract."
    echo "Example: vault.deposit{value: 1 ether}(commitment)"
    echo ""
    read -p "Press enter after you've deposited..."

    echo ""
    echo -e "${GREEN}Step 3: Get Merkle Root${NC}"
    echo "Get the current merkle root from the vault after your deposit."
    echo "Example: cast call \$VAULT \"getCurrentRoot(address)\" \$TOKEN"
    echo ""

    echo ""
    echo -e "${GREEN}Step 4: Prepare Proof${NC}"
    prepare_proof

    echo ""
    echo -e "${GREEN}Step 5: Generate Proof${NC}"
    prove

    echo ""
    echo -e "${BLUE}=== Workflow Complete! ===${NC}"
    echo "You can now use the generated proof to withdraw from the vault."
}

# Main
COMMAND=${1:-help}

case $COMMAND in
    generate-commitment)
        generate_commitment "$2" "$3"
        ;;
    prepare-proof)
        prepare_proof
        ;;
    prove)
        prove
        ;;
    full-workflow)
        full_workflow
        ;;
    help|*)
        show_help
        ;;
esac
