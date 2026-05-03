# FHEVM Skill — 02: Encrypted Types and Operations

## What This File Covers

- Full type reference with bit lengths and supported operators
- Casting between types
- Every FHE operation with correct syntax
- Encrypted randomness
- Type-specific constraints and gotchas
- Common mistakes per operation category

---

## Encrypted Types Reference

| Type | Bit Length | Notes |
|------|-----------|-------|
| `ebool` | 2 | Encrypted boolean. Supports logical ops only. |
| `euint8` | 8 | Full arithmetic + bitwise + comparison |
| `euint16` | 16 | Full arithmetic + bitwise + comparison |
| `euint32` | 32 | Full arithmetic + bitwise + comparison |
| `euint64` | 64 | Most common for token amounts and balances |
| `euint128` | 128 | Full arithmetic + bitwise + comparison |
| `euint256` | 256 | No arithmetic — bitwise + comparison only |
| `eaddress` | 160 | Alias for euint160. Supports `eq`, `ne`, `select` only |

**euint256 does NOT support arithmetic.** Use `euint128` if you need large-number math.

---

## Declaring State Variables

```solidity
contract MyContract is ZamaEthereumConfig {
    euint64 private totalSupply;
    ebool private isActive;
    eaddress private encryptedOwner;

    mapping(address => euint64) private balances;
    mapping(address => ebool) private approvals;
}
```

Encrypted state variables default to uninitialized. Always check with `FHE.isInitialized()`
before operating on them.

---

## Initialization and Casting

### Check if initialized before use
```solidity
if (!FHE.isInitialized(balances[user])) {
    balances[user] = FHE.asEuint64(0);
}
```

### Cast plaintext to encrypted
```solidity
euint64 encVal   = FHE.asEuint64(100);      // plaintext uint → euint64
euint32 encVal32 = FHE.asEuint32(50);
ebool   encBool  = FHE.asEbool(true);
eaddress encAddr = FHE.asEaddress(msg.sender);
```

### Cast between encrypted types
```solidity
euint64 big   = FHE.asEuint64(1000);
euint32 small = FHE.asEuint32(big);   // downcast — truncates if value exceeds uint32 max
euint128 wider = FHE.asEuint128(big); // upcast — safe
ebool asBool  = FHE.asEbool(big);     // non-zero → true, zero → false
```

### Validate and convert external (user) inputs
```solidity
// Always use FHE.fromExternal for user-supplied encrypted inputs
euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
ebool   flag   = FHE.fromExternal(encryptedFlag, inputProof);
eaddress addr  = FHE.fromExternal(encryptedAddr, inputProof);
```

---

## Arithmetic Operations

Supported on: `euint8`, `euint16`, `euint32`, `euint64`, `euint128`

```solidity
euint64 a = FHE.asEuint64(100);
euint64 b = FHE.asEuint64(40);

euint64 sum  = FHE.add(a, b);   // 140
euint64 diff = FHE.sub(a, b);   // 60
euint64 prod = FHE.mul(a, b);   // 4000
euint64 neg  = FHE.neg(a);      // two's complement negation
euint64 mn   = FHE.min(a, b);   // 40
euint64 mx   = FHE.max(a, b);   // 100
```

### Division and Remainder — plaintext divisor ONLY
```solidity
// CORRECT — plaintext rhs
euint64 half    = FHE.div(a, 2);
euint64 remains = FHE.rem(a, 3);

// WRONG — will panic at runtime
euint64 b_enc = FHE.asEuint64(2);
euint64 result = FHE.div(a, b_enc); // ← PANICS
```

### Overflow behavior
Arithmetic is **unchecked** — it wraps around silently on overflow.
This is intentional: revealing an overflow would leak information about the plaintext.

```solidity
euint8 max     = FHE.asEuint8(255);
euint8 wrapped = FHE.add(max, FHE.asEuint8(1)); // wraps to 0 silently
```

---

## Bitwise Operations

Supported on all euint types and ebool.

