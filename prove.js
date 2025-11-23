const UltraHonkBackend = require('@aztec/bb.js').UltraHonkBackend;
const path = require('node:path');
const fs = require('fs');

function uint8ArrayToHexString(uint8Array) {
  return Array.from(uint8Array)
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
}

async function main() {
    // Load circuit bytecode (from Noir compiler output)
    const circuitPath = path.join(__dirname, './target/cum_circuit.json');
    const circuitJson = JSON.parse(fs.readFileSync(circuitPath, 'utf8'));
    const bytecode = circuitJson.bytecode;

    // Load witness data
    const witnessPath = path.join(__dirname, 'target/witness.gz');
    const witnessBuffer = fs.readFileSync(witnessPath);

    // Initialize backend
    const backend = new UltraHonkBackend(bytecode);

    // Generate proof with Keccak for EVM verification
    const proofData = await backend.generateProof(witnessBuffer, {
    keccak: true
    });

    const proof = uint8ArrayToHexString(proofData.proof);
    console.log("proof:", proof);
    console.log("publicInputs:", proofData.publicInputs);
}

main()