# Privacy-Preserving AI Bounty Judge

Forked from [cozfuttu/ritual-chain-workshop](https://github.com/cozfuttu/ritual-chain-workshop)

## Overview

This project implements a **commit-reveal scheme** on top of the existing Ritual AI Bounty Judge system. The goal is to prevent participants from copying each other's answers by hiding submissions until the judging phase.

---

## Lifecycle

### Phase 1 — Create Bounty
The bounty creator calls `createBounty()` with a title, rubric, reward (ETH), submission deadline, and reveal deadline.

### Phase 2 — Commit (Submission Phase)
Participants submit only a **commitment hash** — not their actual answer.

The hash is computed as:
keccak256(answer + salt + msg.sender + bountyId)
This is done off-chain, then submitted via `submitCommitment()`.
No one can see the actual answer at this stage.

### Phase 3 — Reveal (After Submission Deadline)
After the submission deadline, participants reveal their answer and salt via `revealAnswer()`.
The contract verifies that the hash matches the original commitment.
Only valid, revealed answers are eligible for AI judging.

### Phase 4 — Judge
The bounty owner calls `judgeAll()` after the reveal deadline.
All revealed answers are sent to the Ritual LLM for batch judging.
The AI reviews all answers based on the rubric.

### Phase 5 — Finalize
The bounty owner calls `finalizeWinner()` with the index of the winning submission.
The reward is sent directly to the winner's address.

---

## Contract Functions

| Function | Phase | Description |
|---|---|---|
| `createBounty()` | Setup | Create a new bounty with reward and deadlines |
| `submitCommitment()` | Commit | Submit a hash of your answer |
| `revealAnswer()` | Reveal | Reveal your actual answer and salt |
| `judgeAll()` | Judge | Send all revealed answers to Ritual LLM |
| `finalizeWinner()` | Finalize | Send reward to the winner |
| `computeCommitment()` | Helper | Compute your commitment hash off-chain |

---

## Architecture Note

### What is stored on-chain?
- Commitment hash (during commit phase)
- Revealed answer (after reveal phase)
- AI review result (after judging)
- Winner index and reward

### What stays off-chain?
- The actual answer and salt before reveal
- LLM prompt construction (built by the frontend)

### Where do plaintext answers exist?
- Only in the participant's own browser/wallet before reveal
- On-chain only after the reveal phase when the deadline has passed

### How does the LLM receive submissions?
- After the reveal deadline, all revealed answers are batched together
- The bounty owner constructs a single `llmInput` containing all answers
- One single LLM call via Ritual judges all answers at once (batch judging)

---

## Test Plan

See test cases in `/test/BountyJudge.test.js`

### Cases Covered:
- ✅ Valid commitment and reveal
- ✅ Wrong salt on reveal
- ✅ Wrong answer on reveal
- ✅ Reveal before deadline (should fail)
- ✅ Reveal after reveal deadline (should fail)
- ✅ Double commitment (should fail)
- ✅ Double reveal (should fail)
- ✅ Non-committed address tries to reveal (should fail)
- ✅ Winner who did not reveal cannot be finalized

---

## Reflection

What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?

In a bounty system, the bounty title, rubric, reward amount, and deadlines should all be public so participants know what they are competing for and under what rules. The actual answers must remain hidden during the submission phase to prevent copying, which is exactly what the commit-reveal scheme achieves. The salt used to generate the commitment hash should stay private until the reveal phase, as exposing it early would allow others to brute-force the answer. AI should be responsible for objective, rubric-based evaluation of all answers since it can process multiple submissions consistently and without bias. However, a human — the bounty owner — should make the final decision on the winner, as they understand the context and intent behind the bounty better than an AI. The on-chain finalization by the owner also adds accountability, since the decision is recorded publicly and permanently. This hybrid approach balances the efficiency of AI judgment with the contextual wisdom of human oversight, making the system both fair and transparent.

---

## How to Run

```bash
cd hardhat
pnpm install
pnpm hardhat compile
pnpm hardhat test