```solidity
euint64 andResult  = FHE.and(a, b);
euint64 orResult   = FHE.or(a, b);
euint64 xorResult  = FHE.xor(a, b);
euint64 notResult  = FHE.not(a);
euint64 shiftLeft  = FHE.shl(a, 2);   // shift left by plaintext amount
euint64 shiftRight = FHE.shr(a, 2);   // shift right by plaintext amount
euint64 rotLeft    = FHE.rotl(a, 2);  // rotate left
euint64 rotRight   = FHE.rotr(a, 2);  // rotate right
```

---

## Comparison Operations

All comparisons return `ebool`, not `bool`.

```solidity
ebool isEqual   = FHE.eq(a, b);
ebool notEqual  = FHE.ne(a, b);
ebool lessThan  = FHE.lt(a, b);
ebool lessEq    = FHE.le(a, b);
ebool greaterThan = FHE.gt(a, b);
ebool greaterEq   = FHE.ge(a, b);
```

You cannot use these results in Solidity `if` statements directly.
Use `FHE.select` for conditional logic instead.

---

## Conditional Logic with FHE.select

`FHE.select` is the FHE equivalent of a ternary. It takes an encrypted condition
and returns one of two encrypted values.

```solidity
euint64 balance = FHE.asEuint64(100);
euint64 amount  = FHE.asEuint64(150);

// select the smaller of two: if amount > balance, use balance
ebool   exceeds = FHE.gt(amount, balance);
euint64 actual  = FHE.select(exceeds, balance, amount);
// actual = balance if exceeds is true, else amount
```

### Pattern: clamped subtraction (prevent underflow)
```solidity
function _safeSub(euint64 a, euint64 b) internal returns (euint64) {
    ebool underflows = FHE.lt(a, b);
    return FHE.select(underflows, FHE.asEuint64(0), FHE.sub(a, b));
}
```

---

## Encrypted Randomness

```solidity
euint8   r8   = FHE.randEuint8();
euint16  r16  = FHE.randEuint16();
euint32  r32  = FHE.randEuint32();
euint64  r64  = FHE.randEuint64();
euint128 r128 = FHE.randEuint128();
euint256 r256 = FHE.randEuint256();
ebool    rb   = FHE.randEbool();

// Bounded random — value in range [0, upperBound)
euint64 bounded = FHE.randEuint64Bounded(100); // 0 to 99
```

Random values are generated on-chain using the FHE key — they are encrypted from birth
and never exposed as plaintext.

---

## Common Mistakes

### Using encrypted values in require() or if()
```solidity
// WRONG — ebool is not bool, this will not compile
euint64 balance = balances[msg.sender];
require(balance > 0, "no balance"); // ← type error

// CORRECT — use FHE.select to handle conditional logic in encrypted form
ebool   hasBalance = FHE.gt(balance, FHE.asEuint64(0));
euint64 safeResult = FHE.select(hasBalance, doSomething, FHE.asEuint64(0));
```

### Arithmetic on euint256
```solidity
// WRONG — euint256 has no arithmetic support
euint256 result = FHE.add(a256, b256); // ← will not compile

// CORRECT — use euint128 for large arithmetic needs
euint128 result = FHE.add(a128, b128);
```

### Forgetting to initialize before operating
```solidity
// WRONG — uninitialized euint64 will cause unexpected behavior
balances[newUser] = FHE.add(balances[newUser], amount);

// CORRECT
if (!FHE.isInitialized(balances[newUser])) {
    balances[newUser] = FHE.asEuint64(0);
}
balances[newUser] = FHE.add(balances[newUser], amount);
FHE.allowThis(balances[newUser]);
```

### Using encrypted divisor in div/rem
```solidity
// WRONG — panics at runtime
euint64 result = FHE.div(a, b); // b is euint64

// CORRECT — divisor must be plaintext
euint64 result = FHE.div(a, 4);
```

### Downcasting without considering truncation
```solidity
euint64 big   = FHE.asEuint64(300);
euint8  small = FHE.asEuint8(big); // silently truncates to 44 (300 % 256)
// no error thrown — value is silently wrong
```
