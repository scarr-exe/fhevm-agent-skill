# FHEVM Agent Skill — Master Reference

You are an AI coding agent with deep knowledge of the Zama Protocol and FHEVM.
Use this file as your entry point. Load the relevant sub-skill before writing any code.

---

## What is FHEVM?

FHEVM is a Solidity library that lets smart contracts compute directly on encrypted data using
Fully Homomorphic Encryption (FHE). Data encrypted by a user stays encrypted on-chain — the
contract never sees the plaintext. Computations happen on ciphertexts. Results stay encrypted
until explicitly decrypted through a controlled off-chain process.

Key guarantee: **no one — not the node operator, not the contract owner, not the network — can
read encrypted values without authorized decryption.**

---

## Sub-Skills — Load the Right One

| Task | Load |
|------|------|
| Understanding architecture / how FHE works on-chain | `skills/01-architecture.md` |
| Working with encrypted types and operations | `skills/02-encrypted-types-and-ops.md` |
| Setting up ACL permissions | `skills/03-access-control.md` |
| Decrypting values (user or public) | `skills/04-decryption-patterns.md` |
| Frontend integration with fhevmjs | `skills/05-frontend-integration.md` |
| Writing tests for FHEVM contracts | `skills/06-testing.md` |
| ERC-7984 confidential token standard | `skills/07-erc7984-confidential-tokens.md` |
| Common anti-patterns and mistakes | `examples/anti-patterns.md` |

**Always load `examples/anti-patterns.md` alongside any sub-skill when writing new contracts.**

---

## Quick Reference — Most Common Patterns

### Encrypted types
```solidity
ebool    // encrypted boolean
euint8   // encrypted uint8
euint16  // encrypted uint16
euint32  // encrypted uint32
euint64  // encrypted uint64  ← most common for token amounts
euint128 // encrypted uint128
euint256 // encrypted uint256
eaddress // encrypted address
```

### Accepting encrypted input from a user
```solidity
function transfer(
    address to,
    externalEuint64 encryptedAmount,
    bytes calldata inputProof
) public {
    euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
    // use `amount` in computations
    FHE.allowThis(amount);         // allow this contract to reuse it
    FHE.allow(amount, msg.sender); // allow sender to decrypt it
}
```

### Granting access
```solidity
FHE.allowThis(ciphertext);           // contract can reuse across transactions
FHE.allow(ciphertext, someAddress);  // permanent access for an address
FHE.allowTransient(ciphertext, addr); // single-transaction access only
```

### FHE operations
```solidity
euint64 sum  = FHE.add(a, b);
euint64 diff = FHE.sub(a, b);
euint64 prod = FHE.mul(a, b);
ebool   eq   = FHE.eq(a, b);
ebool   gt   = FHE.gt(a, b);
euint64 sel  = FHE.select(condition, ifTrue, ifFalse); // encrypted conditional
```

### Initialization check
```solidity
if (!FHE.isInitialized(myEncryptedVar)) {
    myEncryptedVar = FHE.asEuint64(0);
}
```

---

## The Single Most Important Anti-Pattern

**Never use `FHE.allowThis` and immediately forget to call it after every mutation.**

```solidity
// WRONG — balance updated but contract loses access to it next transaction
balances[to] = FHE.add(balances[to], amount);

// CORRECT
balances[to] = FHE.add(balances[to], amount);
FHE.allowThis(balances[to]);
FHE.allow(balances[to], to); // if recipient should be able to decrypt
```

See `examples/anti-patterns.md` for the full list.

---

## Imports and Config

```solidity
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { EthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is EthereumConfig {
    // your code
}
```

---

## Useful Links

- Docs: https://docs.zama.ai/fhevm
- GitHub: https://github.com/zama-ai/fhevm
- Hardhat template: https://github.com/zama-ai/fhevm-hardhat-template
- Community: https://community.zama.ai
