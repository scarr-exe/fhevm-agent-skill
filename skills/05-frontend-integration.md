# FHEVM Skill — 05: Frontend Integration

## What This File Covers

- Installing and initializing the Relayer SDK
- Encrypting user inputs before sending to contracts
- User decryption — showing users their own private data
- Public decryption flow from the frontend
- React integration pattern
- Common frontend mistakes

---

## Installation

```bash
npm install @zama-fhe/relayer-sdk
```

---

## Initializing the SDK

### Sepolia (testnet — use for development)

```typescript
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({
  ...SepoliaConfig,
  network: "https://ethereum-sepolia-rpc.publicnode.com",
  // or use window.ethereum for browser wallet connection
});
```

### Mainnet

```typescript
import { createInstance, MainnetConfig } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({
  ...MainnetConfig,
  network: "https://ethereum-rpc.publicnode.com",
  auth: {
    __type: "ApiKeyHeader",
    value: process.env.ZAMA_FHEVM_API_KEY,
  },
});
```

### With MetaMask (browser wallet)

```typescript
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({
  ...SepoliaConfig,
  network: window.ethereum, // Eip1193Provider
});
```

---

## Encrypting User Inputs

Before sending encrypted data to a contract, you encrypt it client-side using the FHE public key.

### Single encrypted value

```typescript
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

const instance = await createInstance({ ...SepoliaConfig, network: provider });

// Create an input buffer bound to the contract and the user
const buffer = instance.createEncryptedInput(
  contractAddress,   // address of the receiving contract
  userAddress        // address of the user sending the tx
);

buffer.add64(BigInt(transferAmount)); // encrypt a uint64
const encrypted = await buffer.encrypt();

// encrypted.handles[0] — ciphertext handle (bytes32)
// encrypted.inputProof — ZKPoK proof

// Call the contract
await contract.transfer(
  recipientAddress,
  encrypted.handles[0],
  encrypted.inputProof
);
```

### Multiple values in one input

```typescript
const buffer = instance.createEncryptedInput(contractAddress, userAddress);

buffer.addBool(canTransfer);      // index 0
buffer.add64(transferAmount);     // index 1
buffer.add8(transferType);        // index 2
buffer.addAddress(targetAddress); // index 3

const encrypted = await buffer.encrypt();

await contract.multiParamFunction(
  encrypted.handles[0], // externalEbool
  encrypted.handles[1], // externalEuint64
  encrypted.handles[2], // externalEuint8
  encrypted.handles[3], // externalEaddress
  encrypted.inputProof  // one proof covers all handles
);
```

### Available input methods

```typescript
buffer.addBool(value: boolean)
buffer.add8(value: bigint)
buffer.add16(value: bigint)
buffer.add32(value: bigint)
buffer.add64(value: bigint)
buffer.add128(value: bigint)
buffer.add256(value: bigint)
buffer.addAddress(value: string)  // 20-byte address
```

---

## User Decryption — Showing Users Their Private Data

The user decrypts their own data using an EIP-712 signature. Nothing is revealed on-chain.

```typescript
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

async function getUserBalance(
  contract: ethers.Contract,
  signer: ethers.Signer,
  userAddress: string
): Promise<bigint> {
  const instance = await createInstance({
    ...SepoliaConfig,
    network: window.ethereum,
  });

  // 1. Get the ciphertext handle from the contract
  const encryptedBalance = await contract.getEncryptedBalance();

  // 2. Generate a temporary keypair for re-encryption
  const { publicKey, privateKey } = instance.generateKeypair();

  // 3. Create EIP-712 signature request
  const eip712 = instance.createEIP712(publicKey, contract.address);

  // 4. User signs the request (triggers wallet prompt)
  const signature = await signer.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
  );

  // 5. Decrypt via KMS
  const clearBalance = await instance.userDecrypt(
    encryptedBalance,
    privateKey,
    publicKey,
    signature,
    contract.address,
    userAddress
  );

  return clearBalance; // e.g. 1000n
}
```

---

## Public Decryption — Reading Publicly Revealed Values

Used after a contract marks a value publicly decryptable.

```typescript
async function getPublicResult(
  contract: ethers.Contract,
  handle: string
): Promise<bigint> {
  const instance = await createInstance({
    ...SepoliaConfig,
    network: window.ethereum,
  });

  // Decrypt via KMS — no signature needed for public values
  const results = await instance.publicDecrypt([handle]);

  // Access by handle key
  const clearValue = results.clearValues[handle];
  return clearValue as bigint;
}
```

