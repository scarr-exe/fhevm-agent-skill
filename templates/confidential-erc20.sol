// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title ConfidentialToken
 * @notice ERC-7984 confidential token with encrypted balances and private transfers.
 *         All balance and transfer amounts are represented as ciphertext handles.
 *         No plaintext amounts are ever exposed on-chain.
 *
 * @dev Built on OpenZeppelin Confidential Contracts + Zama FHEVM.
 *      Decimals: 6 (recommended for euint64 range)
 *
 * Usage:
 *   - Mint: owner calls mint() with encrypted amount + inputProof
 *   - Transfer: user encrypts amount client-side, calls transfer() with handle + proof
 *   - Read balance: user calls getEncryptedBalance(), decrypts off-chain via relayer SDK
 */

import { FHE, externalEuint64, euint64 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { ERC7984 } from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ConfidentialToken is SepoliaConfig, ERC7984, Ownable2Step {

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param owner Initial owner with minting rights
     * @param name_ Token name (e.g. "Confidential USD")
     * @param symbol_ Token symbol (e.g. "cUSD")
     * @param contractURI_ Metadata URI (ERC-7572)
     */
    constructor(
        address owner,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    ) ERC7984(name_, symbol_, contractURI_) Ownable(owner) {}

    // -------------------------------------------------------------------------
    // Mint / Burn
    // -------------------------------------------------------------------------

    /**
     * @notice Mint tokens with a fully encrypted amount.
     *         Only owner can call this.
     * @param to Recipient address
     * @param encAmount Encrypted amount handle (from createEncryptedInput)
     * @param inputProof ZKPoK proving sender knows the plaintext
     */
    function mint(
        address to,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyOwner {
        _mint(to, FHE.fromExternal(encAmount, inputProof));
    }

    /**
     * @notice Burn tokens from an address.
     *         Only owner can call this.
     * @param from Address to burn from
     * @param encAmount Encrypted amount handle
     * @param inputProof ZKPoK proving sender knows the plaintext
     */
    function burn(
        address from,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyOwner {
        _burn(from, FHE.fromExternal(encAmount, inputProof));
    }

    // -------------------------------------------------------------------------
    // Balance Queries
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the encrypted balance handle for msg.sender.
     *         The caller must have ACL access to their balance (granted at mint/transfer).
     *         Decrypt off-chain using the relayer SDK userDecrypt().
     */
    function getEncryptedBalance() external view returns (euint64) {
        require(FHE.isSenderAllowed(balanceOf(msg.sender)), "no ACL access");
        return balanceOf(msg.sender);
    }
}

// =============================================================================
// FRONTEND USAGE EXAMPLE (TypeScript)
// =============================================================================
//
// --- MINT (owner) ---
// const buffer = instance.createEncryptedInput(tokenAddress, ownerAddress);
// buffer.add64(BigInt(1000_000)); // 1.0 token with 6 decimals
// const enc = await buffer.encrypt();
// await token.connect(owner).mint(recipientAddress, enc.handles[0], enc.inputProof);
//
// --- TRANSFER ---
// const buffer = instance.createEncryptedInput(tokenAddress, senderAddress);
// buffer.add64(BigInt(250_000)); // 0.25 token
// const enc = await buffer.encrypt();
// await token.connect(sender)["transfer(address,bytes32,bytes)"](
//   recipientAddress, enc.handles[0], enc.inputProof
// );
//
// --- READ BALANCE ---
// const encBalance = await token.connect(user).getEncryptedBalance();
// const { publicKey, privateKey } = instance.generateKeypair();
// const eip712 = instance.createEIP712(publicKey, tokenAddress);
// const signature = await signer.signTypedData(eip712.domain, eip712.types, eip712.message);
// const clearBalance = await instance.userDecrypt(
//   encBalance, privateKey, publicKey, signature, tokenAddress, userAddress
// );
// console.log("Balance:", clearBalance); // e.g. 1000000n (= 1.0 token)
