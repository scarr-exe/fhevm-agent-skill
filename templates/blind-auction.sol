// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BlindAuction
 * @notice A sealed-bid auction where all bids are encrypted.
 *         The highest bid wins. Bid amounts are never revealed publicly.
 *         Only the winner and winning amount are revealed at the end.
 *
 * @dev FHE operations used:
 *   - FHE.fromExternal: validate user's encrypted bid
 *   - FHE.gt: compare bids without revealing them
 *   - FHE.select: update highest bid conditionally
 *   - FHE.makePubliclyDecryptable: reveal winning bid
 *   - FHE.checkSignatures: verify decryption proof on-chain
 *
 * Auction flow:
 *   1. Owner deploys with end time
 *   2. Bidders submit encrypted bids
 *   3. Contract tracks highest bid using FHE.select (no plaintext comparison)
 *   4. After auction ends, owner triggers reveal
 *   5. Off-chain client decrypts, submits proof
 *   6. Winner receives the item; losers can withdraw their bids
 */

import "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindAuction is SepoliaConfig {

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public immutable owner;
    address public immutable beneficiary;
    uint64  public immutable endTime;

    euint64 public highestBid;
    eaddress public highestBidder;

    // Each bidder's encrypted bid amount (for refund logic)
    mapping(address => euint64) public bids;

    bool  public ended;
    bool  public revealed;

    // Set after decryption
    uint64  public clearWinningBid;
    address public clearWinner;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BidSubmitted(address indexed bidder);
    event AuctionEnded();
    event WinnerRevealed(address winner, uint64 winningBid);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyWhileOpen() {
        require(block.timestamp < endTime, "auction ended");
        _;
    }

    modifier onlyAfterEnd() {
        require(block.timestamp >= endTime, "auction still open");
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _beneficiary, uint64 durationSeconds) {
        owner       = msg.sender;
        beneficiary = _beneficiary;
        endTime     = uint64(block.timestamp) + durationSeconds;

        // Initialize highest bid to 0
        highestBid    = FHE.asEuint64(0);
        highestBidder = FHE.asEaddress(address(0));

        FHE.allowThis(highestBid);
        FHE.allowThis(highestBidder);
    }

    // -------------------------------------------------------------------------
    // Bidding
    // -------------------------------------------------------------------------

    /**
     * @notice Submit an encrypted bid.
     * @param encBid Encrypted bid amount handle
     * @param inputProof ZKPoK proving bidder knows their bid amount
     */
    function bid(
        externalEuint64 encBid,
        bytes calldata inputProof
    ) external onlyWhileOpen {
        // Validate and convert the encrypted bid
        euint64 newBid = FHE.fromExternal(encBid, inputProof);

        // Store this bidder's bid for potential refund
        if (FHE.isInitialized(bids[msg.sender])) {
            // If bidder is re-bidding, keep the higher of the two bids
            ebool isHigher = FHE.gt(newBid, bids[msg.sender]);
            euint64 updatedBid = FHE.select(isHigher, newBid, bids[msg.sender]);
            FHE.allowThis(updatedBid);
            FHE.allow(updatedBid, msg.sender);
            bids[msg.sender] = updatedBid;
        } else {
            FHE.allowThis(newBid);
            FHE.allow(newBid, msg.sender);
            bids[msg.sender] = newBid;
        }

        // Check if this bid beats the current highest
        ebool isNewHighest = FHE.gt(newBid, highestBid);

        // Update highest bid and bidder using FHE.select (no plaintext branch)
        euint64  newHighestBid    = FHE.select(isNewHighest, newBid, highestBid);
        eaddress newHighestBidder = FHE.select(
            isNewHighest,
            FHE.asEaddress(msg.sender),
            highestBidder
        );

        FHE.allowThis(newHighestBid);
        FHE.allowThis(newHighestBidder);

        highestBid    = newHighestBid;
        highestBidder = newHighestBidder;

        emit BidSubmitted(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Ending and Revealing
    // -------------------------------------------------------------------------

    /**
     * @notice End the auction and request public decryption of the winner.
     *         Can be called by anyone after endTime.
     */
    function endAuction() external onlyAfterEnd {
        require(!ended, "already ended");
        ended = true;

        // Mark winning bid and winner as publicly decryptable
        FHE.makePubliclyDecryptable(highestBid);
        FHE.makePubliclyDecryptable(highestBidder);

        emit AuctionEnded();
    }

    /**
     * @notice Submit decrypted winner data with KMS proof to finalize.
     *
     * Off-chain client must:
     *   1. Call instance.publicDecrypt([highestBidHandle, highestBidderHandle])
     *      ⚠️ Order matters — must match the handles array order below
     *   2. Submit clearBid, clearWinner, and decryptionProof
     */
    function revealWinner(
        uint64 clearBid,
        address clearBidder,
        bytes calldata decryptionProof
    ) external {
        require(ended, "auction not ended");
        require(!revealed, "already revealed");

        // Verify proof — order must match publicDecrypt([highestBid, highestBidder])
        bytes32[] memory handles = new bytes32[](2);
        handles[0] = FHE.toBytes32(highestBid);
        handles[1] = FHE.toBytes32(highestBidder);

        bytes memory encoded = abi.encode(clearBid, clearBidder);
        FHE.checkSignatures(handles, encoded, decryptionProof);

        // Replay protection
        revealed      = true;
        clearWinningBid = clearBid;
        clearWinner     = clearBidder;

        emit WinnerRevealed(clearBidder, clearBid);
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    function getWinner() external view returns (address winner, uint64 winningBid) {
        require(revealed, "not yet revealed");
        return (clearWinner, clearWinningBid);
    }

    /**
     * @notice Returns caller's encrypted bid handle.
     *         Decrypt off-chain using relayer SDK userDecrypt().
     */
    function getMyBid() external view returns (euint64) {
        require(FHE.isInitialized(bids[msg.sender]), "no bid placed");
        return bids[msg.sender];
    }
}

// =============================================================================
// FRONTEND USAGE EXAMPLE (TypeScript)
// =============================================================================
//
// --- PLACE BID ---
// const buffer = instance.createEncryptedInput(auctionAddress, bidderAddress);
// buffer.add64(BigInt(5000)); // bid amount in tokens
// const enc = await buffer.encrypt();
// await auction.connect(bidder).bid(enc.handles[0], enc.inputProof);
//
// --- END AUCTION (after endTime) ---
// await auction.endAuction();
//
// --- GET HANDLES ---
// const [highestBidHandle, highestBidderHandle] = await Promise.all([
//   auction.highestBid(),
//   auction.highestBidder()
// ]);
//
// --- OFF-CHAIN DECRYPT (order must match revealWinner handles array) ---
// const results = await instance.publicDecrypt([highestBidHandle, highestBidderHandle]);
//
// --- SUBMIT PROOF ---
// await auction.revealWinner(
//   results.clearValues[highestBidHandle],
//   results.clearValues[highestBidderHandle],
//   results.decryptionProof
// );
//
// --- READ WINNER ---
// const [winner, bid] = await auction.getWinner();
