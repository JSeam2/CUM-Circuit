// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PrivateVault.sol";
import {PoseidonT3} from "../src/Poseidon.sol";
import {IVerifier, HonkVerifier} from "../src/WithdrawalVerifier.sol";

// Mock withdrawal verifier that always returns true for testing
contract MockWithdrawalVerifier is IVerifier {
    bool public shouldSucceed = true;

    function verify(bytes calldata, bytes32[] calldata) external view override returns (bool) {
        return shouldSucceed;
    }

    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }
}

// Concrete implementation of PrivateVault for testing
contract TestPrivateVault is PrivateVault {
    IVerifier public withdrawalVerifier;

    constructor(
        address _withdrawalVerifier,
        uint256 _treeDepth,
        bytes32[] memory _initialRoots,
        address[] memory _tokenAddresses,
        uint256[] memory _denominations
    ) PrivateVault(
        _treeDepth,
        _initialRoots,
        _tokenAddresses,
        _denominations
    ) {
        withdrawalVerifier = IVerifier(_withdrawalVerifier);
    }

    // Expose internal function for testing
    function privateDeposit(address token, bytes32 commitment) external {
        _privateDeposit(token, commitment);
    }

    // Expose internal function for testing
    function privateWithdraw(
        bytes calldata proof,
        address token,
        bytes32 merkleRoot,
        bytes32 nullifierHash,
        address recipient,
        address relayer,
        uint256 fee
    ) external {
        _privateWithdraw(withdrawalVerifier, proof, token, merkleRoot, nullifierHash, recipient, relayer, fee);
    }
}

