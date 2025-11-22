// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PrivateVault.sol";
import {PoseidonT3} from "../src/Poseidon.sol";

// Mock withdrawal verifier that always returns true for testing
contract MockWithdrawalVerifier is IWithdrawalVerifier {
    bool public shouldSucceed = true;

    function verify(bytes calldata, uint256[] calldata) external view override returns (bool) {
        return shouldSucceed;
    }

    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }
}

// Concrete implementation of PrivateVault for testing
contract TestPrivateVault is PrivateVault {
    constructor(
        address _withdrawalVerifier,
        uint256 _treeDepth,
        bytes32[] memory _initialRoots,
        address[] memory _tokenAddresses,
        uint256[] memory _denominations
    ) PrivateVault(
        _withdrawalVerifier,
        _treeDepth,
        _initialRoots,
        _tokenAddresses,
        _denominations
    ) {}

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
        _privateWithdraw(proof, token, merkleRoot, nullifierHash, recipient, relayer, fee);
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
