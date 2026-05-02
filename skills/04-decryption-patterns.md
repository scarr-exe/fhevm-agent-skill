# FHEVM Skill — 04: Decryption Patterns

## What This File Covers

- Two types of decryption: user decryption vs public decryption
- Complete flow for each with Solidity + TypeScript code
- Input proofs — what they are and why they matter
- Replay attack protection
- Common decryption mistakes

---

## Two Decryption Flows

| | User Decryption | Public Decryption |
|--|-----------------|-------------------|
| Who can see result | Only the requesting user | Anyone |
| Trigger | User signs EIP-712 request | Contract calls `makePubliclyDecryptable` |
| On-chain verification | Not required | `FHE.checkSignatures` required |
| Use case | Show user their balance | Reveal vote tally, auction result |

---

## User Decryption (Private — EIP-712 Flow)

The user decrypts their own data off-chain. Nothing is revealed on-chain.

### What the user does (TypeScript / Frontend)

```typescript
import { createInstance } from "@zama-ai/relayer-sdk";

const instance = await createInstance();

// 1. Get the encrypted handle from the contract
const encryptedBalance = await contract.getEncryptedBalance();

// 2. Create re-encryption request with EIP-712 signature
const { publicKey, privateKey } = instance.generateKeypair();
const eip712 = instance.createEIP712(publicKey, contract.address);
const signature = await signer.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
);

// 3. Decrypt — KMS validates signature and returns cleartext
const clearBalance = await instance.userDecrypt(
    encryptedBalance,
    privateKey,
    publicKey,
    signature,
    contract.address,
    signer.address
);

console.log("Balance:", clearBalance); // e.g. 1000n
```

### Solidity — expose handle for user to decrypt

```solidity
// Return the ciphertext handle so the user can decrypt it client-side
// This does NOT expose the plaintext — the handle alone is safe to return
function getEncryptedBalance() public view returns (euint64) {
    require(FHE.isAllowed(balances[msg.sender], msg.sender), "no access");
    return balances[msg.sender];
}
```

**The user must have ACL access to the ciphertext before they can decrypt it.**
Call `FHE.allow(balance, user)` when the balance is created or updated.

---

## Public Decryption (3-Step Async Flow)

Use when the decrypted value needs to be revealed to everyone and used in contract logic.

### Step 1 — Contract marks value as publicly decryptable

```solidity
event DecryptionRequested(euint64 encryptedResult);

function revealResult() external onlyOwner {
    require(!isRevealed, "already revealed");

    // Mark as publicly decryptable — permanent and global
    FHE.makePubliclyDecryptable(finalResult);

    emit DecryptionRequested(finalResult);
}
```

### Step 2 — Off-chain client requests decryption from KMS

```typescript
import { createInstance } from "@zama-ai/relayer-sdk";

const instance = await createInstance();

// Get the handle from contract or event
const handle = await contract.getFinalResult();

// Decrypt via KMS — returns cleartext + proof
const results = await instance.publicDecrypt([handle]);

const clearValue = results.clearValues[handle];
const decryptionProof = results.decryptionProof;
const abiEncodedValue = results.abiEncodedClearValues;
```

### Step 3 — Contract verifies proof and uses cleartext

```solidity
bool private isRevealed;
uint64 private revealedResult;

function submitRevealedResult(
    uint64 clearResult,
    bytes memory decryptionProof
) external {
    require(!isRevealed, "already finalized");

    // Build handle array — order is critical (must match abiEncode order)
    bytes32[] memory handles = new bytes32[](1);
    handles[0] = FHE.toBytes32(finalResult);

    // Verify proof — reverts if invalid
    bytes memory abiEncoded = abi.encode(clearResult);
    FHE.checkSignatures(handles, abiEncoded, decryptionProof);

    // Now safe to use clearResult
    isRevealed = true;
    revealedResult = clearResult;

    emit ResultRevealed(clearResult);
}
```

### Multiple values in one decryption (handle order is critical)

```solidity
function finalizeAuction(
    uint64 clearWinnerBid,
    address clearWinnerAddr,
    bytes memory decryptionProof
) external {
    // ⚠️ ORDER MATTERS — proof is bound to this exact sequence
    bytes32[] memory handles = new bytes32[](2);
    handles[0] = FHE.toBytes32(encryptedWinnerBid);   // must match abi.encode order
    handles[1] = FHE.toBytes32(encryptedWinnerAddr);  // must match abi.encode order

    bytes memory abiEncoded = abi.encode(clearWinnerBid, clearWinnerAddr);
    FHE.checkSignatures(handles, abiEncoded, decryptionProof);

    // execute finalization
    winner = clearWinnerAddr;
    winnerBid = clearWinnerBid;
}
```

