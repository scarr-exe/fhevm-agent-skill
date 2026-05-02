# FHEVM Anti-Patterns — Complete Reference

This file documents every known mistake developers make when building with FHEVM.
Load this file alongside any sub-skill when writing new contracts.

Each entry includes: the broken pattern, why it fails, and the correct fix.

---

## Category 1 — Access Control (ACL) Mistakes

### AP-01: Missing FHE.allowThis after mutation

**Severity: Critical** — contract permanently loses access to its own state.

```solidity
// WRONG
function deposit(externalEuint64 encAmount, bytes calldata proof) external {
    euint64 amount = FHE.fromExternal(encAmount, proof);
    balances[msg.sender] = FHE.add(balances[msg.sender], amount);
    // ← NO allowThis — contract cannot use this balance next transaction
}

// CORRECT
function deposit(externalEuint64 encAmount, bytes calldata proof) external {
    euint64 amount = FHE.fromExternal(encAmount, proof);
    euint64 newBalance = FHE.add(balances[msg.sender], amount);
    FHE.allowThis(newBalance);           // ← contract retains access
    FHE.allow(newBalance, msg.sender);   // ← user can decrypt their balance
    balances[msg.sender] = newBalance;
}
```

**Why it fails:** Every FHE computation creates a new ciphertext handle. Without `FHE.allowThis`,
the new handle is orphaned — inaccessible in future transactions.

---

### AP-02: Allowing old handle instead of new computed result

**Severity: Critical** — you grant access to the input, not the output.

```solidity
// WRONG
euint64 newBalance = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]); // ← old handle, not the new result
FHE.allow(balances[user], user);
balances[user] = newBalance; // newBalance has no ACL grants

// CORRECT
euint64 newBalance = FHE.add(balances[user], amount);
FHE.allowThis(newBalance); // ← new handle
FHE.allow(newBalance, user);
balances[user] = newBalance;
```

---

### AP-03: Using allowTransient for persistent state

**Severity: High** — user cannot decrypt their balance after the transaction ends.

```solidity
// WRONG — transient access expires at end of transaction
FHE.allowTransient(balances[user], user);

// CORRECT — use permanent allow for user-facing data
FHE.allow(balances[user], user);
```

---

### AP-04: Not granting access before calling external contract

**Severity: High** — external call reverts with ACL error.

```solidity
// WRONG
externalVault.deposit(userBalance); // vault has no ACL access

// CORRECT
FHE.allowTransient(userBalance, address(externalVault));
externalVault.deposit(userBalance);
```

---

## Category 2 — Encrypted Type Mistakes

### AP-05: Using if/require/revert on encrypted values

**Severity: Compilation error** — `ebool` is not `bool`.

```solidity
// WRONG — does not compile
ebool isValid = FHE.gt(amount, FHE.asEuint64(0));
require(isValid, "invalid"); // type error

// CORRECT — use FHE.select for conditional encrypted logic
euint64 safeAmount = FHE.select(isValid, amount, FHE.asEuint64(0));
```

---

### AP-06: Arithmetic on euint256

**Severity: Compilation error** — euint256 does not support arithmetic.

```solidity
// WRONG
euint256 result = FHE.add(a256, b256); // does not compile

// CORRECT — use euint128 for large arithmetic
euint128 result = FHE.add(a128, b128);
```

---

### AP-07: Encrypted divisor in div/rem

**Severity: Runtime panic** — divisor must be plaintext.

```solidity
// WRONG — panics at runtime
euint64 b = FHE.asEuint64(4);
euint64 result = FHE.div(a, b); // ← PANICS

// CORRECT — plaintext rhs only
euint64 result = FHE.div(a, 4);
```

---

### AP-08: Operating on uninitialized ciphertext

**Severity: High** — produces undefined behavior or revert.

```solidity
// WRONG — balance[newUser] is uninitialized
balances[newUser] = FHE.add(balances[newUser], amount);

// CORRECT
if (!FHE.isInitialized(balances[newUser])) {
    balances[newUser] = FHE.asEuint64(0);
}
euint64 newBal = FHE.add(balances[newUser], amount);
FHE.allowThis(newBal);
balances[newUser] = newBal;
```

---

### AP-09: Silent truncation on downcast

**Severity: Medium** — value is silently wrong with no error thrown.

```solidity
euint64 big = FHE.asEuint64(300);
euint8 small = FHE.asEuint8(big); // 300 % 256 = 44 — silently wrong

// If you must downcast, ensure the value fits in the target type before casting
```

---

## Category 3 — Decryption Mistakes

### AP-10: Returning plaintext from view function

**Severity: Critical** — impossible on-chain; reveals nothing to the user who needs it.

```solidity
// WRONG — contracts cannot decrypt on-chain
function getBalance() public view returns (uint64) {
    return uint64(balances[msg.sender]); // type error + logically broken
}

// CORRECT — return encrypted handle; user decrypts off-chain
function getEncryptedBalance() public view returns (euint64) {
    require(FHE.isSenderAllowed(balances[msg.sender]), "no access");
    return balances[msg.sender];
}
```

---

### AP-11: Wrong handle order in checkSignatures

**Severity: Critical** — proof verification reverts.

The decryption proof is cryptographically bound to the exact order of handles.

```solidity
// If you called publicDecrypt([efoo, ebar]) off-chain:

// WRONG — reversed order causes revert
bytes32[] memory handles = new bytes32[](2);
handles[0] = FHE.toBytes32(encryptedBar); // swapped
handles[1] = FHE.toBytes32(encryptedFoo); // swapped
FHE.checkSignatures(handles, abi.encode(clearFoo, clearBar), proof); // REVERTS

// CORRECT — same order as publicDecrypt call
handles[0] = FHE.toBytes32(encryptedFoo);
handles[1] = FHE.toBytes32(encryptedBar);
FHE.checkSignatures(handles, abi.encode(clearFoo, clearBar), proof);
```

