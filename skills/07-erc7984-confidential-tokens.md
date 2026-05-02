# FHEVM Skill — 07: ERC-7984 Confidential Tokens

## What This File Covers

- What ERC-7984 is vs standard ERC-20
- OpenZeppelin Confidential Contracts setup
- Building a basic ERC-7984 token
- Wrapping ERC-20 into ERC-7984 and back
- Transfer patterns and operators
- Extensions: Freezable, ObserverAccess, Restricted
- Common ERC-7984 mistakes

---

## What is ERC-7984?

ERC-7984 is a standard fungible token implementation similar to ERC-20, but built from the ground up with confidentiality in mind. All balance and transfer amounts are represented as ciphertext handles, ensuring that no data is leaked to the public.

Key differences from ERC-20:

| | ERC-20 | ERC-7984 |
|--|--------|----------|
| Balances | Public `uint256` | Encrypted `euint64` |
| Transfer amounts | Public | Encrypted |
| ERC-20 compatible | Yes | No — new interface |
| Decimals | 18 (convention) | 6 (recommended) |
| Approval model | Allowance-based | Operator with expiration |

ERC-7984 is not ERC-20 compliant — the standard incorporates lessons from ERC-20, ERC-721, ERC-1155, ERC-6909 and provides an interface for maximal functionality.

---

## Installation

```bash
npm install @openzeppelin/confidential-contracts
npm install @fhevm/solidity
```

---

