import { expect } from "chai";
import hre from "hardhat";
import { time } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { keccak256, encodePacked, parseEther } from "viem";

describe("AIJudge - Commit Reveal", function () {
  async function deployFixture() {
    const [owner, alice, bob] = await hre.viem.getWalletClients();
    const publicClient = await hre.viem.getPublicClient();

    const aiJudge = await hre.viem.deployContract("AIJudge");

    const now = BigInt(await time.latest());
    const deadline = now + 3600n;       // 1 hour from now
    const revealDeadline = now + 7200n; // 2 hours from now

    await aiJudge.write.createBounty(
      ["Test Bounty", "Best answer wins", deadline, revealDeadline],
      { value: parseEther("1"), account: owner.account }
    );

    return { aiJudge, owner, alice, bob, publicClient, deadline, revealDeadline };
  }

  function makeCommitment(answer: string, salt: `0x${string}`, address: `0x${string}`, bountyId: bigint) {
    return keccak256(encodePacked(["string", "bytes32", "address", "uint256"], [answer, salt, address, bountyId]));
  }

  // ─── Valid Cases ─────────────────────────────────────────────

  it("should allow valid commitment and reveal", async function () {
    const { aiJudge, alice, deadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });

    await time.increaseTo(deadline + 1n);

    await aiJudge.write.revealAnswer([1n, answer, salt], { account: alice.account });

    const sub = await aiJudge.read.getSubmission([1n, 0n]);
    expect(sub[1]).to.equal(answer);
    expect(sub[2]).to.equal(true);
  });

  // ─── Wrong Salt ───────────────────────────────────────────────

  it("should fail reveal with wrong salt", async function () {
    const { aiJudge, alice, deadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const wrongSalt = "0x1111111111111111111111111111111111111111111111111111111111111111" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });
    await time.increaseTo(deadline + 1n);

    await expect(
      aiJudge.write.revealAnswer([1n, answer, wrongSalt], { account: alice.account })
    ).to.be.rejectedWith("commitment mismatch");
  });

  // ─── Wrong Answer ─────────────────────────────────────────────

  it("should fail reveal with wrong answer", async function () {
    const { aiJudge, alice, deadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });
    await time.increaseTo(deadline + 1n);

    await expect(
      aiJudge.write.revealAnswer([1n, "Wrong answer", salt], { account: alice.account })
    ).to.be.rejectedWith("commitment mismatch");
  });

  // ─── Reveal Before Deadline ───────────────────────────────────

  it("should fail reveal before deadline", async function () {
    const { aiJudge, alice } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });

    await expect(
      aiJudge.write.revealAnswer([1n, answer, salt], { account: alice.account })
    ).to.be.rejectedWith("reveal phase not started");
  });

  // ─── Reveal After Reveal Deadline ────────────────────────────

  it("should fail reveal after reveal deadline", async function () {
    const { aiJudge, alice, revealDeadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });
    await time.increaseTo(revealDeadline + 1n);

    await expect(
      aiJudge.write.revealAnswer([1n, answer, salt], { account: alice.account })
    ).to.be.rejectedWith("reveal phase closed");
  });

  // ─── Double Commitment ────────────────────────────────────────

  it("should fail double commitment", async function () {
    const { aiJudge, alice } = await deployFixture();

    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment("My answer", salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });

    await expect(
      aiJudge.write.submitCommitment([1n, commitment], { account: alice.account })
    ).to.be.rejectedWith("already committed");
  });

  // ─── Double Reveal ────────────────────────────────────────────

  it("should fail double reveal", async function () {
    const { aiJudge, alice, deadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment(answer, salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });
    await time.increaseTo(deadline + 1n);
    await aiJudge.write.revealAnswer([1n, answer, salt], { account: alice.account });

    await expect(
      aiJudge.write.revealAnswer([1n, answer, salt], { account: alice.account })
    ).to.be.rejectedWith("already revealed");
  });

  // ─── Non-committed Address ────────────────────────────────────

  it("should fail reveal from non-committed address", async function () {
    const { aiJudge, bob, deadline } = await deployFixture();

    const answer = "My answer";
    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;

    await time.increaseTo(deadline + 1n);

    await expect(
      aiJudge.write.revealAnswer([1n, answer, salt], { account: bob.account })
    ).to.be.rejectedWith("no commitment found");
  });

  // ─── Winner Did Not Reveal ────────────────────────────────────

  it("should fail finalize if winner did not reveal", async function () {
    const { aiJudge, owner, alice, revealDeadline } = await deployFixture();

    const salt = "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" as `0x${string}`;
    const commitment = makeCommitment("My answer", salt, alice.account.address, 1n);

    await aiJudge.write.submitCommitment([1n, commitment], { account: alice.account });
    await time.increaseTo(revealDeadline + 1n);

    // Skip reveal, try to finalize directly
    await expect(
      aiJudge.write.finalizeWinner([1n, 0n], { account: owner.account })
    ).to.be.rejectedWith("not judged yet");
  });
});
