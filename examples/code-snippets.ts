/**
 * FHEVM Frontend Code Snippets
 * Common TypeScript patterns for interacting with FHEVM contracts.
 * Reference this file for frontend integration work.
 */

import { createInstance, SepoliaConfig, MainnetConfig } from "@zama-fhe/relayer-sdk";
import { ethers } from "ethers";

// =============================================================================
// 1. INITIALIZE SDK
// =============================================================================

// Sepolia (development)
export async function initSepolia(provider?: ethers.Eip1193Provider) {
  return createInstance({
    ...SepoliaConfig,
    network: provider ?? "https://ethereum-sepolia-rpc.publicnode.com",
  });
}

// Mainnet (requires API key)
export async function initMainnet(provider?: ethers.Eip1193Provider) {
  return createInstance({
    ...MainnetConfig,
    network: provider ?? "https://ethereum-rpc.publicnode.com",
    auth: {
      __type: "ApiKeyHeader",
      value: process.env.ZAMA_FHEVM_API_KEY!,
    },
  });
}

// With MetaMask
export async function initWithMetaMask() {
  return createInstance({
    ...SepoliaConfig,
    network: window.ethereum,
  });
}

// =============================================================================
// 2. ENCRYPT USER INPUTS
// =============================================================================

// Encrypt a single uint64
export async function encryptUint64(
  instance: Awaited<ReturnType<typeof createInstance>>,
  contractAddress: string,
  userAddress: string,
  value: bigint
) {
  const buffer = instance.createEncryptedInput(contractAddress, userAddress);
  buffer.add64(value);
  const enc = await buffer.encrypt();
  return { handle: enc.handles[0], proof: enc.inputProof };
}

// Encrypt multiple values in one input (one shared proof)
export async function encryptTransferParams(
  instance: Awaited<ReturnType<typeof createInstance>>,
  contractAddress: string,
  userAddress: string,
  amount: bigint,
  canTransfer: boolean
) {
  const buffer = instance.createEncryptedInput(contractAddress, userAddress);
  buffer.add64(amount);    // handles[0]
  buffer.addBool(canTransfer); // handles[1]
  const enc = await buffer.encrypt();
  return {
    amountHandle:   enc.handles[0],
    boolHandle:     enc.handles[1],
    inputProof:     enc.inputProof,
  };
}

// =============================================================================
// 3. USER DECRYPTION (private — user sees only their own data)
// =============================================================================

export async function userDecryptBalance(
  instance: Awaited<ReturnType<typeof createInstance>>,
  contract: ethers.Contract,
  signer: ethers.Signer,
  userAddress: string
): Promise<bigint> {
  // 1. Get encrypted handle from contract
  const encHandle = await contract.getEncryptedBalance();

  // 2. Generate temporary keypair for re-encryption
  const { publicKey, privateKey } = instance.generateKeypair();

  // 3. Create EIP-712 signing request
  const contractAddress = await contract.getAddress();
  const eip712 = instance.createEIP712(publicKey, contractAddress);

  // 4. User signs (triggers wallet prompt)
  const signature = await signer.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
  );

  // 5. Decrypt via KMS
  const clearValue = await instance.userDecrypt(
    encHandle,
    privateKey,
    publicKey,
    signature,
    contractAddress,
    userAddress
  );

  return clearValue as bigint;
}

// =============================================================================
// 4. PUBLIC DECRYPTION (anyone can read after contract reveals)
// =============================================================================

// Decrypt a single publicly revealed value
export async function publicDecryptSingle(
  instance: Awaited<ReturnType<typeof createInstance>>,
  handle: string
): Promise<bigint | boolean> {
  const results = await instance.publicDecrypt([handle]);
  return results.clearValues[handle as `0x${string}`] as bigint | boolean;
}

// Decrypt multiple values at once — order must match on-chain checkSignatures
export async function publicDecryptMultiple(
  instance: Awaited<ReturnType<typeof createInstance>>,
  handles: string[]
) {
  const results = await instance.publicDecrypt(handles);
  return {
    clearValues:     results.clearValues,
    decryptionProof: results.decryptionProof,
    abiEncoded:      results.abiEncodedClearValues,
  };
}

// =============================================================================
// 5. SUBMIT DECRYPTION PROOF ON-CHAIN (after publicDecrypt)
// =============================================================================

// Example: reveal auction result
export async function submitAuctionResult(
  contract: ethers.Contract,
  signer: ethers.Signer,
  instance: Awaited<ReturnType<typeof createInstance>>,
  winnerBidHandle: string,
  winnerAddrHandle: string
) {
  // Decrypt both values — order matches on-chain handles array
  const results = await instance.publicDecrypt([
    winnerBidHandle,   // index 0
    winnerAddrHandle   // index 1
  ]);

  const clearBid     = results.clearValues[winnerBidHandle as `0x${string}`] as bigint;
  const clearWinner  = results.clearValues[winnerAddrHandle as `0x${string}`] as string;
  const proof        = results.decryptionProof;

  const tx = await contract.connect(signer).revealWinner(
    clearBid,
    clearWinner,
    proof
  );
  await tx.wait();
  return { clearBid, clearWinner };
}

// =============================================================================
// 6. ERC-7984 TOKEN INTERACTIONS
// =============================================================================

// Transfer tokens
export async function confidentialTransfer(
  instance: Awaited<ReturnType<typeof createInstance>>,
  token: ethers.Contract,
  signer: ethers.Signer,
  senderAddress: string,
  recipientAddress: string,
  amount: bigint
) {
  const tokenAddress = await token.getAddress();
  const buffer = instance.createEncryptedInput(tokenAddress, senderAddress);
  buffer.add64(amount);
  const enc = await buffer.encrypt();

  // Use the transferWithProof variant (function selector for overloaded func)
  const tx = await token
    .connect(signer)
    ["transfer(address,bytes32,bytes)"](
      recipientAddress,
      enc.handles[0],
      enc.inputProof
    );

  await tx.wait();
}

// Set operator (replaces ERC-20 approve)
export async function setOperator(
  token: ethers.Contract,
  signer: ethers.Signer,
  operatorAddress: string,
  durationHours: number = 24
) {
  const expirationTimestamp =
    Math.round(Date.now() / 1000) + durationHours * 60 * 60;

  const tx = await token
    .connect(signer)
    .setOperator(operatorAddress, expirationTimestamp);

  await tx.wait();
}

// =============================================================================
// 7. UTILITY HELPERS
// =============================================================================

// Format encrypted balance for display (6 decimals by default for ERC-7984)
export function formatConfidentialAmount(
  rawAmount: bigint,
  decimals: number = 6
): string {
  const divisor = BigInt(10 ** decimals);
  const whole   = rawAmount / divisor;
  const frac    = rawAmount % divisor;
  return `${whole}.${frac.toString().padStart(decimals, "0")}`;
}