contract PrivateVaultTest is Test {
    MockWithdrawalVerifier public withdrawalVerifier;
    TestPrivateVault public vault;

    uint256 constant TREE_DEPTH = 20;
    address constant ETH_TOKEN = address(0);
    address constant TEST_TOKEN = address(0x1);
    uint256 constant DENOMINATION = 1 ether;

    bytes32 constant ZERO_VALUE = bytes32(0);

    function setUp() public {
        // Deploy mock verifier
        withdrawalVerifier = new MockWithdrawalVerifier();

        // Setup initial roots (one for ETH, one for TEST_TOKEN)
        bytes32[] memory initialRoots = new bytes32[](2);
        initialRoots[0] = _computeEmptyRoot();
        initialRoots[1] = _computeEmptyRoot();

        // Setup token addresses
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = ETH_TOKEN;
        tokenAddresses[1] = TEST_TOKEN;

        // Setup denominations
        uint256[] memory denominations = new uint256[](2);
        denominations[0] = DENOMINATION;
        denominations[1] = DENOMINATION;

        // Deploy vault
        vault = new TestPrivateVault(
            address(withdrawalVerifier),
            TREE_DEPTH,
            initialRoots,
            tokenAddresses,
            denominations
        );
    }

    // Helper: Compute the empty tree root
    function _computeEmptyRoot() internal pure returns (bytes32) {
        bytes32 currentHash = ZERO_VALUE;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            uint[2] memory inputs = [uint256(currentHash), uint256(currentHash)];
            currentHash = bytes32(PoseidonT3.hash(inputs));
        }
        return currentHash;
    }


    function testDeposit_SingleCommitment() public {
        bytes32 commitment = bytes32(uint256(12345));

        bytes32 oldRoot = vault.getCurrentRoot(ETH_TOKEN);
        uint256 oldLeafIndex = vault.getCurrentLeafIndex(ETH_TOKEN);

        // Perform deposit
        vault.privateDeposit(ETH_TOKEN, commitment);

        // Check that root changed
        bytes32 newRoot = vault.getCurrentRoot(ETH_TOKEN);
        assertNotEq(newRoot, oldRoot, "Root should change after deposit");

        // Check that leaf index incremented
        uint256 newLeafIndex = vault.getCurrentLeafIndex(ETH_TOKEN);
        assertEq(newLeafIndex, oldLeafIndex + 1, "Leaf index should increment");

        // Check that commitment is marked as used
        assertTrue(vault.isCommitmentUsed(ETH_TOKEN, commitment), "Commitment should be marked as used");

        // Check that new root is in known roots
        assertTrue(vault.isKnownRoot(ETH_TOKEN, newRoot), "New root should be known");

        // Check root history length
        assertEq(vault.getRootHistoryLength(ETH_TOKEN), 2, "Root history should have 2 entries");
    }

    function testDeposit_MultipleCommitments() public {
        bytes32[] memory commitments = new bytes32[](5);
        commitments[0] = bytes32(uint256(1));
        commitments[1] = bytes32(uint256(2));
        commitments[2] = bytes32(uint256(3));
        commitments[3] = bytes32(uint256(4));
        commitments[4] = bytes32(uint256(5));

        bytes32[] memory roots = new bytes32[](5);

        for (uint256 i = 0; i < commitments.length; i++) {
            vault.privateDeposit(ETH_TOKEN, commitments[i]);
            roots[i] = vault.getCurrentRoot(ETH_TOKEN);

            // Each root should be different
            if (i > 0) {
                assertNotEq(roots[i], roots[i-1], "Each deposit should produce different root");
            }

            // Check leaf index
            assertEq(vault.getCurrentLeafIndex(ETH_TOKEN), i + 1, "Leaf index should increment correctly");

            // Check commitment is marked as used
            assertTrue(vault.isCommitmentUsed(ETH_TOKEN, commitments[i]), "Commitment should be marked as used");
        }

        // Check that all roots are in history
        assertEq(vault.getRootHistoryLength(ETH_TOKEN), 6, "Root history should have 6 entries (initial + 5 deposits)");

        // Check that all roots are known
        for (uint256 i = 0; i < roots.length; i++) {
            assertTrue(vault.isKnownRoot(ETH_TOKEN, roots[i]), "All roots should be known");
        }
    }

    function testDeposit_DifferentTokens() public {
        bytes32 commitment1 = bytes32(uint256(111));
        bytes32 commitment2 = bytes32(uint256(222));

        // Deposit to ETH vault
        vault.privateDeposit(ETH_TOKEN, commitment1);
        bytes32 ethRoot = vault.getCurrentRoot(ETH_TOKEN);

        // Deposit to TEST_TOKEN vault
        vault.privateDeposit(TEST_TOKEN, commitment2);
        bytes32 tokenRoot = vault.getCurrentRoot(TEST_TOKEN);

        // Roots should be different
        assertNotEq(ethRoot, tokenRoot, "Different token vaults should have different roots");

        // Check leaf indices
        assertEq(vault.getCurrentLeafIndex(ETH_TOKEN), 1, "ETH vault should have 1 leaf");
        assertEq(vault.getCurrentLeafIndex(TEST_TOKEN), 1, "Token vault should have 1 leaf");

        // Check commitments are in correct vaults
        assertTrue(vault.isCommitmentUsed(ETH_TOKEN, commitment1), "Commitment1 should be in ETH vault");
        assertTrue(vault.isCommitmentUsed(TEST_TOKEN, commitment2), "Commitment2 should be in token vault");
        assertFalse(vault.isCommitmentUsed(ETH_TOKEN, commitment2), "Commitment2 should not be in ETH vault");
        assertFalse(vault.isCommitmentUsed(TEST_TOKEN, commitment1), "Commitment1 should not be in token vault");
    }

    function testDeposit_RevertZeroCommitment() public {
        vm.expectRevert(PrivateVault.InvalidCommitment.selector);
        vault.privateDeposit(ETH_TOKEN, bytes32(0));
    }

    function testDeposit_RevertDuplicateCommitment() public {
        bytes32 commitment = bytes32(uint256(12345));

        // First deposit should succeed
        vault.privateDeposit(ETH_TOKEN, commitment);

        // Second deposit with same commitment should revert
        vm.expectRevert(PrivateVault.CommitmentAlreadyUsed.selector);
        vault.privateDeposit(ETH_TOKEN, commitment);
    }

    function testDeposit_CommitmentCanBeUsedInDifferentVaults() public {
        bytes32 commitment = bytes32(uint256(12345));

        // Deposit same commitment to both vaults should succeed
        vault.privateDeposit(ETH_TOKEN, commitment);
        vault.privateDeposit(TEST_TOKEN, commitment);

        // Both should be marked as used in their respective vaults
        assertTrue(vault.isCommitmentUsed(ETH_TOKEN, commitment));
        assertTrue(vault.isCommitmentUsed(TEST_TOKEN, commitment));
    }

    function testDeposit_RootHistory() public {
        uint256 numDeposits = 35; // More than ROOT_HISTORY_SIZE (30)

        bytes32[] memory allRoots = new bytes32[](numDeposits);

        for (uint256 i = 0; i < numDeposits; i++) {
            bytes32 commitment = bytes32(uint256(i + 1));
            vault.privateDeposit(ETH_TOKEN, commitment);
            allRoots[i] = vault.getCurrentRoot(ETH_TOKEN);
        }

        // Root history array grows (not capped), but old roots are removed from knownRoots
        uint256 historyLength = vault.getRootHistoryLength(ETH_TOKEN);
        assertEq(historyLength, numDeposits + 1, "Root history array should contain all roots + initial");

        // Recent roots (last 30) should still be known
        for (uint256 i = numDeposits - 30; i < numDeposits; i++) {
            assertTrue(
                vault.isKnownRoot(ETH_TOKEN, allRoots[i]),
                "Recent roots should still be known"
            );
        }

        // Old roots should not be known anymore (expired from knownRoots)
        // First few roots should be expired
        assertFalse(
            vault.isKnownRoot(ETH_TOKEN, allRoots[0]),
            "Very old root should not be known"
        );
        assertFalse(
            vault.isKnownRoot(ETH_TOKEN, allRoots[1]),
            "Old root should not be known"
        );
    }

    function testDeposit_PoseidonHashIsUsed() public {
        // This test verifies that PoseidonT3 hash produces deterministic results
        bytes32 commitment1 = bytes32(uint256(100));
        bytes32 commitment2 = bytes32(uint256(100)); // Same commitment

        // Deploy a second vault with same parameters
        bytes32[] memory initialRoots = new bytes32[](1);
        initialRoots[0] = _computeEmptyRoot();
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = ETH_TOKEN;
        uint256[] memory denominations = new uint256[](1);
        denominations[0] = DENOMINATION;

        TestPrivateVault vault2 = new TestPrivateVault(
            address(withdrawalVerifier),
            TREE_DEPTH,
            initialRoots,
            tokenAddresses,
            denominations
        );

        // Deposit same commitment to both vaults
        vault.privateDeposit(ETH_TOKEN, commitment1);
        vault2.privateDeposit(ETH_TOKEN, commitment2);

        // Roots should be the same (deterministic)
        assertEq(
            vault.getCurrentRoot(ETH_TOKEN),
            vault2.getCurrentRoot(ETH_TOKEN),
            "Same commitment should produce same root"
        );
    }

    function testFuzz_Deposit(bytes32 commitment) public {
        // Fuzz test with random commitments
        vm.assume(commitment != bytes32(0)); // Exclude zero commitment

        uint256 leafIndexBefore = vault.getCurrentLeafIndex(ETH_TOKEN);
        bytes32 rootBefore = vault.getCurrentRoot(ETH_TOKEN);

        vault.privateDeposit(ETH_TOKEN, commitment);

        uint256 leafIndexAfter = vault.getCurrentLeafIndex(ETH_TOKEN);
        bytes32 rootAfter = vault.getCurrentRoot(ETH_TOKEN);

        // Assertions
        assertEq(leafIndexAfter, leafIndexBefore + 1, "Leaf index should increment");
        assertNotEq(rootAfter, rootBefore, "Root should change");
        assertTrue(vault.isCommitmentUsed(ETH_TOKEN, commitment), "Commitment should be used");
        assertTrue(vault.isKnownRoot(ETH_TOKEN, rootAfter), "New root should be known");
    }
}

