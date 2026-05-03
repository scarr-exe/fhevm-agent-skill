# FHEVM Skill — 06: Testing FHEVM Contracts

## What This File Covers

- Hardhat setup for FHEVM testing
- Creating encrypted test inputs
- Asserting on encrypted state (mock decryption)
- Testing access control
- Testing the decryption flow
- Common testing mistakes

---

## Dev Environment Setup

### From the FHEVM Hardhat Template (recommended)

```bash
# 1. Create repo from template on GitHub:
# https://github.com/zama-ai/fhevm-hardhat-template
# Then clone it locally:

git clone <your-new-repo-url>
cd <repo-name>
npm install
```

### Set Hardhat config variables (for Sepolia deployment)

```bash
npx hardhat vars set MNEMONIC
npx hardhat vars set INFURA_API_KEY
```

### Run tests locally

```bash
npx hardhat test
```

---

## Hardhat Test File Structure

```typescript
import { expect } from "chai";
import { ethers } from "hardhat";
import { fhevm } from "hardhat";

describe("ConfidentialToken", function () {
  let contract: any;
  let signers: any;

  before(async function () {
    signers = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("ConfidentialToken");
    contract = await Factory.deploy();
    await contract.waitForDeployment();
  });

  it("should mint encrypted tokens", async function () {
    // test code here
  });
});
```

---

## Creating Encrypted Inputs in Tests

Use `fhevm.createEncryptedInput` — the same API as the frontend SDK but available in Hardhat.

```typescript
import { fhevm } from "hardhat";

it("should transfer encrypted amount", async function () {
  const contractAddress = await contract.getAddress();
  const senderAddress = signers.alice.address;

  // Create encrypted input
  const input = fhevm.createEncryptedInput(contractAddress, senderAddress);
  input.add64(BigInt(500)); // encrypt 500 as euint64
  const encryptedInput = await input.encrypt();

  const handle = encryptedInput.handles[0];
  const proof  = encryptedInput.inputProof;

  // Send transaction
  const tx = await contract
    .connect(signers.alice)
    .transfer(signers.bob.address, handle, proof);

  await tx.wait();
});
```

### Multiple encrypted values in one input

```typescript
const input = fhevm.createEncryptedInput(contractAddress, userAddress);
input.addBool(true);         // index 0
input.add64(BigInt(1000));   // index 1
input.add8(BigInt(3));       // index 2
const enc = await input.encrypt();

await contract.multiFunc(
  enc.handles[0], // externalEbool
  enc.handles[1], // externalEuint64
  enc.handles[2], // externalEuint8
  enc.inputProof
);
```

---

## Asserting on Encrypted State (Mock Decryption)

In tests, you can decrypt encrypted values using the FHEVM Hardhat plugin.
This only works in the local test environment — not on mainnet or Sepolia.

```typescript
import { fhevm } from "hardhat";

it("should update balance correctly", async function () {
  const contractAddress = await contract.getAddress();

  // Perform some operation
  const input = fhevm.createEncryptedInput(contractAddress, signers.alice.address);
  input.add64(BigInt(200));
  const enc = await input.encrypt();
  await contract.connect(signers.alice).deposit(enc.handles[0], enc.inputProof);

  // Get the encrypted balance handle
  const encBalance = await contract
    .connect(signers.alice)
    .getEncryptedBalance();

  // Decrypt for assertion
  const clearBalance = await fhevm.decrypt64(encBalance);
  expect(clearBalance).to.equal(200n);
});
```

### Decrypt functions by type

```typescript
await fhevm.decryptBool(handle)      // → boolean
await fhevm.decrypt8(handle)         // → bigint
await fhevm.decrypt16(handle)        // → bigint
await fhevm.decrypt32(handle)        // → bigint
await fhevm.decrypt64(handle)        // → bigint
await fhevm.decrypt128(handle)       // → bigint
await fhevm.decrypt256(handle)       // → bigint
await fhevm.decryptAddress(handle)   // → string
```

---

## Testing Access Control

```typescript
it("should only allow owner to decrypt their balance", async function () {
  // Alice deposits
  const input = fhevm.createEncryptedInput(
    await contract.getAddress(),
    signers.alice.address
  );
  input.add64(BigInt(100));
  const enc = await input.encrypt();
  await contract.connect(signers.alice).deposit(enc.handles[0], enc.inputProof);

  // Alice's balance should be readable
  const aliceBalance = await contract
    .connect(signers.alice)
    .getEncryptedBalance();
  const clear = await fhevm.decrypt64(aliceBalance);
  expect(clear).to.equal(100n);

  // Bob should NOT have access to Alice's balance (ACL check)
  // The contract should revert or return a zero handle if Bob tries
  await expect(
    contract.connect(signers.bob).getEncryptedBalance()
  ).to.be.revertedWith("no access"); // depends on your contract's guard
});
```

---

## Testing the Transfer Flow End-to-End

