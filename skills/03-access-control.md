# FHEVM Skill — 03: Access Control

## What This File Covers

- How the ACL works and why it exists
- Every ACL function with when to use each
- Common permission patterns
- Multi-contract permission flows
- Common mistakes that break access control

---

## Why ACL Exists

Encrypted values in FHEVM are ciphertext handles — `bytes32` references to encrypted data.
Without the ACL, no address (including your own contract) can reuse or decrypt a ciphertext
across transaction boundaries.

Every time you compute a new ciphertext (via `FHE.add`, `FHE.fromExternal`, etc.), the result
is a **new handle**. If you don't grant access to that new handle, it becomes permanently
inaccessible — even to the contract that created it.

The ACL is your permission ledger. You are responsible for maintaining it correctly.

---

## ACL Functions Reference

### `FHE.allowThis(ciphertext)`
Grants the current contract (`address(this)`) permanent access to the ciphertext.

Use this after every computation that produces a result you want to store and reuse.

```solidity
euint64 newBalance = FHE.add(balances[user], amount);
FHE.allowThis(newBalance); // contract can use newBalance in future transactions
balances[user] = newBalance;
```

### `FHE.allow(ciphertext, address)`
Grants permanent access to a specific external address.

Use this when a user should be able to decrypt a value (e.g. their own balance).

```solidity
FHE.allow(balances[user], user); // user can now decrypt their balance
```

### `FHE.allowTransient(ciphertext, address)`
Grants access **only for the current transaction**. Uses EIP-1153 transient storage.
Cheaper than permanent `FHE.allow` for values that don't need to persist.

Use this when passing ciphertexts to external contracts within the same transaction.

```solidity
FHE.allowTransient(amount, address(externalContract));
externalContract.processAmount(amount); // has access only during this tx
```

### `FHE.makePubliclyDecryptable(ciphertext)`
Marks a ciphertext as globally and permanently decryptable by anyone.

Use this for values meant to be revealed publicly (e.g. final auction result, vote tally).

```solidity
function revealResult() external onlyOwner {
    FHE.makePubliclyDecryptable(finalResult);
}
```

### `FHE.isAllowed(ciphertext, address) → bool`
Returns whether the given address has permission for the ciphertext.

```solidity
require(FHE.isAllowed(balance, msg.sender), "no access");
```

### `FHE.isSenderAllowed(ciphertext) → bool`
Shorthand for checking `msg.sender` permission.

```solidity
require(FHE.isSenderAllowed(balance), "not authorized");
```

---

## Permanent vs Transient Allowance

| | `FHE.allow` | `FHE.allowTransient` |
|--|-------------|----------------------|
| Scope | Permanent, across transactions | Current transaction only |
| Storage | Dedicated ACL contract | EIP-1153 transient storage |
| Gas cost | Higher | Lower |
| Use case | User balances, stored state | Passing to external contracts |

---

## Required ACL Pattern After Every State Mutation

This is the most critical pattern in FHEVM development. Every time you compute a new
ciphertext and store it, you must call `FHE.allowThis` on the result — otherwise
the contract cannot use it in future transactions.

```solidity
function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
    euint64 amount = FHE.fromExternal(encAmount, inputProof);

    // Initialize if first deposit
    if (!FHE.isInitialized(balances[msg.sender])) {
        balances[msg.sender] = FHE.asEuint64(0);
    }

    euint64 newBalance = FHE.add(balances[msg.sender], amount);

    // ✅ Grant contract access to new ciphertext
    FHE.allowThis(newBalance);

    // ✅ Grant user access so they can decrypt their balance
    FHE.allow(newBalance, msg.sender);

    balances[msg.sender] = newBalance;
}
```

---

## Transfer Pattern — Granting Access to Both Parties

```solidity
function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external {
    euint64 amount = FHE.fromExternal(encAmount, inputProof);

    // Safe subtraction — prevent underflow
    ebool canTransfer = FHE.ge(balances[msg.sender], amount);
    euint64 actualAmount = FHE.select(canTransfer, amount, FHE.asEuint64(0));

    euint64 newSenderBalance = FHE.sub(balances[msg.sender], actualAmount);
    euint64 newReceiverBalance = FHE.add(balances[to], actualAmount);

    // Grant contract access to both new ciphertexts
    FHE.allowThis(newSenderBalance);
    FHE.allowThis(newReceiverBalance);

    // Grant each user access to their own balance
    FHE.allow(newSenderBalance, msg.sender);
    FHE.allow(newReceiverBalance, to);

    balances[msg.sender] = newSenderBalance;
    balances[to] = newReceiverBalance;
}
```

---

## Multi-Contract Pattern — Passing Ciphertexts Between Contracts

When Contract A passes an encrypted value to Contract B:
- Contract A must grant Contract B access before calling it
- Use `allowTransient` if B only needs it within the same transaction

```solidity
// Contract A
function sendToVault(euint64 amount) external {
    FHE.allowTransient(amount, address(vault)); // give vault transient access
    vault.receive(amount);
}
```

```solidity
// Contract B (Vault)
function receive(euint64 amount) external {
    require(FHE.isSenderAllowed(amount), "no ACL permission");

    euint64 newTotal = FHE.add(total, amount);
    FHE.allowThis(newTotal); // vault now owns this handle
    total = newTotal;
}
```

---

## Common Mistakes

### Missing FHE.allowThis after mutation
```solidity
// WRONG — contract loses access to newBalance after this transaction
balances[user] = FHE.add(balances[user], amount);

// CORRECT
euint64 newBalance = FHE.add(balances[user], amount);
FHE.allowThis(newBalance);
balances[user] = newBalance;
```

### Granting access to original handle instead of new handle
```solidity
euint64 oldBalance = balances[user]; // handle A
euint64 newBalance = FHE.add(oldBalance, amount); // handle B — NEW handle

// WRONG — allowing old handle, not the new computed result
FHE.allowThis(oldBalance);

// CORRECT — always allow the result of the computation
FHE.allowThis(newBalance);
FHE.allow(newBalance, user);
balances[user] = newBalance;
```

### Using allowTransient for values that need to persist
```solidity
// WRONG — transient access expires after this transaction
FHE.allowTransient(balances[user], user);
// user cannot decrypt balance in a future separate transaction

// CORRECT — use permanent allow for user-facing data
FHE.allow(balances[user], user);
```

### Not granting access before passing to external contract
```solidity
// WRONG — externalContract has no ACL access, call will fail
externalContract.process(balance);

// CORRECT
FHE.allowTransient(balance, address(externalContract));
externalContract.process(balance);
```

### Calling makePubliclyDecryptable without ACL permission
```solidity
// WRONG — contract must have ACL access to the handle first
FHE.makePubliclyDecryptable(someExternalHandle);

// CORRECT — only call on ciphertexts your contract owns
FHE.allowThis(result);
FHE.makePubliclyDecryptable(result); // now contract has access, can mark it
```
