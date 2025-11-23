#!/usr/bin/env node

/**
 * Fetch Merkle path from a deployed PrivateVault contract
 *
 * Usage:
 *   node fetch_merkle_path.js <VAULT_ADDRESS> <TOKEN_ADDRESS> <LEAF_INDEX> <RPC_URL>
 *
 * Example:
 *   node fetch_merkle_path.js 0x1234... 0x0 5 https://mainnet.base.org
 */

const { ethers } = require('ethers');

// Minimal ABI for the functions we need
const VAULT_ABI = [
  'function getMerklePath(address token, uint256 leafIndex) view returns (uint256[] pathIndices, bytes32[] pathElements)',
  'function getCurrentRoot(address token) view returns (bytes32)',
  'function getCurrentLeafIndex(address token) view returns (uint256)',
  'function getTreeDepth(address token) view returns (uint256)'
];

async function fetchMerklePath(vaultAddress, tokenAddress, leafIndex, rpcUrl) {
  console.log('=== Merkle Path Fetcher ===\n');

  // Connect to provider
  const provider = new ethers.JsonRpcProvider(rpcUrl);

  // Create contract instance
  const vault = new ethers.Contract(vaultAddress, VAULT_ABI, provider);

  try {
    // Get tree depth
    console.log('Querying vault...');
    const treeDepth = await vault.getTreeDepth(tokenAddress);
    console.log(`Tree Depth: ${treeDepth}\n`);

    // Get current leaf index to verify
    const currentLeafIndex = await vault.getCurrentLeafIndex(tokenAddress);
    console.log(`Current Leaf Index: ${currentLeafIndex}`);

    if (BigInt(leafIndex) >= BigInt(currentLeafIndex)) {
      console.error(`\nError: Leaf index ${leafIndex} is out of bounds (max: ${currentLeafIndex - 1n})`);
      process.exit(1);
    }

    // Get merkle root
    const merkleRoot = await vault.getCurrentRoot(tokenAddress);
    console.log(`Current Root: ${merkleRoot}\n`);

    // Fetch the Merkle path
    console.log(`Fetching Merkle path for leaf index ${leafIndex}...`);
    const [pathIndices, pathElements] = await vault.getMerklePath(tokenAddress, leafIndex);

    console.log('\n=== Merkle Path Retrieved ===\n');

    // Format for Prover.toml
    console.log('# For Prover.toml:');
    console.log('path_indices = [');
    pathIndices.forEach((idx, i) => {
      const comma = i < pathIndices.length - 1 ? ',' : '';
      console.log(`  "${idx}"${comma}`);
    });
    console.log(']');

    console.log('\npath_elements = [');
    pathElements.forEach((elem, i) => {
      const comma = i < pathElements.length - 1 ? ',' : '';
      // Convert to hex without 0x prefix for Prover.toml
      const hexValue = BigInt(elem).toString(16).padStart(64, '0');
      console.log(`  "0x${hexValue}"${comma}`);
    });
    console.log(']');

    console.log(`\nmerkle_root = "${merkleRoot}"`);

    console.log('\n=== Summary ===');
    console.log(`Vault: ${vaultAddress}`);
    console.log(`Token: ${tokenAddress}`);
    console.log(`Leaf Index: ${leafIndex}`);
    console.log(`Tree Depth: ${treeDepth}`);
    console.log(`Merkle Root: ${merkleRoot}`);

  } catch (error) {
    console.error('\nError fetching Merkle path:');

    if (error.message.includes('call revert exception')) {
      console.error('Contract call failed. Possible reasons:');
      console.error('  - Vault address is incorrect');
      console.error('  - Contract does not have getMerklePath function (needs to be upgraded)');
      console.error('  - RPC endpoint is not responding');
    } else {
      console.error(error.message);
    }

    process.exit(1);
  }
}

// Main execution
if (require.main === module) {
  const args = process.argv.slice(2);

  if (args.length < 4) {
    console.log('Usage: node fetch_merkle_path.js <VAULT_ADDRESS> <TOKEN_ADDRESS> <LEAF_INDEX> <RPC_URL>');
    console.log('');
    console.log('Arguments:');
    console.log('  VAULT_ADDRESS  - Address of the deployed PrivateVault contract');
    console.log('  TOKEN_ADDRESS  - Token address (use 0x0000000000000000000000000000000000000000 for ETH)');
    console.log('  LEAF_INDEX     - Index of your commitment in the tree (from deposit event)');
    console.log('  RPC_URL        - RPC endpoint URL');
    console.log('');
    console.log('Examples:');
    console.log('  # For Base mainnet');
    console.log('  node fetch_merkle_path.js 0x1234... 0x0 5 https://mainnet.base.org');
    console.log('');
    console.log('  # For Base Sepolia testnet');
    console.log('  node fetch_merkle_path.js 0x1234... 0x0 5 https://sepolia.base.org');
    console.log('');
    console.log('  # For local Anvil');
    console.log('  node fetch_merkle_path.js 0x1234... 0x0 5 http://localhost:8545');
    console.log('');
    console.log('Tips:');
    console.log('  - Get LEAF_INDEX from your deposit transaction logs (leafIndex field)');
    console.log('  - Or query: cast call $VAULT "getCurrentLeafIndex(address)" $TOKEN --rpc-url $RPC');
    console.log('  - Your leaf index = current leaf index - 1 (if you were the last depositor)');
    process.exit(1);
  }

  const [vaultAddress, tokenAddress, leafIndex, rpcUrl] = args;

  fetchMerklePath(vaultAddress, tokenAddress, leafIndex, rpcUrl)
    .then(() => process.exit(0))
    .catch(error => {
      console.error('Unexpected error:', error);
      process.exit(1);
    });
}

module.exports = { fetchMerklePath };