// Test contract for testing with real WithdrawalVerifier
contract PrivateVaultWithRealVerifierTest is Test {
    IVerifier public withdrawalVerifier;
    TestPrivateVault public vault;

    uint256 constant TREE_DEPTH = 20;
    address constant ETH_TOKEN = address(0);
    uint256 constant DENOMINATION = 1 ether;

    bytes32 constant ZERO_VALUE = bytes32(0);

    function setUp() public {
        // Deploy real verifier
        withdrawalVerifier = new HonkVerifier();

        // Setup initial roots
        bytes32[] memory initialRoots = new bytes32[](1);
        initialRoots[0] = _computeEmptyRoot();

        // Setup token addresses
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = ETH_TOKEN;

        // Setup denominations
        uint256[] memory denominations = new uint256[](1);
        denominations[0] = DENOMINATION;

        // Deploy vault
        vault = new TestPrivateVault(
            address(withdrawalVerifier),
            TREE_DEPTH,
            initialRoots,
            tokenAddresses,
            denominations
        );

        // Fund the vault with ETH for withdrawals
        vm.deal(address(vault), 100 ether);
    }

    // Helper: Compute the empty tree root
    function _computeEmptyRoot() internal pure returns (bytes32) {
        bytes32 currentHash = ZERO_VALUE;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            uint[2] memory inputs = [uint256(currentHash), uint256(currentHash)];
            currentHash = bytes32(PoseidonT3.hash(inputs));
        }
        return currentHash;
    }

    // Helper: Compute commitment hash (matches the circuit)
    function _computeCommitment(uint256 secret, uint256 nullifier) internal pure returns (bytes32) {
        uint[2] memory inputs = [secret, nullifier];
        return bytes32(PoseidonT3.hash(inputs));
    }

    // Helper: Compute nullifier hash (matches the circuit)
    function _computeNullifierHash(uint256 nullifier) internal pure returns (bytes32) {
        uint[2] memory inputs = [nullifier, 0];
        return bytes32(PoseidonT3.hash(inputs));
    }

    // Helper: Compute merkle root for a single commitment at index 0
    function _computeMerkleRoot(bytes32 commitment) internal pure returns (bytes32) {
        bytes32 currentHash = commitment;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            uint[2] memory inputs = [uint256(currentHash), 0];
            currentHash = bytes32(PoseidonT3.hash(inputs));
        }
        return currentHash;
    }

    // Test withdrawal with real verifier
    // This test will use proof data generated from the Noir circuit
    function testWithdraw_WithRealVerifier() public {
        // Circuit inputs (these match what's in the Noir test)
        uint256 secret = 11111111;
        uint256 nullifier = 22222222;

        // Compute commitment
        bytes32 commitment = _computeCommitment(secret, nullifier);
        console.log("Commitment:");
        console.logBytes32(commitment);
        // Expected: 0x027d41a203035596e96fda110d73edf92d17ca4c60b28bf72b0f2bc593f226eb

        // Compute nullifier hash
        bytes32 nullifierHash = _computeNullifierHash(nullifier);
        console.log("Nullifier Hash:");
        console.logBytes32(nullifierHash);

        // Compute merkle root (commitment at index 0, all siblings are 0)
        bytes32 merkleRoot = _computeMerkleRoot(commitment);
        console.log("Merkle Root:");
        console.logBytes32(merkleRoot);

        // Deposit the commitment first
        vault.privateDeposit(ETH_TOKEN, commitment);

        // Verify the root matches what we expect
        bytes32 vaultRoot = vault.getCurrentRoot(ETH_TOKEN);
        console.log("Vault Root:");
        console.logBytes32(vaultRoot);
        assertEq(vaultRoot, merkleRoot, "Vault root should match computed root");

        // Recipient and relayer
        address recipient = address(0x1234567890);
        address relayer = address(0);
        uint256 fee = 0;

        console.log("\n=== Test Values for Proof Generation ===");
        console.log("Use these values to generate the proof with: nargo prove");
        console.log("\nPrivate inputs:");
        console.log("secret =", secret);
        console.log("nullifier =", nullifier);
        console.log("path_indices = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]");
        console.log("path_elements = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]");
        console.log("\nPublic inputs:");
        console.log("merkle_root =", uint256(merkleRoot));
        console.log("nullifier_hash =", uint256(nullifierHash));
        console.log("recipient =", uint256(uint160(recipient)));
        console.log("relayer =", uint256(uint160(relayer)));
        console.log("fee =", fee);
        console.log("\n=== Copy these values to Prover.toml ===");
        console.log("secret = \"0x%x\"", secret);
        console.log("nullifier = \"0x%x\"", nullifier);
        console.log("merkle_root = \"0x%x\"", uint256(merkleRoot));
        console.log("nullifier_hash = \"0x%x\"", uint256(nullifierHash));
        console.log("recipient = \"0x%x\"", uint256(uint160(recipient)));
        console.log("relayer = \"0x%x\"", uint256(uint160(relayer)));
        console.log("fee = \"0x%x\"", fee);

        bytes memory proof = hex"0000000000000000000000000000000000000000000000042ab5d6d1986846cf00000000000000000000000000000000000000000000000b75c020998797da780000000000000000000000000000000000000000000000005a107acb64952eca000000000000000000000000000000000000000000000000000031e97a575e9d00000000000000000000000000000000000000000000000b5666547acf8bd5a400000000000000000000000000000000000000000000000c410db10a01750aeb00000000000000000000000000000000000000000000000d722669117f9758a4000000000000000000000000000000000000000000000000000178cbf4206471000000000000000000000000000000000000000000000000e91b8a11e7842c38000000000000000000000000000000000000000000000007fd51009034b3357f000000000000000000000000000000000000000000000009889939f81e9c74020000000000000000000000000000000000000000000000000000f94656a2ca48000000000000000000000000000000000000000000000006fb128b46c1ddb67f0000000000000000000000000000000000000000000000093fe27776f50224bd000000000000000000000000000000000000000000000004a0c80c0da527a0810000000000000000000000000000000000000000000000000001b52c2020d746137b5a6a54b3d7f3669280047373ccd1d26db0f7c27a4d361da72885168f566218e93ea0b5eddf6f78c63101f736374d5ac062417aa67bfbb49b3b6cecd447921f2629f0ae84a917d30ad85e35162a3fd634968835f2a623cf662e7e5d11110018687322159cdb468abdfd8384042b27923d285f9ce2890b0fabab5aabe7669c1c34ef15cca7d55142399b409615364ee7424665e77b6f6664528cae6cf12ebd229782393a8b72e9e8254ebc0a14a55b626a3f235e019259b19846ffc31252731c694dd8eb445d9cbe8664b2addc290e679399c2356693d71c34a622498f0df916c00e8fbcd3aab05cbdcc9318046d7820a641b4e2c8eba16546245cc90d01fd048d4b928102a496f2922072bb7eb5cf94780f0210ba33ebff7eda6bbb6c49331644dbf5be362714b82ddba4298b102c46ccb2f94741d0f13b50a88376c400292c48f389c71b4faf5c4949c986a1e556807a699b0ce43c68e4be090de9f0acf903a97984912af1b26253b0b004b46168c9edb792011064901dcac92efa70ce7711a57e63937d6652c2b42aa0bb4d0c158e87c9cdfc9d97bbaba3be80281f6a1023398e28c6ffef00b66a7a15831479c04db8ee0cf5329250a714fafa5203b8c2138b80cb54e33beee8aee4633f8db9991fd243504b1b791f5de18bfb688900bc212d8eb6a8845132ca390666ae14e6d9ce192a3ab10ceb7ebb9709ad50feee821ea73b1529f6f023d0d47f5fa09dea5fe2aacce719785b1b1ab057f870a2ed6c211b1a19c76afe24e7fbc7e0ea6525dbd5171c7f7641e450841b7fe5f79c970d179ce8c6667e2e7d680a093f12be712c81c91533e5cce66e19f950e4f6e175da2b0f21bd10d2db6ba5efcdc0dae8f367c06c43feb9d8e3c28b7f1825d20865d5242836e8b11467e6be3d494fefe94e019423045156623ec70f59ddf5ca698ed0179269ac6fbf2ea789268cbbd85c4876ef664afebd7706e23e49d0ab40169e260f296de512aa9ae72a343c493f8826844b879b6afb929557290ecda1019ca25918c9599e3337cb28d25352a4ebb0978065ddcff70d9a63187b10dccf499562f808ac60a9528146ac5374421a4b45dd2868a63af6f440f2e401bac9bac8ba638023683c0fb603add037842cdf021dd01fe41b1220724bc00606603810482b095e175b617c782e51b0f377b3be2a66ad4291f0bfa777c8707b07a19fd37c5b0b210eda727db3e28d4a29a1baaa828401d1aeac3539621a31db770bd97e1d640f4412479c41d6c7b356e9e6ce9151f696c1a7525f722d25d97cce1c4f608b6fb2671bff3cd5dac51e3229186bd7b647f4d462b288182871b6fad324486b308094e02c245d2d5cfbb7802f4b0750091981f4e40c11b80884361cb87b9cb21430fb930ca88bebb6ac2ed8cb7e30baf1bad2fcd668ff6d05c6becf3ea1b21d769867ef12be13661cd015e7b7d07dc9f461898c3cddbac2da3a612c519ae8078c6772c125f4eee006b0765b0c86495fe94837083f7750c5b3235af4dfa8f3d4f946f88a2a02ada155b48373e390bc2e3828b57e489b5c9dcb82d35806456d66648cddc102ecf2b4c1dffaee0c06ee01abd71c6c9ccf34378449e808b7c81090e3cce1f618c03a0bed47cb0c130811e39fe601fe33afd276eea4997aa62b78570234fe8627b2b85b6877681396f69989ce3f8c418e9e9f41bb3f37bd9112fe35f937c34003a1d4d6d7a2541f8e9e066f86fff74a5a4a40520315ceb946c316181ff70daa23bf2060ca425de17e547a6267273f9d5b2bbee7528ec6313aab5cfeb19f101b1a092360b2b7d570635d360af640aae176ca6f3cc29282522b97c0c3ba73208d199b74ed05f8d9b9cad5a133c27c10c98da64c098220e5b1f0bd67d495045b2217efa047934a002552c539520c038a34de0baf8ac4bbb2a88361981157985a22289f458867ca537d3ff372a70ecadbc606cb7df258c659aae040dc54e103592b1ee6a2fa1dd413d79e92181b74495ebe377d1a79ad6f06ca2d007c5a7498c5c20ba081a73dce7cc29d96134dceef05c8af99e739268250b84258c21030c42195298e8f1a69b3f95c5ea75e37e0b38da290102de58f3ad7b3edd9052814d9fecc303070e677fde88aef033e82d176ca5a77ac2341c5749703c660ae30bb937b4801e3b3bf9678834284c82c0c06fd85fcfee9acad6866f2b4e387330e67dc587210eee1c354678d349e2df40414b6303396f87e779418bfda30af3b54493fb3d12ea6c5c2469c2b02129943f00f1401cdb84591a4c8556f7232e61742713399ad03d48505203d1a9033285f8613ff2554017958daf2c8fafa8cfd8dbe91ca98c90507866470231ccacdae1df2666666c41a31fba165b36f1fc49ebe4787fb5fb624094b49fff896305a40bc18d57ac8b253135f1c0ff026b50e65434dfeaf28f814157d696a0f903fb97145c1ee3a5f0a0fb802e35283aa78fd87004f51f90d63097588d5ebd62c0d006b7dd75d2be6b974b0d9c4a314ad2b590669a27ba2295029b327220b006230ad9caf5939aaf8b7e57f1c2146da79cf1341afe640ec33ac0c838d1d1e861af6c2f094ab8df86bec2fdc4ef5174150ab90693adefa06640015b564400d3dabcfefc9b193847233949df818cd121ce8faef276a78c50271a413bb81b089445ae2b79735e4e6df11483082e61d23a7047114a5b2859c55bdc913e9b7406c9b5781303508b6f5489b7c81c7e99525806f9828760b2c6952fb750676ea6b808e36498684cc5d766f2a5f25ba30f95b7d75daa509d7bf66ebd8be0df4567272b127292f811bf5f9fa76ecf672acb20657c71c5da6eb7f4bbf0cca158c19c1a174e898aaab4cfde0775c104a912f579b46e94d0d9219ce777a94b805a12f98f32f6f6aa7216b758eeb772870810a51586f8d66378cd172a26a2ccf26278cd5463428fa8b2083b78395afcca1529da3d4944e7da16ce91180abaed1008b479f99037279c1a7391b233f24c940e5a7024a312586df66c946af0885560221849d3c519430f966c9b7ccc75363b96a63689dd93ba8806893015b9d728314eb143a4ed64b45bf0d379fbaad5e74f61d3a3bd4c6e2a76e0e0d4dc57832d710e8e6148bc32ec1fa3f08ea4fbaa3efac775536125e181562dde660a12d0501045cd8605f26d5e97289f33615940804a32608fb3d5f577a1c63f57b445c35661ce1463e8dcd11c472604d1837f803015d078d77ca0c2b376efb0ed8750fc64c0bc837e0afb66f8431656f4ef74bb59de6399e901cfb7f47a9e1bcd1fcd275a30acec68bd38b42651f9463380b1e495f3441876e8ffe7a603b55bb4ee12aff5324577edc16eaaf88efc6dd2bbdffee8c95fcf62c2d1a2f2a8ec0e97e3e136c6f2bc405ff48c06ec946bec5b48470e6c6772af3d0b21d00bc1a8c14af6647c533224f54bdcd616c2b9302cfe5dffe1169a68a875b9d9b38f7b749cf5dc9a09a2d2cab5a98ad50dccb303718da6cb53f2b9a68189dee55655ef89fc1a821bcbfc70f4c102fb1b59b091af47f127404b13f54b3d71faf9b5ba174ea3009a32df0870e0fbac20aeb036fe4a64408c5cfe78d3ff61fce9de6e149ef2844088c36158913b9c5f772b3121e73b624fef2d230e233b57d6c742aa00d09d1227aabc597562c38add1a190be34f5d53d95e7fc3d0d9f8eb1ff15f8c059affea378eea5ab282ce3315739f762dd0c0676a5b8736a5b5c4ac048a230f27321db3452c6b2252b017d2afd0bee5731865e09a2508c251db0444bfc021de3a95444ffd47fc26de406ec52855b0dd6db966a379e617d32c9d493faf48222376e97d1078d9fecd90a1474efb8a467a2fe6435f4658c46b76ab3f6dcde96ecc6069de3b2ab07324a3f0cd0ce51bb4713309a27115b78b4f09c0f1839d9c0c5772d31ceced2bd9b4dbc00a4d7590459fd3327392be64615605126b8ba7ecffd1f2dc9f0c36a13beccf016ea820e45c2abc25f6c79ebc4d6fd4eee630d9f3f7a6cdf494927306535490425565af3f960f2718aef4d8a1bcd143adca885bdac333870bad1e550f5e8e97404c80ea5c0263ed55ac8eb2c91ff528b3bba566c7fba991cbf84ff372d3509391fbc49fe9740191e08071ee526b6af89700dbf3b2b5bc63de77a84eab28d08742db4c0ad0d9ace9a9ee1417ff746110b0f0dc506bf01876184a91f5c111953910c63326f0f542c4ffecbc6f4b1df312ded7fa28797f983b25d28d4e52703076f19c84d3da805d80eb2a4828827de4d0858d376459167a491e9921dc5d09368831a8c035d9ed9b842a53bba981199d5740116db77769ba88438bf136916de110c2c8356cbb574830448c568af6518024c0683a375c18104bd0262479964813ec00b35dcb7d7bed9ff053429f9f90a24d64487f506f600c0f01dbc9b81e5a52dd823ed57939fcbc06df172842d9681158208f621e936981dd1cc5251895f61b85e0686107b3d006a42b4b2e38b777cf599743d8d00073a8a64f9ec85130cffabeb1a6718b55d54f36f2569d6472d5a77b6e28cbce18860924ea91af4aa2236928307ab824e0770d61932a085ceb89f489fde5c99638908c347a2066020f66901550f1d2f7e550e35da40ce6b9f27ad8f6023b56c2d3bd3a50655ec78625670fd7f1f1b05eed3f84e17c8cd600bee23fa630bda9c257a0bea4bca1d47f505e2f515042fc18e5c88681e77895fc66b20013c8da4967decdb4a35c180af45be03ba072946c36ae4e41ef89d47055cd40064a34306f7d11886fc7361a92df4d2e8037d24c8debdc4c99417cb6e6c4ce22340021c8fb82a7dc5ee3fea49b0cc844203b626e99dc5d8e64e2b3f38ac618abacc726c359a214115eaff787e35233d79efbc0e1a10540e5ba9b69d540378c0b45e3eadfba574a64534b514b6c164b4efb9c923a94914dcd6194b4367314fcf2197d9d1b62fff5d1aa2fd117d3258bb1885bd0b12a2a6256c0d327387419c39e3065aea53fe9c7bd24932af3bba5cc4d412ae1562e427974afb97f5f292ece5587e1851349efd2366c6ff79b988eb1e5eb0991cf3685e2fb46f50ee43b884d70e0e97720d5e7f9f1827789308c72e5a92aa8d28d8493687fdf47c046410e41eb33f64a5b63674a02f6e46728825050692a3530a462d73cbed6124a69501b51f9de342d901cbf9fd610c7471eefc9e6c53bca62b91e03cd2927a0c1a13dd1c8a6c7c30c979f65dc9dcb7083a81f86731565dc009040ada3db69ce3731ab64e7cd2ee11521cfac41512bac801365b3d71f655040554f54121b1c78f9ec9b6a36e7abaa41c0c41b33c0d3b032587be22d9750c001b402c0dcd68b859ee0299143e501e071daf2f913ce3cfcc4e2d66a39577633c0888e29db728335d49fdcbf1063d97e364e030fbbcc0df8cf92fbac30a7b0d0d0ad72c2c311c81691b3ae836603bc0fc9a394f16ec6b5ab87fd0a905aae40db30c9bd053f83e8968dbeaa73ec9337c2be4a28ba301b86daa8f57f960a1aa48512fd5982cfdef4864cf2e7187ecc5a3f2183a450ae6b65ee0574ebea485b1f18b2dcbb1fc21de17a2f3b1087057efffc05da8b18f02adc4c1880bcbad33bc445402c08ea707567f77e5aa1bc5fd891a823887fe06b8cf2f30a9b03005859f48e62be9df5a05349b35357e619de2e63c1b2505073954a728e01ff98c07c35c02df0d773c4dfe663e2ffd1b66bcc514205f0d32baad4c26b89e1e31394225ee3153186c92714c399526eb4f953e9c3d23c22d519ed134b9013d1e437228b293c5f611ebbb11aff0dd2f654a97e52ec74ee4d9dd36fc887ae6aad5313d99bcab7e241390f13217a2681465db0da76e3ea98fbce9973faa0b2e8d044f945afc184352009e69aef32e2feb8177e7f2300eb30dbf1f61b104b0ee173c41f0763336291e2473b5605f5c4bd087cf4e13d4f1ef42f1bf571de288216417d0a4f6ec0de9f003c6f19515426a8c2082465dcf37ae1ad412ac31a29b1b18914fd713cfbffaa1149e2771df1d7c251dda0d68c69662c989cc9a114e3d96767479abb513c101be0d490acd3ec654419fb5de9e78bef42e4ef720d5f1a802b530fcdcbbca8338da00e3d1c95951dbd1460d02bda13e6953b042fd5c4b73ee6038c765e4d3c4ce3720cf8ac3715bdd754d90a8ce3eb1cf87e5de08e988f3f19828d15168fde5911a2e153d4543a056a6238f6ca8818c5dc6f3762fcd0d6109ce3534dc4bf0f714d00f64734769929c113ba0e69e805b4ea755021c210cd1b13d737f568b654d98c20a7f65bee3d990a42ccab0d845884b463f7586e3328fef4115551268ef041bba1075aefbdc9bf6bd67d7c1becbd4305c31d16b5aea77a3556f9be5f61cc4537418e3beccaec7bad86513ed36e7812916bde52cfe5c9732624c5f9bafcaf5607916f9d001a94cb2633bca06f6f88e6f1d4a5e2d03833bba26c34e6bb19a8f3c2a0679e3aefd3a93780be7277b8211fcb6ef8b8620215e060c97004507c99e64270d1ff0c5de9368557cd5974e507a6ec922a58eceec863c36538bceeac46c38232340ea85027628b54554c2ee688ce279eef9f436af731655432f505431423db51595446485d7916c08a6244dff44826e509dc534166222c132dd63b8f986df3b14b3dff2166b2c5c0e8cebfd68215f1ebeb3ff447f39908c479f7df87682e6dc2649db1be9b00924827989e4b2e7274a45efe47362548a3fd7109117598febac225f96f13b4dce262bffb305db60235bd8807d4f6901e9bde0ccd5910c956a3804673f1e8a68be8c06e72834c78def4fbea457b3c0c6a2cc021bb7f9fbbabecc265d65d80c123c065226c17686cffdb85aeb9de85e5c6804ddc43e83fe0b3e891cf3b9bc4657b8677d7b7c166f35512c4bd790c8321632dde64877f3d10de8e814a8939bdbd1033bba3acc064f1f9acbd741bf82f3e6798c52d998e9ba41f25a0125421662516b5b472bc3b095a5b6542c0859125f4d4509f88995dd1a1b89be2f0018616862dd7a66600b4c60bde30c6d9671ac843d50380725a7f0d4bda9991b72afcbdb631ce1630b14f49a44ac2af76d6c11a2cca83debdb618f49113f94126cec45ad7eaff383ce025914a3f26b1d16682a77cd4a56e84def94f288b983273d0f6ec2b263e1c2157cf3cba796590d2d111746960260873e2d037a37fd8029e8fdbb43a1558cda66f52d66ec9813751629df4fdda8b05d1d8b244f2dc53f25b522aa23a90479e8dbcabc2fc04f6f122c2375316c87ef6a46f9d6bd180a90167365817b30c4aac45b6b16fa304b6588e9f936ec96b2410104baaa0559bede1cc8a42b092379b53df6767f0995762a372cf4df6d893aeb227e500db368c300281c4db102dc6b0668f98b894731e6389b060eef925da87144951cc71dfb742d1082cd7524376cc91ac7a1c6a29bbc1290a01321fb4349866d9913d852eb4b2e1a0d8bc235163b7708f3140243e8d4621c0d039f716e42db89e80ab63eaa9be924530f2e4524e559aec6e45fca61d04f7b23013b5c2a13c1c5b58c35afe555a40ccbbf7bbc8e38c802aaaf08f8200070ebaf8cbb2fac9a5774d9bd5621caaad016c8739682884795529aa19ed83aafc0790131f62874aa60e8131d947780b3011c4d54089ec8bf65b7f3c5af87983fcc159dc21d55912405026a9cc7717bfbab03e4c591fe51d32b92f91f1f23236dcc29bc16d66f1e51ce3950f07e5aaf3f001034949a19c64a83ef3f21efe459276c451ca37cf3a639529b2bd8cf10120e0b07509453645b733a4e23c6ae6e6d9d764ea5ba82f35fef4965caf1d6430661961b86ce0307524493e1ca92cce928d8284079c816a82f746a63eb7deb36223e0a24814f912446d115cf364afc62a5e959c0d90934049f5c456a1d30f33461bb190c679453867017c8526b4a3d2aa9abece1eb037dd01d81b566c985d5190e2a2901483394085c09816869ff52f8d55ebf059ab918495556c27af9a52d256be7302727b3e49fde532b9ec794bba43e81b86bf65e90ce7ff7db06045dc2bd151d2003c106670fdbb29bd110f9817c7bb4e19cd2228aba4b219c073c1082a8e56c440817d30058f0936520d7f4d4c56718fd608dee3e310d573f59c781230a4b19101a35777fd12a137ab3d2ce19146046a96315de52072975126b47cae1b386ea2d2b7749d692f786369611bfa70887162f52fc29116e5d82542c1476598ddd679e2b914ece4c1a8d1185ac303bf31d33267b550d0392acfcddc47335e995e6b5a902b9baa6bc7d260dc4e35c7467ff514d29a7851432e8d0afbf9c6b77f1df672c2f16945c5a8ef3f93e28a5d44ff30a715f42fd55f5f582864b6de252853c72ec25ad98baf07ab630b092112d28f1e253aff6f2464f891b4b12c86bee4c8ab6b719ac1d61ff379372a1dd746bfe0fe28d5dd01de4a6d48a79be0b68ae456bb0d03039d21b5c34139360ba76013008e72317c124022b38c41b1e9af85dc90700e3279d93400354f856b55ffe7724d6ad1748beddcf479eaec3bb7809ccf79922281ccaeb437a548169d3a6f44554165b7bec45b19dd036b7e6463e775e572c32421f46e13e11b3088e4fdaae067a3467e6a1d1715353a898a12ed85b045e4c2ead2352010e37495e62b045aa6e3d950741b821c66023578b3153890aad7b75a9ca19c970e8d677ebe5b28e1ff6f0188133147130779e152dc66ac44fc6a110762e1b193fa852af5451e6c71b62669112dfc12d4142905167cb3d79af109bf5abf802291b65e1fa63ac9589a089ecaf7fd818425e22f1b14a09c66dba1967c7191b17b3759c7719777ced6edb3d3846a0369f62beedaf53d4ca25c80ad277d9cb462474031bbd90f98e6d9d6e157d4e9600caa27adff2c586ed557737dc9882523200a8236f6f3c42bce641e7080502a5136f659f6332889ab435da23c1c93d79c7045f28f844aed6b451009167fad3a639c734fb3566a04a10871bd6666bf32e6d2b3319f1426a8ff9c6e0152b10d3f1ae1de3af609704613c10d6addd87bd61941dcf43bba8dee15453b4f4f3cbbd0b68770e4e751228a20d8fb1a9fc267898a41798bd837c9561d139a1587ee01d1ba68f827061fa5bdee47fc8aea1b151c1a626f43597fd8c0159708c0bd199d8298fa7a26bdb2195238a69a3a695f363b853208564da9deb57121495344ecaee7580bfe8136d591dd008d223782a739aa54f1a5dc82200b8a949e389076acf9760fe85baede5fc3a1e3a66d0ee44d5fa445d2cee492e6924c26835cdff58e0642cd796f0d83b9519387e43b0232bad47d438305469489f20d80c478648bb65e2197cabadc7271d7912ee7b3e8d619907778407490c8ff6242a2de813b47c19a47008f183f1065fe1d72b8c796811b6c3fdba080b3bcc46b0dd5fc3611c29b319a4ada5f8611f5ecdfe964e7defcf9be2a2ae23b43255aec5a901ccc961dd42bb883762c01e540d51dd080dfa76018c27dcd00d1b20bc09a060b5f9e8f49e09813b6b1b20bca22f2134d1cb6c162474ddb10c0ad4bd3b82d517096440b2db5531114a7a73e3ec6d021657fd1b1384fed2f351144d83d52c8a5b7ca7e8a69d459ca64e2e9217241c604099f47fbbb970919458093bb347422e6b5de88333e2a96382cf98a51501c6692ad1654eeae3f4d101bf03b2a55b1d1d556138bf41294d6c6429be72628a394bb9f82acca572b1d0a7a221cea674c6ae515e522568195b318c1dbbeed4c2c9d2c394179fb22d8fa870ad0051d220073dd41201756f0b3406bf1d440061180840d056c79bf601cf665855187f27368516d1200df4096aea34244e28076d1b3338db88d167430b70b36b8726d3e74444968bca642b89448bc393335a0cc11cbe002f05c67ad58dded245340066bc07afbc0a88cab5e51afcff83c67de1b18fcaa92948758aae0fdb86fbe417a3000a0c6e9ca3ba6c4f0081bc74de7fd67526bf0043288c757830f3c64a902d65972c48eddc4fe74224c680109b1172ae79b8a8f22999eb94e35687d1a3ed169cc4af2486b29042c81005360635b43e1bf9277959425d82dc96ab8766b6770c09c80977de73df0d0b98ce1b175579c0cb5763c9f677e62fa39162f144f8910a6adc8e4f54cb4bf7c353c97bcce974ff2770f8358dcc51c3f770a66a3c176f0e634f9aa0aeb0b33ff31eb295bcba56c66b64ce27c5407ebc9baddac206a8262e0b9a885c4cc870631e2065c17a3759f64b82d9091730b4ea5d4fe53deb1c282d04eaa9410d0ce09ce866f5c453669e9a17033070d514a174df725e2326c3e201bf5b13662a77f2e67d6d11f3260cfa7184a173782bec68a96255530a1eef5d04e3823bc0773a4a8fa3a3c3f391a8b1bbabae957df97e9c13b996ff2b28661e0ab6e38829990d9d2c6067701d424757038b7768162186d6958620d7daa0e7db21d62c9ffa3f71f8fc97fbf01d07a0172e7d1cdfc4268409b9be2ff618d4864b24fd3a0a61fd5ed3b55473cb6d64c40bc801e2e36e93878c81dc180aea10947115718121660ac78751ed1d273cd62ed994d5eebb97c3ac2e3e345a78aa6569840a21dba494c9e3d60887d05f58824e00177626440dd6991d221b19b5240ba62f16ccb0ef3dd8cb3cf34ec84e703fe37b1c8db5dd147b379495a0e141be3eaf54299b17993ae5f00ffa9a99b5b51cc79d23b900eb93314949bc4ad4cb768e6ff61c6f85fda7499697ac1ed69897f6b4fa0119def990f102405e7f0d1249bb3d05232b5d1021d91800b79af16c4864c1973aaa837d9a11b3e71044483212df42eb051226c46990d7a59ff2d8e04da5615e9b1b221e6723071fa5ae81ade55c813f1f619e0cdff8e8c16caa48d848f00c3df37479a955eff0a0b9220db28c3fb0fc0f896d0c06452bfd993b4149ece939bc7055bf685ac9e4a2444918b1d6477c991e49e2db2fafcbe04fe3c45682884e8842028f83993c9689e3463be48e29caa3194bb8188fff95cdcca827b267ceb97056de5576208fc4a8aa912f3ff2d1d5480fe8c3fb0d498460f4084af0ce364415e0f29e6320441b3cb77223a61036a6501a033f7112cf56c75202ce9e40f6a092e1c6bb114a204e1407952f459cb2b82727c106bd85a46723a1dcf08853bdb61e92bd90442c3f102a0874bfe217706c410883076a597aa066572f46cb04a82f5da3fc734e471716d64a70471cca57ac67223cf6b6a38bc0f71d4490fe87bc06040671d2ea8abfd9f604b29f5bc7c49e5029120f7337d642ea0d68bc603547682d463e69f432e145c1a2eff9f92dd52b050250a60b6a59c3bc2c1d7b89b0cf51da9581df42ced6db35fc1c99c74b63ff8c105059ec101f7045f2d411800d8a8bc7608f26d9a31ea5073c7af23ecfaee91603158704b74b1830c5c231af8b23c3e391fc3a19be91ea37758912109b4feb551b63030e9d2952cc522110446cb9d52abb4a9d9be224853d5810c869640ceb4a";

        // Record balance before withdrawal
        uint256 balanceBefore = recipient.balance;

        // Perform withdrawal with real proof
        vault.privateWithdraw(
            proof,
            ETH_TOKEN,
            merkleRoot,
            nullifierHash,
            recipient,
            relayer,
            fee
        );

        // Verify withdrawal succeeded
        // Balance will be handled on the basecontract
        // uint256 balanceAfter = recipient.balance;
        // assertEq(balanceAfter, balanceBefore + DENOMINATION, "Recipient should receive denomination");

        // Verify nullifier is marked as used
        assertTrue(vault.isNullifierUsed(ETH_TOKEN, nullifierHash), "Nullifier should be marked as used");

        // Try to withdraw again with same nullifier (should fail)
        vm.expectRevert(PrivateVault.NullifierAlreadyUsed.selector);
        vault.privateWithdraw(
            proof,
            ETH_TOKEN,
            merkleRoot,
            nullifierHash,
            recipient,
            relayer,
            fee
        );
    }
}