---

## React Integration Pattern

```typescript
import { useState, useEffect } from "react";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";
import { ethers } from "ethers";

function ConfidentialBalance({ contract, address }) {
  const [balance, setBalance] = useState<bigint | null>(null);
  const [loading, setLoading] = useState(false);

  const decryptBalance = async () => {
    setLoading(true);
    try {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();

      const instance = await createInstance({
        ...SepoliaConfig,
        network: window.ethereum,
      });

      const encBalance = await contract.getEncryptedBalance();
      const { publicKey, privateKey } = instance.generateKeypair();
      const eip712 = instance.createEIP712(publicKey, contract.address);

      const signature = await signer.signTypedData(
        eip712.domain,
        eip712.types,
        eip712.message
      );

      const clear = await instance.userDecrypt(
        encBalance,
        privateKey,
        publicKey,
        signature,
        contract.address,
        address
      );

      setBalance(clear);
    } catch (err) {
      console.error("Decryption failed:", err);
    } finally {
      setLoading(false);
    }
  };

  const transferTokens = async (recipient: string, amount: number) => {
    const provider = new ethers.BrowserProvider(window.ethereum);
    const signer = await provider.getSigner();

    const instance = await createInstance({
      ...SepoliaConfig,
      network: window.ethereum,
    });

    const buffer = instance.createEncryptedInput(
      contract.address,
      address
    );
    buffer.add64(BigInt(amount));
    const encrypted = await buffer.encrypt();

    const tx = await contract
      .connect(signer)
      .transfer(recipient, encrypted.handles[0], encrypted.inputProof);

    await tx.wait();
  };

  return (
    <div>
      <button onClick={decryptBalance} disabled={loading}>
        {loading ? "Decrypting..." : "Reveal Balance"}
      </button>
      {balance !== null && <p>Balance: {balance.toString()}</p>}
    </div>
  );
}
```

---

## Common Frontend Mistakes

### Sending plaintext to an encrypted parameter
```typescript
// WRONG — passing plaintext uint directly
await contract.transfer(recipient, 1000, proof); // ← type mismatch, will fail

// CORRECT — encrypt first, then send handle
const buffer = instance.createEncryptedInput(contract.address, userAddress);
buffer.add64(BigInt(1000));
const enc = await buffer.encrypt();
await contract.transfer(recipient, enc.handles[0], enc.inputProof);
```

### Reusing instance across different users
```typescript
// WRONG — instance is user-specific (contains keys bound to user address)
const globalInstance = await createInstance({ ... });
// ... using globalInstance for multiple different users

// CORRECT — create instance per operation or per user session
async function doUserAction(userAddress: string, ...) {
  const instance = await createInstance({ ...SepoliaConfig, network: provider });
  // use instance
}
```

### Skipping await on encrypt()
```typescript
// WRONG — encrypt() is async, skipping await gives you a Promise not the result
const encrypted = buffer.encrypt(); // ← Promise<EncryptedInput>
await contract.transfer(to, encrypted.handles[0], encrypted.inputProof); // ← undefined

// CORRECT
const encrypted = await buffer.encrypt();
await contract.transfer(to, encrypted.handles[0], encrypted.inputProof);
```

### Mismatched handle index and Solidity parameter
```typescript
// If Solidity expects (externalEuint64 amount, externalEbool flag)
// and you encrypted in order: add64 then addBool

buffer.add64(amount);  // index 0 → handles[0]
buffer.addBool(flag);  // index 1 → handles[1]
const enc = await buffer.encrypt();

// CORRECT mapping:
await contract.myFunction(enc.handles[0], enc.handles[1], enc.inputProof);

// WRONG — swapped handles
await contract.myFunction(enc.handles[1], enc.handles[0], enc.inputProof); // ← fails validation
```

### Not checking ACL before attempting user decrypt
The contract must have called `FHE.allow(ciphertext, userAddress)` first.
If the user has no ACL access, `userDecrypt` will fail.

```typescript
// This will throw if contract never called FHE.allow(balance, userAddress)
const clearBalance = await instance.userDecrypt(...);
```

Verify ACL is set in your contract's deposit/transfer functions:
```solidity
FHE.allow(newBalance, msg.sender); // ← must be present
```
