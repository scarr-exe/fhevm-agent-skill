import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * ConfidentialVoting Test Suite
 *
 * Covers:
 *   1. Deployment
 *   2. Voter registration
 *   3. Proposal creation
 *   4. Encrypted vote casting (yes and no)
 *   5. Duplicate vote prevention
 *   6. Unregistered voter rejection
 *   7. Voting after deadline rejection
 *   8. Tally request after deadline
 *   9. Result reveal with decryption proof
 *  10. Replay attack prevention
 *  11. Correct tally — 3 yes, 1 no
 *  12. Pre-reveal guard
 */

describe("ConfidentialVoting", function () {
  let voting: any;
  let owner: any;
  let alice: any;
  let bob: any;
  let carol: any;
  let dave: any;
  let stranger: any;

  let contractAddress: string;
  const PROPOSAL_ID = 0;
  const DURATION = 3600; // 1 hour in seconds

  // ─────────────────────────────────────────────────────────────────────────
  // Setup
  // ─────────────────────────────────────────────────────────────────────────

  before(async function () {
    [owner, alice, bob, carol, dave, stranger] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("ConfidentialVoting");
    voting = await Factory.deploy();
    await voting.waitForDeployment();

    contractAddress = await voting.getAddress();
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Deployment
  // ─────────────────────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("sets the deployer as owner", async function () {
      expect(await voting.owner()).to.equal(owner.address);
    });

    it("starts with zero proposals", async function () {
      expect(await voting.proposalCount()).to.equal(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Voter Registration
  // ─────────────────────────────────────────────────────────────────────────

  describe("Voter Registration", function () {
    it("owner can register voters", async function () {
      await voting.connect(owner).registerVoter(alice.address);
      await voting.connect(owner).registerVoter(bob.address);
      await voting.connect(owner).registerVoter(carol.address);
      await voting.connect(owner).registerVoter(dave.address);

      expect(await voting.registeredVoters(alice.address)).to.be.true;
      expect(await voting.registeredVoters(bob.address)).to.be.true;
      expect(await voting.registeredVoters(carol.address)).to.be.true;
      expect(await voting.registeredVoters(dave.address)).to.be.true;
    });

    it("stranger is not registered", async function () {
      expect(await voting.registeredVoters(stranger.address)).to.be.false;
    });

    it("non-owner cannot register voters", async function () {
      await expect(
        voting.connect(alice).registerVoter(stranger.address)
      ).to.be.revertedWith("not owner");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Proposal Creation
  // ─────────────────────────────────────────────────────────────────────────

  describe("Proposal Creation", function () {
    it("owner can create a proposal", async function () {
      const tx = await voting
        .connect(owner)
        .createProposal("Should we upgrade the protocol?", DURATION);

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log: any) => log.fragment?.name === "ProposalCreated"
      );

      expect(event).to.not.be.undefined;
      expect(await voting.proposalCount()).to.equal(1);
    });

    it("non-owner cannot create a proposal", async function () {
      await expect(
        voting.connect(alice).createProposal("Rogue proposal", DURATION)
      ).to.be.revertedWith("not owner");
    });

    it("proposal tallies start as initialized encrypted handles", async function () {
      const proposal = await voting.proposals(PROPOSAL_ID);

      // yesVotes and noVotes are ciphertext handles (bytes32)
      // They should exist (non-zero) — they are encrypted zeros, not plaintext zeros
      expect(proposal.yesVotes).to.not.equal(ethers.ZeroHash);
      expect(proposal.noVotes).to.not.equal(ethers.ZeroHash);
      expect(proposal.revealed).to.be.false;
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Casting Encrypted Votes
  // ─────────────────────────────────────────────────────────────────────────

  describe("Casting Encrypted Votes", function () {
    it("alice casts YES — vote is accepted", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, alice.address);
      input.addBool(true); // true = yes
      const enc = await input.encrypt();

      const tx = await voting
        .connect(alice)
        .castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof);

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log: any) => log.fragment?.name === "VoteCast"
      );

      expect(event).to.not.be.undefined;
      expect(event.args.voter).to.equal(alice.address);
      expect(await voting.hasVoted(PROPOSAL_ID, alice.address)).to.be.true;
    });

    it("bob casts YES — vote is accepted", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, bob.address);
      input.addBool(true);
      const enc = await input.encrypt();

      await voting.connect(bob).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof);
      expect(await voting.hasVoted(PROPOSAL_ID, bob.address)).to.be.true;
    });

    it("carol casts YES — vote is accepted", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, carol.address);
      input.addBool(true);
      const enc = await input.encrypt();

      await voting.connect(carol).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof);
      expect(await voting.hasVoted(PROPOSAL_ID, carol.address)).to.be.true;
    });

    it("dave casts NO — vote is accepted", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, dave.address);
      input.addBool(false); // false = no
      const enc = await input.encrypt();

      await voting.connect(dave).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof);
      expect(await voting.hasVoted(PROPOSAL_ID, dave.address)).to.be.true;
    });

    it("tally is still encrypted during voting — no leaks", async function () {
      const proposal = await voting.proposals(PROPOSAL_ID);

      // Tally exists as a ciphertext handle — no plaintext readable on-chain
      expect(typeof proposal.yesVotes).to.equal("string");
      expect(proposal.revealed).to.be.false;
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Vote Access Control
  // ─────────────────────────────────────────────────────────────────────────

  describe("Vote Access Control", function () {
    it("prevents duplicate voting", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, alice.address);
      input.addBool(true);
      const enc = await input.encrypt();

      await expect(
        voting.connect(alice).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof)
      ).to.be.revertedWith("already voted");
    });

    it("rejects unregistered voter", async function () {
      const input = fhevm.createEncryptedInput(contractAddress, stranger.address);
      input.addBool(true);
      const enc = await input.encrypt();

      await expect(
        voting.connect(stranger).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof)
      ).to.be.revertedWith("not a registered voter");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Deadline Enforcement
  // ─────────────────────────────────────────────────────────────────────────

  describe("Deadline Enforcement", function () {
    it("cannot request reveal while voting is open", async function () {
      await expect(
        voting.connect(owner).requestReveal(PROPOSAL_ID)
      ).to.be.revertedWith("voting still open");
    });

    it("rejects votes after deadline", async function () {
      // Fast-forward past deadline
      await time.increase(DURATION + 1);

      const [, , , , , , lateVoter] = await ethers.getSigners();
      await voting.connect(owner).registerVoter(lateVoter.address);

      const input = fhevm.createEncryptedInput(contractAddress, lateVoter.address);
      input.addBool(true);
      const enc = await input.encrypt();

      await expect(
        voting.connect(lateVoter).castVote(PROPOSAL_ID, enc.handles[0], enc.inputProof)
      ).to.be.revertedWith("voting closed");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Tally Request
  // ─────────────────────────────────────────────────────────────────────────

  describe("Tally Request", function () {
    it("anyone can request reveal after deadline", async function () {
      // stranger (non-owner) triggers reveal
      const tx = await voting.connect(stranger).requestReveal(PROPOSAL_ID);
      const receipt = await tx.wait();

      const event = receipt.logs.find(
        (log: any) => log.fragment?.name === "TallyRequested"
      );

      expect(event).to.not.be.undefined;
      expect((await voting.proposals(PROPOSAL_ID)).tallied).to.be.true;
    });

    it("cannot request reveal twice", async function () {
      await expect(
        voting.connect(owner).requestReveal(PROPOSAL_ID)
      ).to.be.revertedWith("already tallied");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Result Reveal + Correct Tally
  //    *** This is the key test to show in the video ***
  // ─────────────────────────────────────────────────────────────────────────

  describe("Result Reveal — 3 YES, 1 NO", function () {
    it("decrypts tally correctly: 3 yes, 1 no", async function () {
      const proposal = await voting.proposals(PROPOSAL_ID);

      // Mock decryption — only works in local Hardhat FHEVM environment
      // In production: use instance.publicDecrypt([yesHandle, noHandle])
      const clearYes = await fhevm.decrypt64(proposal.yesVotes);
      const clearNo  = await fhevm.decrypt64(proposal.noVotes);

      // alice=yes, bob=yes, carol=yes, dave=no
      expect(clearYes).to.equal(3n, "expected 3 yes votes");
      expect(clearNo).to.equal(1n,  "expected 1 no vote");
    });

    it("submits proof and finalizes result on-chain", async function () {
      const proposal = await voting.proposals(PROPOSAL_ID);

      const clearYes = await fhevm.decrypt64(proposal.yesVotes);
      const clearNo  = await fhevm.decrypt64(proposal.noVotes);

      // Generate mock decryption proof (local env only)
      const mockProof = await fhevm.generateDecryptionProof(
        [proposal.yesVotes, proposal.noVotes],
        [clearYes, clearNo]
      );

      const tx = await voting
        .connect(owner)
        .revealResult(PROPOSAL_ID, clearYes, clearNo, mockProof);

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log: any) => log.fragment?.name === "ResultRevealed"
      );

      expect(event).to.not.be.undefined;
      expect(event.args.yesVotes).to.equal(3n);
      expect(event.args.noVotes).to.equal(1n);
    });

    it("result is now publicly readable on-chain", async function () {
      const [yes, no, revealed] = await voting.getResult(PROPOSAL_ID);

      expect(revealed).to.be.true;
      expect(yes).to.equal(3n);
      expect(no).to.equal(1n);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 9. Replay Attack Prevention
  // ─────────────────────────────────────────────────────────────────────────

  describe("Replay Attack Prevention", function () {
    it("cannot submit the same proof twice", async function () {
      const proposal = await voting.proposals(PROPOSAL_ID);

      const clearYes = await fhevm.decrypt64(proposal.yesVotes);
      const clearNo  = await fhevm.decrypt64(proposal.noVotes);

      const mockProof = await fhevm.generateDecryptionProof(
        [proposal.yesVotes, proposal.noVotes],
        [clearYes, clearNo]
      );

      await expect(
        voting.connect(owner).revealResult(PROPOSAL_ID, clearYes, clearNo, mockProof)
      ).to.be.revertedWith("already revealed");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 10. Pre-reveal Guard
  // ─────────────────────────────────────────────────────────────────────────

  describe("Pre-reveal Guard", function () {
    it("getResult reverts on unrevealed proposal", async function () {
      // Create a fresh proposal, do not reveal it
      await voting.connect(owner).createProposal("Unrevealed proposal", DURATION);
      const newId = (await voting.proposalCount()) - 1n;

      await expect(
        voting.getResult(newId)
      ).to.be.revertedWith("not yet revealed");
    });
  });
});