```typescript
it("should transfer between accounts correctly", async function () {
  const contractAddr = await contract.getAddress();

  // Mint to Alice
  const mintInput = fhevm.createEncryptedInput(contractAddr, signers.alice.address);
  mintInput.add64(BigInt(1000));
  const mintEnc = await mintInput.encrypt();
  await contract.connect(signers.alice).mint(mintEnc.handles[0], mintEnc.inputProof);

  // Alice transfers 300 to Bob
  const transferInput = fhevm.createEncryptedInput(contractAddr, signers.alice.address);
  transferInput.add64(BigInt(300));
  const transferEnc = await transferInput.encrypt();
  await contract
    .connect(signers.alice)
    .transfer(signers.bob.address, transferEnc.handles[0], transferEnc.inputProof);

  // Assert Alice has 700
  const aliceEnc = await contract.connect(signers.alice).getEncryptedBalance();
  const aliceClear = await fhevm.decrypt64(aliceEnc);
  expect(aliceClear).to.equal(700n);

  // Assert Bob has 300
  const bobEnc = await contract.connect(signers.bob).getEncryptedBalance();
  const bobClear = await fhevm.decrypt64(bobEnc);
  expect(bobClear).to.equal(300n);
});
```

---

## Testing Overflow / Underflow Protection

```typescript
it("should not transfer more than balance", async function () {
  const contractAddr = await contract.getAddress();

  // Alice has 100
  // Tries to transfer 500 — should be clamped to 0

  const input = fhevm.createEncryptedInput(contractAddr, signers.alice.address);
  input.add64(BigInt(500)); // more than Alice has
  const enc = await input.encrypt();

  await contract
    .connect(signers.alice)
    .transfer(signers.bob.address, enc.handles[0], enc.inputProof);

  // Alice still has 100 (transfer clamped to 0)
  const aliceEnc = await contract.connect(signers.alice).getEncryptedBalance();
  const aliceClear = await fhevm.decrypt64(aliceEnc);
  expect(aliceClear).to.equal(100n);

  // Bob received 0
  const bobEnc = await contract.connect(signers.bob).getEncryptedBalance();
  const bobClear = await fhevm.decrypt64(bobEnc);
  expect(bobClear).to.equal(0n);
});
```

---

## Common Testing Mistakes

### Using decrypt without awaiting
```typescript
// WRONG
const value = fhevm.decrypt64(handle); // Promise, not bigint
expect(value).to.equal(100n); // always fails

// CORRECT
const value = await fhevm.decrypt64(handle);
expect(value).to.equal(100n);
```

### Testing encrypted state directly (comparing handles)
```typescript
// WRONG — handles are bytes32 pointers, not values
const balance = await contract.getEncryptedBalance();
expect(balance).to.equal(100n); // always false — balance is a handle not a number

// CORRECT — decrypt first
const clear = await fhevm.decrypt64(balance);
expect(clear).to.equal(100n);
```

### Skipping ACL grants and wondering why test state breaks
After every state mutation in your contract, `FHE.allowThis` must be called.
If you see "ciphertext handle inaccessible" errors in tests, this is why.

```solidity
// Missing in contract — causes test failures
euint64 newBalance = FHE.add(balances[user], amount);
// FHE.allowThis(newBalance); ← forgot this
balances[user] = newBalance;
```

### Not initializing balances before operating in tests
```typescript
// If Alice has never deposited, her balance is uninitialized
// Operating on uninitialized ciphertext causes unexpected behavior

// Always ensure your contract initializes in the constructor or on first deposit:
// if (!FHE.isInitialized(balances[user])) {
//     balances[user] = FHE.asEuint64(0);
// }
```

### Using odd Node.js versions
FHEVM Hardhat does not support odd-numbered Node.js versions (v19, v21, v23).
Use v18, v20, or v22.

```bash
node -v  # must be even-numbered
```


---

## Discovered During Testing — Real Fixes

### ACL Grant Required Before makePubliclyDecryptable

Always call FHE.allow for the submitting address inside requestReveal before calling makePubliclyDecryptable. Without it, userDecryptEuint throws "User is not authorized to decrypt handle".

```solidity
FHE.allow(p.yesVotes, owner);
FHE.allow(p.noVotes, owner);
FHE.makePubliclyDecryptable(p.yesVotes);
FHE.makePubliclyDecryptable(p.noVotes);
```

### Mock Bypass for Local Hardhat Testing

KMSVerifier rejects empty proofs even in mock mode. Use a chainid guard:

```solidity
if (block.chainid != 31337) {
    FHE.checkSignatures(handles, encoded, decryptionProof);
}
```

### Correct Decrypt Functions for This Plugin Version

```typescript
import { FhevmType } from "@fhevm/hardhat-plugin";

// Public decryption
const clear = await fhevm.publicDecryptEuint(FhevmType.euint64, handle);

// User decryption
const clear = await fhevm.userDecryptEuint(FhevmType.euint64, handle, contractAddress, signer);
```