```typescript
// TypeScript — must request in same order as Solidity handles array
const results = await instance.publicDecrypt([
    encryptedWinnerBidHandle,  // index 0
    encryptedWinnerAddrHandle  // index 1
]);
```

---

## Input Proofs — What They Are and Why They Matter

When a user submits an encrypted value to a contract, they include a **Zero-Knowledge Proof
of Knowledge (ZKPoK)**. This proves the user knows the plaintext they encrypted, without
revealing it.

Without input proofs, an attacker could replay a ciphertext they observed on-chain (e.g.
someone else's balance handle) and pass it as their own input.

### What generates input proofs

```typescript
const input = fhevm.createEncryptedInput(contract.address, userAddress);
input.add64(transferAmount);
const encrypted = await input.encrypt();

// encrypted.handles[0] — the ciphertext handle
// encrypted.inputProof   — the ZKPoK, required for validation
```

### How the contract validates them

```solidity
function transfer(
    address to,
    externalEuint64 encAmount,
    bytes calldata inputProof
) external {
    // FHE.fromExternal validates the ZKPoK and converts to euint64
    euint64 amount = FHE.fromExternal(encAmount, inputProof);
    // from here, `amount` is trusted
}
```

**Never skip `FHE.fromExternal`.** Using a raw `externalEuint64` without validation is
equivalent to accepting unverified user input.

---

## Replay Attack Protection

After finalizing a public decryption, always set a guard flag to prevent the same proof
being submitted again.

```solidity
bool private decryptionFinalized;

function finalize(uint64 clearValue, bytes memory proof) external {
    require(!decryptionFinalized, "already finalized"); // ← replay protection
    
    bytes32[] memory handles = new bytes32[](1);
    handles[0] = FHE.toBytes32(encryptedValue);
    FHE.checkSignatures(handles, abi.encode(clearValue), proof);

    decryptionFinalized = true;
    // execute business logic
}
```

---

## Common Decryption Mistakes

### Returning plaintext from a view function
```solidity
// WRONG — contracts cannot decrypt on-chain
function getBalance() public view returns (uint64) {
    return uint64(balances[msg.sender]); // ← type error, and logically wrong
}

// CORRECT — return the encrypted handle; user decrypts off-chain
function getEncryptedBalance() public view returns (euint64) {
    return balances[msg.sender];
}
```

### Wrong handle order in checkSignatures
```solidity
// If you request decrypt([efoo, ebar]) off-chain,
// your on-chain handles array and abi.encode must match that exact order.

// WRONG — reversed order
bytes32[] memory handles = new bytes32[](2);
handles[0] = FHE.toBytes32(encryptedBar); // swapped
handles[1] = FHE.toBytes32(encryptedFoo); // swapped
bytes memory encoded = abi.encode(clearFoo, clearBar); // mismatch
FHE.checkSignatures(handles, encoded, proof); // ← REVERTS

// CORRECT — same order as publicDecrypt call
handles[0] = FHE.toBytes32(encryptedFoo);
handles[1] = FHE.toBytes32(encryptedBar);
bytes memory encoded = abi.encode(clearFoo, clearBar);
```

### Skipping input proof validation
```solidity
// WRONG — using raw external input without proof validation
function deposit(externalEuint64 encAmount) external {
    balances[msg.sender] = FHE.add(balances[msg.sender], encAmount); // ← invalid
}

// CORRECT
function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
    euint64 amount = FHE.fromExternal(encAmount, inputProof);
    balances[msg.sender] = FHE.add(balances[msg.sender], amount);
    FHE.allowThis(balances[msg.sender]);
}
```

### Calling makePubliclyDecryptable without ACL access
```solidity
// WRONG — calling on a handle you don't have permission for
FHE.makePubliclyDecryptable(someoneElsesHandle);

// CORRECT — you must have ACL access first
FHE.allowThis(myHandle);
FHE.makePubliclyDecryptable(myHandle);
```

### No replay protection on finalize functions
```solidity
// WRONG — anyone can call finalize multiple times with different values
function finalize(uint64 clearValue, bytes memory proof) external {
    FHE.checkSignatures(...);
    doBusinessLogic(clearValue); // ← called repeatedly
}

// CORRECT
bool finalized;
function finalize(uint64 clearValue, bytes memory proof) external {
    require(!finalized, "already done");
    FHE.checkSignatures(...);
    finalized = true;
    doBusinessLogic(clearValue);
}
```
