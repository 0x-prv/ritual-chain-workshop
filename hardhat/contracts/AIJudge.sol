// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ─── Structs ────────────────────────────────────────────────

    struct Submission {
        address submitter;
        string  answer;
        bytes32 commitment;
        bool    revealed;
    }

    struct Bounty {
        address owner;
        string  title;
        string  rubric;
        uint256 reward;
        uint256 deadline;
        uint256 revealDeadline;
        bool    judged;
        bool    finalized;
        bytes   aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // ─── State Variables ─────────────────────────────────────────

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(address => bool))    public hasCommitted;
    mapping(uint256 => mapping(address => uint256)) public submitterIndex;

    // ─── Events ──────────────────────────────────────────────────

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 submissionIndex
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ─── Modifiers ───────────────────────────────────────────────

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ─── Functions ───────────────────────────────────────────────

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline < revealDeadline, "reveal must be after deadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner          = msg.sender;
        bounty.title          = title;
        bounty.rubric         = rubric;
        bounty.reward         = msg.value;
        bounty.deadline       = deadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex    = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline, revealDeadline);
    }

    /// @notice Phase 1 — submit only a hash, answer stays hidden
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.deadline, "submission phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(!hasCommitted[bountyId][msg.sender], "already committed");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");

        hasCommitted[bountyId][msg.sender]   = true;
        submitterIndex[bountyId][msg.sender] = bounty.submissions.length;

        bounty.submissions.push(Submission({
            submitter:  msg.sender,
            answer:     "",
            commitment: commitment,
            revealed:   false
        }));

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    /// @notice Phase 2 — reveal answer after submission deadline
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline, "reveal phase not started");
        require(block.timestamp < bounty.revealDeadline, "reveal phase closed");
        require(hasCommitted[bountyId][msg.sender], "no commitment found");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 idx = submitterIndex[bountyId][msg.sender];
        Submission storage sub = bounty.submissions[idx];

        require(!sub.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(sub.commitment == expected, "commitment mismatch");

        sub.answer   = answer;
        sub.revealed = true;

        emit AnswerRevealed(bountyId, msg.sender, idx);
    }

    /// @notice Phase 3 — judge all revealed answers via Ritual LLM
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not ended");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged   = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Phase 4 — finalize and send reward to winner
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");
        require(bounty.submissions[winnerIndex].revealed, "winner did not reveal");

        bounty.finalized   = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward  = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ─── View Functions ──────────────────────────────────────────

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            string memory answer,
            bool revealed
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");

        Submission storage sub = bounty.submissions[index];
        return (
            sub.submitter,
            sub.revealed ? sub.answer : "",
            sub.revealed
        );
    }

    /// @notice Helper to compute commitment hash off-chain
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }
}