---

### AP-12: Skipping FHE.fromExternal (no input proof validation)

**Severity: Critical** — allows replay attacks with stolen ciphertext handles.

```solidity
// WRONG — no proof validation, attacker can replay any known handle
function deposit(externalEuint64 encAmount) external {
    balances[msg.sender] = FHE.add(balances[msg.sender], encAmount);
}

// CORRECT
function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
    euint64 amount = FHE.fromExternal(encAmount, inputProof);
    euint64 newBal = FHE.add(balances[msg.sender], amount);
    FHE.allowThis(newBal);
    balances[msg.sender] = newBal;
}
```

---

### AP-13: No replay protection on finalize functions

**Severity: High** — same decryption proof can be submitted multiple times.

```solidity
// WRONG — can be called repeatedly
function finalize(uint64 clearVal, bytes memory proof) external {
    FHE.checkSignatures(..., proof);
    doBusinessLogic(clearVal);
}

// CORRECT
bool private finalized;
function finalize(uint64 clearVal, bytes memory proof) external {
    require(!finalized, "already finalized");
    FHE.checkSignatures(..., proof);
    finalized = true;
    doBusinessLogic(clearVal);
}
```

---

### AP-14: Calling makePubliclyDecryptable without ACL access

**Severity: High** — reverts because contract doesn't have permission.

```solidity
// WRONG — no ACL access first
FHE.makePubliclyDecryptable(externalHandle);

// CORRECT — must own the handle
FHE.allowThis(result);
FHE.makePubliclyDecryptable(result);
```

---

## Category 4 — Configuration Mistakes

### AP-15: Missing ZamaConfig inheritance

**Severity: Critical** — FHE operations fail at runtime.

```solidity
// WRONG
contract MyContract {
    function compute() public { ... }
}

// CORRECT
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is SepoliaConfig {
    function compute() public { ... }
}
```

---

### AP-16: Hardcoding gateway or KMS addresses

**Severity: High** — breaks when addresses change; use config contracts instead.

```solidity
// WRONG
address constant GATEWAY = 0x1234...;

// CORRECT — inherit from config which sets addresses correctly
contract MyContract is SepoliaConfig { ... }
```

---

## Category 5 — Frontend Mistakes

### AP-17: Sending plaintext to encrypted parameter

**Severity: High** — tx reverts with type mismatch.

```typescript
// WRONG
await contract.transfer(recipient, 1000, proof);

// CORRECT
const buffer = instance.createEncryptedInput(contractAddress, userAddress);
buffer.add64(BigInt(1000));
const enc = await buffer.encrypt();
await contract.transfer(recipient, enc.handles[0], enc.inputProof);
```

---

### AP-18: Skipping await on encrypt()

**Severity: High** — passes `Promise` instead of encrypted data, tx fails silently.

```typescript
// WRONG
const enc = buffer.encrypt(); // Promise not result
await contract.transfer(to, enc.handles[0], enc.inputProof); // undefined

// CORRECT
const enc = await buffer.encrypt();
await contract.transfer(to, enc.handles[0], enc.inputProof);
```

---

### AP-19: Mismatching handle index to Solidity parameter position

**Severity: High** — wrong ciphertext sent to wrong parameter, validation fails.

```typescript
// If Solidity: function f(externalEuint64 amount, externalEbool flag, bytes proof)
// You must match buffer order to parameter order

buffer.add64(amount);  // handles[0] → amount
buffer.addBool(flag);  // handles[1] → flag
const enc = await buffer.encrypt();

// CORRECT
await contract.f(enc.handles[0], enc.handles[1], enc.inputProof);

// WRONG — swapped
await contract.f(enc.handles[1], enc.handles[0], enc.inputProof);
```

---

## Category 6 — ERC-7984 Specific Mistakes

### AP-20: Treating balanceOf as uint256

```solidity
// WRONG — returns euint64, not uint256
uint256 bal = token.balanceOf(user);

// CORRECT — decrypt client-side
const encBal = await token.balanceOf(userAddress);
const clear = await instance.userDecrypt(encBal, ...);
```

---

### AP-21: Using 18 decimals with euint64

`euint64` max is ~18.4 quintillion. With 18 decimals, max representable token amount is ~18 tokens.
Use 6 decimals.

---

### AP-22: Expecting standard ERC-20 Transfer events

ERC-7984 does not emit `Transfer(address, address, uint256)` events.
Amounts are confidential. Do not use ERC-20 indexers or event parsers with ERC-7984 tokens.

---

### AP-23: Missing ZamaConfig on ERC-7984 token

```solidity
// WRONG
contract MyToken is ERC7984 { ... }

// CORRECT
contract MyToken is SepoliaConfig, ERC7984 { ... }
```

---

## Quick Anti-Pattern Checklist

Before submitting any FHEVM contract, verify:

- [ ] Every FHE computation result has `FHE.allowThis` called on it
- [ ] Users who should decrypt their data have `FHE.allow(handle, user)` called
- [ ] All external inputs are validated with `FHE.fromExternal`
- [ ] No `if`/`require` on `ebool` — use `FHE.select`
- [ ] No arithmetic on `euint256`
- [ ] No encrypted divisor in `FHE.div` or `FHE.rem`
- [ ] All finalize functions have replay protection
- [ ] Contract inherits from `SepoliaConfig` or `EthereumConfig`
- [ ] No hardcoded gateway/KMS addresses
- [ ] Frontend uses `await buffer.encrypt()` before sending handles
- [ ] `checkSignatures` handle array order matches `publicDecrypt` call order
