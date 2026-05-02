# FHEVM Skill — 01: Architecture

## What This File Covers

- How FHE works on-chain without the cryptography lecture
- The role of each system component
- Transaction lifecycle with encrypted data
- Trust model — what "confidential" actually guarantees
- What you as a developer control vs what the protocol handles

---

## How FHE Works On-Chain (Developer Mental Model)

Standard Solidity: you store `uint256 balance = 100`. Anyone can read it.

FHEVM: you store `euint64 balance`. The value `100` is encrypted into a ciphertext. The contract
holds a **ciphertext handle** — a `bytes32` reference to the encrypted value. No one on-chain
ever sees `100`, including the contract itself.

Operations like `FHE.add(a, b)` work **directly on the ciphertexts**. The result is another
ciphertext. The EVM never decrypts anything during execution.

Decryption happens **off-chain**, through the Zama Key Management System (KMS), only when
explicitly requested and authorized.

---

## System Components

### 1. FHE Solidity Library (`@fhevm/solidity`)
The library you import in your contracts. Provides:
- Encrypted types: `euint8`, `euint64`, `ebool`, `eaddress`, etc.
- Operations: `FHE.add`, `FHE.eq`, `FHE.select`, etc.
- Access control: `FHE.allow`, `FHE.allowThis`, `FHE.allowTransient`
- Decryption setup: `FHE.makePubliclyDecryptable`, `FHE.checkSignatures`
- Input validation: `FHE.fromExternal`

### 2. Access Control List (ACL) Contract
A dedicated on-chain contract that records permissions over ciphertext handles.
When you call `FHE.allow(ciphertext, address)`, it writes to the ACL.
Without an ACL entry, no one (including your own contract) can reuse a ciphertext
across transactions.

### 3. Key Management System (KMS)
Off-chain infrastructure operated by Zama. Holds the master FHE private key.
Responds to authorized decryption requests.
Returns decrypted values **plus a cryptographic proof** that the decryption was performed
legitimately. Your contract verifies this proof on-chain via `FHE.checkSignatures`.

### 4. Relayer SDK (`fhevmjs` / `@zama-ai/relayer-sdk`)
A TypeScript library used in your frontend and tests. It:
- Encrypts user inputs using the FHE public key before sending to the contract
- Generates Zero-Knowledge Proofs of Knowledge (ZKPoK) that accompany each encrypted input
- Calls the KMS for decryption on behalf of the user
- Returns decrypted values and decryption proofs to use in on-chain verification

### 5. Hardhat Plugin (`@zama-ai/hardhat-fhevm`)
Extends Hardhat with FHEVM-aware tooling:
- Local mock FHE environment for testing
- `fhevm.createEncryptedInput()` for creating test inputs
- Mock decryption for asserting on encrypted state in tests

---

## Transaction Lifecycle with Encrypted Data

### Sending encrypted input (user to contract)

```
User (browser)
  → fhevmjs encrypts plaintext with FHE public key
  → fhevmjs generates ZKPoK proving user knows the plaintext
  → sends [ciphertext handle, inputProof] to contract function

Contract
  → FHE.fromExternal(handle, inputProof) validates proof + converts to euint64
  → performs FHE operations on the result
  → stores result ciphertext, calls FHE.allowThis + FHE.allow
```

### Decrypting a value (user-side)

```
Frontend
  → calls contract to get ciphertext handle (e.g. getEncryptedBalance())
  → calls relayer-sdk userDecrypt(handle, EIP-712 signature)
  → KMS validates signature, decrypts, returns cleartext + proof
  → frontend displays value to user
```

### Public decryption (reveal on-chain result)

```
Contract
  → calls FHE.makePubliclyDecryptable(ciphertext)
  → emits event

Off-chain client
  → calls instance.publicDecrypt([handle])
  → receives cleartext + decryptionProof from KMS

Contract
  → receives cleartext + proof via callback function
  → calls FHE.checkSignatures to verify authenticity
  → executes business logic with clear value
```

---

## Trust Model

| Who can see the plaintext? | Under what condition? |
|----------------------------|-----------------------|
| The user who encrypted it  | Always (they know it) |
| A specific address         | After `FHE.allow(cipher, address)` + user-side decryption |
| The public                 | After `FHE.makePubliclyDecryptable` + public decryption flow |
| The contract itself        | Never directly — only through authorized decryption |
| Node operators             | Never — computation is on ciphertexts only |
| Zama KMS                   | Only during explicit decryption requests |

**What FHEVM does NOT protect against:**
- Logic bugs in your contract (e.g. unauthorized ACL grants)
- Metadata leakage (e.g. if you emit unencrypted values in events)
- Timing attacks if you leak information through conditional execution paths

---

## Configuration — How to Set Up a Contract

Every FHEVM contract must inherit a config contract that sets the correct gateway and KMS addresses.

```solidity
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { EthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// For Sepolia testnet, use SepoliaConfig instead:
// import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is EthereumConfig {
    // your contract code here
}
```

Available config contracts:
- `EthereumConfig` — Ethereum mainnet
- `SepoliaConfig` — Sepolia testnet (use this for development)

**Do not hardcode gateway or KMS addresses manually.** Always inherit from the config contract.

---

## What the Developer Controls

You are responsible for:
- Which addresses get ACL access to which ciphertexts
- When and how decryption is triggered
- Ensuring `FHE.allowThis` is called after every mutation
- Validating input proofs via `FHE.fromExternal`
- Your contract logic — FHEVM does not protect against bad logic

The protocol handles:
- Actual FHE cryptography
- Key management
- Decryption proof generation and verification

---

## Common Architecture Mistakes

### Not inheriting the config contract
```solidity
// WRONG — will fail at runtime
contract MyContract {
    function doSomething() public { ... }
}

// CORRECT
contract MyContract is SepoliaConfig {
    function doSomething() public { ... }
}
```

### Assuming the contract can "read" encrypted values
Contracts cannot print, compare, or branch on plaintext versions of encrypted values.
`FHE.eq(a, b)` returns an `ebool`, not a `bool`. Use `FHE.select` for conditional logic.

```solidity
// WRONG — euint64 cannot be cast to uint64 for comparison
require(uint64(balance) > 0, "empty balance");

// CORRECT — use FHE operations
ebool hasBalance = FHE.gt(balance, FHE.asEuint64(0));
// use hasBalance in further FHE logic or decrypt it
```
