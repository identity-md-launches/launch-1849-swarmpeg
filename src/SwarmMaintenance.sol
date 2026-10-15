// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LaunchConstants} from "./LaunchConstants.sol";

/// @notice Ownerless maintenance pot. 100% of the hook fee funds holder-approved
/// swarm work. Approval pays a fixed recipient; it can never change deployed code.
contract SwarmMaintenance is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IERC20 public immutable votingToken;
    IERC20 public constant pairedToken = IERC20(LaunchConstants.IMD);
    uint256 public constant PROPOSAL_STAKE = 1_000_000 ether; // 0.1% of fixed supply
    uint256 public constant QUORUM = 10_000_000 ether; // 1% of fixed supply
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant EXECUTION_DELAY = 2 days;
    uint256 public constant EXECUTION_WINDOW = 14 days;

    struct Job {
        address recipient;
        uint64 voteEnd;
        bool closed;
        bool paid;
        uint256 amount;
        uint256 yes;
        uint256 no;
        bytes32 workHash;
    }

    struct Receipt {
        uint256 amount;
        bool voted;
    }

    uint256 public jobCount;
    uint256 public activeJob;
    uint256 public totalPaid;
    uint256 public escrowedVotes;
    mapping(uint256 id => Job) public jobs;
    mapping(uint256 id => mapping(address voter => Receipt)) public receipts;
    uint256 private _pendingRedemption;

    error InvalidConfiguration();
    error InvalidJob();
    error JobActive();
    error VotingClosed();
    error AlreadyVoted();
    error VoteLocked();
    error NothingToWithdraw();
    error NotExecutable();
    error OnlyExpectedManagerCallback();

    event FeesRedeemed(uint256 amount);
    event JobProposed(
        uint256 indexed id,
        address indexed proposer,
        address indexed recipient,
        uint256 amount,
        bytes32 workHash,
        uint256 voteEnd
    );
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 amount);
    event VoteWithdrawn(uint256 indexed id, address indexed voter, uint256 amount);
    event JobPaid(uint256 indexed id, address indexed recipient, uint256 amount, bytes32 workHash);
    event JobClosed(uint256 indexed id);

    constructor(IPoolManager manager_, IERC20 token_) {
        if (address(manager_) == address(0) || address(token_) == address(0) || address(token_) == address(pairedToken))
        {
            revert InvalidConfiguration();
        }
        poolManager = manager_;
        votingToken = token_;
    }

    function managedAssets() public view returns (uint256) {
        return pairedToken.balanceOf(address(this))
            + poolManager.balanceOf(address(this), uint256(uint160(address(pairedToken))));
    }

    /// @notice Redeems claims only to this pot, never to the caller. No reward can be
    /// extracted by spamming this function; it is safe for permissionless keepers.
    function redeemFees(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidJob();
        _redeem(amount);
    }

    /// @notice Propose payment for completed work, identified by a content hash.
    /// The proposer casts an initial affirmative vote with locked real tokens.
    function proposePayment(address recipient, uint256 amount, bytes32 workHash)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (activeJob != 0) revert JobActive();
        if (
            recipient == address(0) || recipient == address(this) || amount == 0 || amount > managedAssets()
                || workHash == bytes32(0)
        ) revert InvalidJob();
        id = ++jobCount;
        activeJob = id;
        uint64 end = uint64(block.timestamp + VOTING_PERIOD);
        jobs[id] = Job(recipient, end, false, false, amount, PROPOSAL_STAKE, 0, workHash);
        receipts[id][msg.sender] = Receipt(PROPOSAL_STAKE, true);
        escrowedVotes += PROPOSAL_STAKE;
        votingToken.safeTransferFrom(msg.sender, address(this), PROPOSAL_STAKE);
        emit JobProposed(id, msg.sender, recipient, amount, workHash, end);
        emit VoteCast(id, msg.sender, true, PROPOSAL_STAKE);
    }

    function vote(uint256 id, bool support, uint256 amount) external nonReentrant {
        Job storage job = jobs[id];
        if (id == 0 || id != activeJob || job.closed || block.timestamp >= job.voteEnd) revert VotingClosed();
        if (receipts[id][msg.sender].voted) revert AlreadyVoted();
        if (amount == 0) revert InvalidJob();
        receipts[id][msg.sender] = Receipt(amount, true);
        if (support) job.yes += amount;
        else job.no += amount;
        escrowedVotes += amount;
        votingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit VoteCast(id, msg.sender, support, amount);
    }

    /// @notice Votes remain counted after withdrawal, but withdrawal is only possible
    /// once all voting has ended. The same tokens cannot vote twice in one job.
    function withdrawVote(uint256 id) external nonReentrant {
        Job storage job = jobs[id];
        if (block.timestamp < job.voteEnd) revert VoteLocked();
        uint256 amount = receipts[id][msg.sender].amount;
        if (amount == 0) revert NothingToWithdraw();
        receipts[id][msg.sender].amount = 0;
        escrowedVotes -= amount;
        votingToken.safeTransfer(msg.sender, amount);
        emit VoteWithdrawn(id, msg.sender, amount);
    }

    function passed(uint256 id) public view returns (bool) {
        Job storage job = jobs[id];
        return id != 0 && job.voteEnd != 0 && block.timestamp >= job.voteEnd && job.yes >= QUORUM && job.yes > job.no;
    }

    function executePayment(uint256 id) external nonReentrant {
        Job storage job = jobs[id];
        if (
            id != activeJob || job.closed || !passed(id) || block.timestamp < uint256(job.voteEnd) + EXECUTION_DELAY
                || block.timestamp >= uint256(job.voteEnd) + EXECUTION_DELAY + EXECUTION_WINDOW
        ) revert NotExecutable();
        job.closed = true;
        job.paid = true;
        activeJob = 0;
        totalPaid += job.amount;
        uint256 liquid = pairedToken.balanceOf(address(this));
        if (liquid < job.amount) _redeem(job.amount - liquid);
        pairedToken.safeTransfer(job.recipient, job.amount);
        emit JobPaid(id, job.recipient, job.amount, job.workHash);
    }

    function closeJob(uint256 id) external nonReentrant {
        Job storage job = jobs[id];
        if (
            id == 0 || id != activeJob || job.closed || block.timestamp < job.voteEnd
                || (passed(id) && block.timestamp < uint256(job.voteEnd) + EXECUTION_DELAY + EXECUTION_WINDOW)
        ) {
            revert NotExecutable();
        }
        job.closed = true;
        activeJob = 0;
        emit JobClosed(id);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        uint256 amount = _pendingRedemption;
        if (msg.sender != address(poolManager) || amount == 0) revert OnlyExpectedManagerCallback();
        // Clear before interacting; even a hostile token cannot replay this callback.
        _pendingRedemption = 0;
        uint256 currencyId = uint256(uint160(address(pairedToken)));
        poolManager.burn(address(this), currencyId, amount);
        poolManager.take(Currency.wrap(address(pairedToken)), address(this), amount);
        emit FeesRedeemed(amount);
        return "";
    }

    function _redeem(uint256 amount) private {
        _pendingRedemption = amount;
        poolManager.unlock("");
        _pendingRedemption = 0;
    }
}
