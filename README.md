# FHEVM Agent Skill

An operational skill file bundle that enables AI coding agents
(Claude Code, Cursor, Windsurf) to accurately build, test, and deploy
confidential smart contracts using the Zama Protocol.

## What's inside

- 7 specialized skill files covering the full FHEVM workflow
- 23 documented anti-patterns with broken + correct code examples
- 3 production contract templates (voting, auction, ERC-7984 token)
- TypeScript frontend snippets
- Full test suite

## How to use

Drop `SKILL.md` into your AI coding agent's context, then prompt:

> "Write me a confidential voting contract using FHEVM"

The agent will produce correct, working code — input proofs validated,
ACL grants in place, no common pitfalls.

## Tested with

Claude Code — see demo video: https://youtu.be/48Llc79KDqU
