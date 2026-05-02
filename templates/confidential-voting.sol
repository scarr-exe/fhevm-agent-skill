// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ConfidentialVoting
 * @notice A voting contract where vote choices are encrypted.
 *         Votes are cast as encrypted booleans (yes/no).
 *         Only the final tally is revealed after the voting period ends.
 *
 * @dev FHE operations used:
 *   - FHE.fromExternal: validate user's encrypted vote
 *   - FHE.add: tally votes
 *   - FHE.select: conditionally add vote
 *   - FHE.makePubliclyDecryptable: reveal final result
 *   - FHE.checkSignatures: verify decryption proof on-chain
 *
 * Voting flow:
 *   1. Owner creates proposal
 *   2. Registered voters cast encrypted votes (true = yes, false = no)
 *   3. After deadline, anyone can trigger tallying
 *   4. Owner requests public decryption of tally
 *   5. Off-chain client decrypts, submits proof on-chain
 *   6. Final result is publicly available
 */

import "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialVoting is SepoliaConfig {

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    struct Proposal {
        string description;
        euint64 yesVotes;       // encrypted tally of yes votes
        euint64 noVotes;        // encrypted tally of no votes
        uint64  deadline;       // unix timestamp
        bool    tallied;        // votes have been tallied
        bool    revealed;       // result has been publicly revealed
        uint64  clearYesVotes;  // set after decryption
        uint64  clearNoVotes;   // set after decryption
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public registeredVoters;

    uint256 public proposalCount;
    address public owner;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProposalCreated(uint256 indexed proposalId, string description, uint64 deadline);
    event VoteCast(uint256 indexed proposalId, address indexed voter);
    event TallyRequested(uint256 indexed proposalId, euint64 yesVotes, euint64 noVotes);
    event ResultRevealed(uint256 indexed proposalId, uint64 yesVotes, uint64 noVotes);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyRegistered() {
        require(registeredVoters[msg.sender], "not a registered voter");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function registerVoter(address voter) external onlyOwner {
        registeredVoters[voter] = true;
    }

    function createProposal(
        string calldata description,
        uint64 durationSeconds
    ) external onlyOwner returns (uint256) {
        uint256 id = proposalCount++;
        Proposal storage p = proposals[id];
        p.description = description;
        p.deadline = uint64(block.timestamp) + durationSeconds;

        // Initialize tallies to 0
        p.yesVotes = FHE.asEuint64(0);
        p.noVotes  = FHE.asEuint64(0);

        // Contract must retain access to these handles
        FHE.allowThis(p.yesVotes);
        FHE.allowThis(p.noVotes);

        emit ProposalCreated(id, description, p.deadline);
        return id;
    }

    // -------------------------------------------------------------------------
    // Voting
    // -------------------------------------------------------------------------

    /**
     * @notice Cast an encrypted vote.
     * @param proposalId ID of the proposal
     * @param encVote Encrypted boolean: true = yes, false = no
     * @param inputProof ZKPoK proving sender knows their vote
     */
    function castVote(
        uint256 proposalId,
        externalEbool encVote,
        bytes calldata inputProof
    ) external onlyRegistered {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp <= p.deadline, "voting closed");
        require(!hasVoted[proposalId][msg.sender], "already voted");

        hasVoted[proposalId][msg.sender] = true;

        // Validate and convert the encrypted vote
        ebool vote = FHE.fromExternal(encVote, inputProof);

        // Conditionally add to yes or no tally using FHE.select
        // If vote == true, add 1 to yes. If vote == false, add 1 to no.
        euint64 one  = FHE.asEuint64(1);
        euint64 zero = FHE.asEuint64(0);

        euint64 yesIncrement = FHE.select(vote, one, zero);
        euint64 noIncrement  = FHE.select(vote, zero, one);

        euint64 newYes = FHE.add(p.yesVotes, yesIncrement);
        euint64 newNo  = FHE.add(p.noVotes, noIncrement);

        // Must grant contract access to new handles
        FHE.allowThis(newYes);
        FHE.allowThis(newNo);

        p.yesVotes = newYes;
        p.noVotes  = newNo;

        emit VoteCast(proposalId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Tally and Reveal
    // -------------------------------------------------------------------------

    /**
     * @notice Mark tally as ready for public decryption.
     *         Can be called by anyone after deadline.
     */
    function requestReveal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.deadline, "voting still open");
        require(!p.tallied, "already tallied");

        p.tallied = true;

        // Mark both tallies as publicly decryptable
        FHE.makePubliclyDecryptable(p.yesVotes);
        FHE.makePubliclyDecryptable(p.noVotes);

        emit TallyRequested(proposalId, p.yesVotes, p.noVotes);
    }

    /**
     * @notice Submit decrypted tally with KMS proof to finalize.
     *
     * Off-chain client must:
     *   1. Call instance.publicDecrypt([yesHandle, noHandle])
     *   2. Submit clearYes, clearNo, and decryptionProof here
     *
     * IMPORTANT: handle order in decryption call must match
     *            the order in this function's checkSignatures call.
     */
    function revealResult(
        uint256 proposalId,
        uint64 clearYes,
        uint64 clearNo,
        bytes calldata decryptionProof
    ) external {
        Proposal storage p = proposals[proposalId];
        require(p.tallied, "tally not requested");
        require(!p.revealed, "already revealed");

        // Verify decryption proof — order must match publicDecrypt([yesVotes, noVotes])
        bytes32[] memory handles = new bytes32[](2);
        handles[0] = FHE.toBytes32(p.yesVotes);
        handles[1] = FHE.toBytes32(p.noVotes);

        bytes memory encoded = abi.encode(clearYes, clearNo);
        FHE.checkSignatures(handles, encoded, decryptionProof);

        // Replay protection
        p.revealed = true;
        p.clearYesVotes = clearYes;
        p.clearNoVotes  = clearNo;

        emit ResultRevealed(proposalId, clearYes, clearNo);
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    function getResult(uint256 proposalId) external view returns (
        uint64 yes,
        uint64 no,
        bool revealed
    ) {
        Proposal storage p = proposals[proposalId];
        require(p.revealed, "not yet revealed");
        return (p.clearYesVotes, p.clearNoVotes, p.revealed);
    }
}

// =============================================================================
// FRONTEND USAGE EXAMPLE (TypeScript)
// =============================================================================
//
// --- CAST VOTE ---
// const buffer = instance.createEncryptedInput(contractAddress, voterAddress);
// buffer.addBool(true);  // true = yes, false = no
// const enc = await buffer.encrypt();
// await voting.connect(voter).castVote(proposalId, enc.handles[0], enc.inputProof);
//
// --- REQUEST REVEAL (after deadline) ---
// await voting.requestReveal(proposalId);
//
// --- OFF-CHAIN DECRYPT ---
// const yesHandle = await voting.proposals(proposalId).then(p => p.yesVotes);
// const noHandle  = await voting.proposals(proposalId).then(p => p.noVotes);
// const results = await instance.publicDecrypt([yesHandle, noHandle]);
//
// --- SUBMIT PROOF ON-CHAIN ---
// await voting.revealResult(
//   proposalId,
//   results.clearValues[yesHandle],
//   results.clearValues[noHandle],
//   results.decryptionProof
// );
//
// --- READ RESULT ---
// const [yes, no] = await voting.getResult(proposalId);
// console.log(`Yes: ${yes}, No: ${no}`);