## Basic ERC-7984 Token

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { FHE, externalEuint64, euint64 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { ERC7984 } from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ConfidentialToken is SepoliaConfig, ERC7984, Ownable2Step {
    constructor(
        address owner,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    ) ERC7984(name_, symbol_, contractURI_) Ownable(owner) {}

    // Mint with encrypted amount (full privacy)
    function mint(
        address to,
        externalEuint64 amount,
        bytes calldata inputProof
    ) external onlyOwner {
        _mint(to, FHE.fromExternal(amount, inputProof));
    }

    // Mint with plaintext (amount visible at mint time)
    function mintClear(address to, uint64 amount) external onlyOwner {
        euint64 encAmount = FHE.asEuint64(amount);
        _mint(to, encAmount);
    }

    // Burn with encrypted amount
    function burn(
        address from,
        externalEuint64 amount,
        bytes calldata inputProof
    ) external onlyOwner {
        _burn(from, FHE.fromExternal(amount, inputProof));
    }
}
```

---

## ERC-7984 Transfer Functions

The token standard exposes eight different transfer functions — all permutations of: transfer vs transferFrom, with vs without inputProof, and with vs without ERC1363-style callback.

### Transfer from sender (you know the amount)

```solidity
// When sender created the encrypted amount themselves
function transfer(address to, externalEuint64 amount, bytes calldata inputProof) external;

// When sender already has a ciphertext handle they own (ACL access)
function transfer(address to, euint64 amount) external;
```

### Transfer on behalf of another (operator pattern)

```solidity
// transferFrom — operator moves tokens from `from`
function transferFrom(address from, address to, externalEuint64 amount, bytes calldata inputProof) external;
function transferFrom(address from, address to, euint64 amount) external;
```

### Frontend — Sending a Transfer

```typescript
const buffer = instance.createEncryptedInput(tokenAddress, senderAddress);
buffer.add64(BigInt(transferAmount));
const enc = await buffer.encrypt();

// Use transfer with inputProof when you're creating a fresh encrypted amount
await token.connect(sender)["transfer(address,bytes32,bytes)"](
  recipientAddress,
  enc.handles[0],
  enc.inputProof
);
```

---

## Operators (Replacing ERC-20 Allowances)

An operator is an address that has the ability to move tokens on behalf of another address by calling `transferFrom`. Operators are set using an expiration timestamp — this can be thought of as a limited duration infinite approval for an ERC-20.

```solidity
// Set Bob as operator for Alice for 24 hours
const expirationTimestamp = Math.round(Date.now() / 1000) + 60 * 60 * 24;
await token.connect(alice).setOperator(bob.address, expirationTimestamp);
```

```solidity
// Bob can now move Alice's tokens
await token.connect(bob).transferFrom(alice.address, carol.address, enc.handles[0], enc.inputProof);
```

**Operators do NOT gain the ability to decrypt or re-encrypt balance handles for the delegating address.**

---

## Wrapping ERC-20 into ERC-7984

Use `ERC7984ERC20Wrapper` to wrap an existing ERC-20 into a confidential ERC-7984 token.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { ERC7984ERC20Wrapper } from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";

contract WrappedConfidentialToken is SepoliaConfig, ERC7984ERC20Wrapper {
    constructor(
        address underlyingToken,  // the ERC-20 to wrap
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    ) ERC7984ERC20Wrapper(underlyingToken, name_, symbol_, contractURI_) {}
}
```

### Wrapping ERC-20 → ERC-7984 (deposit)

```typescript
// User approves wrapper contract to spend their ERC-20
await erc20.connect(user).approve(wrapperAddress, amount);

// User deposits ERC-20, receives encrypted ERC-7984 balance
await wrapper.connect(user).depositFor(userAddress, amount);
// Balance is now encrypted — amount is no longer visible on-chain
```

### Unwrapping ERC-7984 → ERC-20 (withdraw)

```typescript
// User requests to unwrap — triggers public decryption flow
const buffer = instance.createEncryptedInput(wrapperAddress, userAddress);
buffer.add64(BigInt(withdrawAmount));
const enc = await buffer.encrypt();

await wrapper.connect(user).withdrawTo(userAddress, enc.handles[0], enc.inputProof);
// After decryption is verified on-chain, user receives plain ERC-20 back
```

**Wrapping: amount is visible entering the wrapper. Unwrapping: requires explicit decryption — user is choosing to make that amount public.**

---

## Available Extensions

OpenZeppelin provides several ERC-7984 extensions:
- `ERC7984ERC20Wrapper` — wraps an ERC-20 into a confidential token
- `ERC7984Freezable` — allows a freezer role to freeze/unfreeze accounts
- `ERC7984ObserverAccess` — allows each account to add an observer with access to their transfers and balances
- `ERC7984Restricted` — implements user account transfer restrictions

### Freezable

```solidity
import { ERC7984Freezable } from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984Freezable.sol";

contract MyToken is SepoliaConfig, ERC7984Freezable, Ownable {
    // freezer role can call freeze(address) and unfreeze(address)
}
```

### ObserverAccess (Compliance Use Case)

```solidity
import { ERC7984ObserverAccess } from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ObserverAccess.sol";

// Each user can assign an observer (e.g. auditor, regulator)
// Observer gains read access to that user's encrypted balances and transfers
```

---

## Disclosing an Encrypted Amount Publicly

```solidity
// Step 1 — request disclosure (on-chain)
function requestDisclose(euint64 encryptedAmount) external {
    // Both msg.sender AND address(this) must have ACL access
    FHE.allowThis(encryptedAmount);
    token.requestDiscloseEncryptedAmount(encryptedAmount);
}

// Step 2 — off-chain: call publicDecrypt via relayer-sdk

// Step 3 — submit proof to finalize disclosure (on-chain)
token.discloseEncryptedAmount(encryptedAmount, clearAmount, decryptionProof);
// Emits AmountDisclosed event
```

---

## Common ERC-7984 Mistakes

### Treating ERC-7984 like ERC-20
```solidity
// WRONG — balanceOf returns euint64, not uint256
uint256 bal = token.balanceOf(user); // type error

// CORRECT — decrypt via frontend
const encBal = await token.balanceOf(userAddress);
const clear = await instance.userDecrypt(encBal, ...);
```

### Expecting ERC-20 transfer events
ERC-7984 does not emit standard ERC-20 `Transfer(address, address, uint256)` events
because amounts are confidential. Do not rely on transfer event parsing from ERC-20 tooling.

### Missing ZamaConfig inheritance
```solidity
// WRONG — ERC7984 needs FHE configuration
contract MyToken is ERC7984 { ... }

// CORRECT
contract MyToken is SepoliaConfig, ERC7984 { ... }
```

### Using decimals: 18 with euint64
`euint64` max value is 18,446,744,073,709,551,615.
With 18 decimals, this allows a max of ~18 tokens. Use 6 decimals as recommended.

```solidity
// Built into ERC7984 base — decimals() returns 6 by default
// Do not override to 18 unless you have specific reason
```

### Calling transferFrom without operator permission
```solidity
// If Bob is not set as operator for Alice, this will revert
await token.connect(bob).transferFrom(alice.address, carol.address, ...);

// Alice must first set Bob as operator
await token.connect(alice).setOperator(bob.address, expirationTimestamp);
```

### Unwrapping to address(0) or wrong recipient
```solidity
// Always pass the correct recipient when withdrawing
await wrapper.withdrawTo(
  recipientAddress, // must be a valid non-zero address
  enc.handles[0],
  enc.inputProof
);
```
