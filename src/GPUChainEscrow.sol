// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GPUChainEscrow
/// @notice Holds a client's budget and releases it only on a quorum-signed verdict.
/// @dev UNAUDITED. Testnet only. Verifiers are a permissioned set and the arbiter is centralized;
///      this contract enforces payment rules, it does not prove any computation happened.
contract GPUChainEscrow is EIP712, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Funded,
        Active,
        Attested,
        Disputed,
        Settled,
        Refunded,
        Cancelled
    }

    /// @notice EIP-712 typed data. Must match docs/schemas/verdict.eip712.json.
    struct Verdict {
        bytes32 jobId;
        bool passed;
        bytes32 finalCheckpoint;
        bytes32 lineageRoot;
        bytes32 qualityReport;
        address[] payees;
        uint256[] amounts;
        uint256 refund;
        uint64 expiry;
    }

    struct Job {
        address client;
        uint64 deadline;
        State state;
        uint32 verifierSet;
        uint64 disputeWindow;
        uint64 disputeEnd;
        uint64 disputedAt;
        bool passed;
        uint256 budget;
        uint256 bond;
        uint256 refund;
        bytes32 specHash;
        bytes32 policyHash;
        bytes32 finalCheckpoint;
        address[] payees;
        uint256[] amounts;
        address arbiter; // Snapshot, like the verifier set: swapping it mustn't reach a running job.
    }

    bytes32 public constant VERDICT_TYPEHASH = keccak256(
        "Verdict(bytes32 jobId,bool passed,bytes32 finalCheckpoint,bytes32 lineageRoot,bytes32 qualityReport,address[] payees,uint256[] amounts,uint256 refund,uint64 expiry)"
    );

    uint256 public constant MAX_PAYEES = 8;
    uint256 public constant MAX_VERIFIERS = 16;
    uint64 public constant MAX_DISPUTE_WINDOW = 7 days;
    uint64 public constant REFUND_GRACE = 1 hours;
    uint64 public constant ARBITER_TIMEOUT = 3 days;

    IERC20 public immutable token;
    uint256 public immutable disputeBond;

    address public coordinator;
    address public arbiter;

    uint32 public currentVerifierSet;
    mapping(uint32 setId => uint256) public quorumOf;
    mapping(uint32 setId => mapping(address verifier => bool)) public isVerifier;

    mapping(bytes32 jobId => Job) private _jobs;
    mapping(address account => uint256) public withdrawable;

    /// @notice Solvency accounting: token balance must always equal the sum of these two.
    uint256 public totalLocked;
    uint256 public totalWithdrawable;

    event JobCreated(bytes32 indexed jobId, address indexed client, uint256 budget, bytes32 specHash, bytes32 policyHash);
    event JobCancelled(bytes32 indexed jobId);
    event JobActivated(bytes32 indexed jobId);
    event JobAnchor(bytes32 indexed jobId, uint8 indexed kind, uint32 attempt, bytes32 dataHash);
    event JobAttested(bytes32 indexed jobId, bool passed, bytes32 finalCheckpoint, uint64 disputeEnd);
    event JobDisputed(bytes32 indexed jobId, uint256 bond);
    event DisputeResolved(bytes32 indexed jobId, bool clientUpheld);
    event JobSettled(bytes32 indexed jobId, uint256 paid, uint256 refunded);
    event JobRefunded(bytes32 indexed jobId, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);
    event VerifierSetUpdated(uint32 indexed setId, address[] verifiers, uint256 quorum);
    event CoordinatorUpdated(address coordinator);
    event ArbiterUpdated(address arbiter);

    error NotClient();
    error NotCoordinator();
    error NotArbiter();
    error ZeroAddress();
    error JobExists();
    error ZeroBudget();
    error BadDeadline();
    error BadDisputeWindow();
    error WrongState(State actual);
    error VerdictExpired();
    error TooManyPayees();
    error LengthMismatch();
    error ZeroPayee();
    error FailedVerdictHasPayees();
    error AmountsDoNotMatchBudget();
    error NotEnoughSignatures();
    error SignersNotAscending();
    error UnknownVerifier(address signer);
    error WindowStillOpen();
    error WindowClosed();
    error NothingToDispute();
    error TooEarly();
    error NothingToWithdraw();
    error BadVerifierSet();

    constructor(
        IERC20 token_,
        address owner_,
        address coordinator_,
        address arbiter_,
        address[] memory verifiers,
        uint256 quorum,
        uint256 disputeBond_
    ) EIP712("GPUChainEscrow", "1") Ownable(owner_) {
        if (address(token_) == address(0) || coordinator_ == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        token = token_;
        disputeBond = disputeBond_;
        coordinator = coordinator_;
        arbiter = arbiter_;
        _setVerifiers(verifiers, quorum);
    }

    // ---------------------------------------------------------------- client

    /// @notice Locks the budget. The token approval must equal or exceed `budget`.
    function createJob(
        bytes32 jobId,
        bytes32 specHash,
        bytes32 policyHash,
        uint256 budget,
        uint64 deadline,
        uint64 disputeWindow
    ) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.state != State.None) revert JobExists();
        if (budget == 0) revert ZeroBudget();
        if (deadline <= block.timestamp) revert BadDeadline();
        if (disputeWindow == 0 || disputeWindow > MAX_DISPUTE_WINDOW) revert BadDisputeWindow();

        job.client = msg.sender;
        job.deadline = deadline;
        job.state = State.Funded;
        job.verifierSet = currentVerifierSet; // Snapshot: the set can't change under a running job.
        job.arbiter = arbiter;
        job.disputeWindow = disputeWindow;
        job.budget = budget;
        job.specHash = specHash;
        job.policyHash = policyHash;
        totalLocked += budget;

        emit JobCreated(jobId, msg.sender, budget, specHash, policyHash);
        token.safeTransferFrom(msg.sender, address(this), budget);
    }

    /// @notice Client takes the budget back before any work starts.
    function cancel(bytes32 jobId) external {
        Job storage job = _jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.state != State.Funded) revert WrongState(job.state);
        job.state = State.Cancelled;
        _release(job.budget);
        _credit(job.client, job.budget);
        emit JobCancelled(jobId);
    }

    /// @notice Disputes a passing verdict inside the window. Posts a bond.
    function dispute(bytes32 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.state != State.Attested) revert WrongState(job.state);
        if (block.timestamp >= job.disputeEnd) revert WindowClosed();
        if (!job.passed) revert NothingToDispute(); // A failed verdict already refunds the client in full.

        job.state = State.Disputed;
        job.disputedAt = uint64(block.timestamp);
        job.bond = disputeBond;
        totalLocked += disputeBond;

        emit JobDisputed(jobId, disputeBond);
        token.safeTransferFrom(msg.sender, address(this), disputeBond);
    }

    // ----------------------------------------------------------- coordinator

    function markActive(bytes32 jobId) external {
        if (msg.sender != coordinator) revert NotCoordinator();
        Job storage job = _jobs[jobId];
        if (job.state != State.Funded) revert WrongState(job.state);
        if (block.timestamp >= job.deadline) revert BadDeadline();
        job.state = State.Active;
        emit JobActivated(jobId);
    }

    /// @notice Records a hash of an off-chain event. A log only: it moves no funds and changes no state.
    function anchorEvent(bytes32 jobId, uint8 kind, uint32 attempt, bytes32 dataHash) external {
        if (msg.sender != coordinator) revert NotCoordinator();
        Job storage job = _jobs[jobId];
        if (job.state != State.Active) revert WrongState(job.state);
        emit JobAnchor(jobId, kind, attempt, dataHash);
    }

    // ------------------------------------------------------------ settlement

    /// @notice Anyone may submit a verdict carrying enough verifier signatures.
    /// @param signatures Ordered so the recovered signers are strictly ascending, which rejects duplicates.
    function submitAttestation(Verdict calldata verdict, bytes[] calldata signatures) external {
        Job storage job = _jobs[verdict.jobId];
        if (job.state != State.Active) revert WrongState(job.state);
        if (block.timestamp > verdict.expiry) revert VerdictExpired();
        if (verdict.payees.length > MAX_PAYEES) revert TooManyPayees();
        if (verdict.payees.length != verdict.amounts.length) revert LengthMismatch();
        if (!verdict.passed && verdict.payees.length != 0) revert FailedVerdictHasPayees();

        uint256 total = verdict.refund;
        for (uint256 i; i < verdict.payees.length; ++i) {
            if (verdict.payees[i] == address(0)) revert ZeroPayee();
            total += verdict.amounts[i];
        }
        if (total != job.budget) revert AmountsDoNotMatchBudget();

        _checkSignatures(hashVerdict(verdict), signatures, job.verifierSet);

        job.state = State.Attested;
        job.passed = verdict.passed;
        job.finalCheckpoint = verdict.finalCheckpoint;
        job.payees = verdict.payees;
        job.amounts = verdict.amounts;
        job.refund = verdict.refund;
        job.disputeEnd = uint64(block.timestamp) + job.disputeWindow;

        emit JobAttested(verdict.jobId, verdict.passed, verdict.finalCheckpoint, job.disputeEnd);
    }

    /// @notice Anyone may finalize once the dispute window has closed.
    function finalize(bytes32 jobId) external {
        Job storage job = _jobs[jobId];
        if (job.state != State.Attested) revert WrongState(job.state);
        if (block.timestamp < job.disputeEnd) revert WindowStillOpen();
        _applyVerdict(jobId, job);
    }

    /// @notice The arbiter decides a dispute by setting the final split across the verdict's payees.
    /// @param clientUpheld True returns the bond to the client. False forfeits it to the arbiter.
    function resolveDispute(bytes32 jobId, uint256[] calldata amounts, uint256 refund, bool clientUpheld) external {
        Job storage job = _jobs[jobId];
        if (msg.sender != job.arbiter) revert NotArbiter(); // Whoever was arbiter when the job was funded.
        if (job.state != State.Disputed) revert WrongState(job.state);
        if (amounts.length != job.payees.length) revert LengthMismatch();
        uint256 total = refund;
        for (uint256 i; i < amounts.length; ++i) {
            total += amounts[i];
        }
        if (total != job.budget) revert AmountsDoNotMatchBudget();

        job.amounts = amounts;
        job.refund = refund;
        _settleBond(job, clientUpheld ? job.client : job.arbiter);
        emit DisputeResolved(jobId, clientUpheld);
        _applyVerdict(jobId, job);
    }

    /// @notice If the arbiter stays silent the verdict stands and the bond is returned.
    /// @dev Known MVP limit: colluding verifiers plus a silent arbiter cost the client. Disclosed in docs.
    function finalizeAfterArbiterTimeout(bytes32 jobId) external {
        Job storage job = _jobs[jobId];
        if (job.state != State.Disputed) revert WrongState(job.state);
        if (block.timestamp < job.disputedAt + ARBITER_TIMEOUT) revert TooEarly();
        _settleBond(job, job.client);
        _applyVerdict(jobId, job);
    }

    /// @notice Permissionless refund after the deadline, so funds survive a dead coordinator.
    function claimTimeoutRefund(bytes32 jobId) external {
        Job storage job = _jobs[jobId];
        if (job.state != State.Funded && job.state != State.Active) revert WrongState(job.state);
        if (block.timestamp < job.deadline + REFUND_GRACE) revert TooEarly();
        job.state = State.Refunded;
        _release(job.budget);
        _credit(job.client, job.budget);
        emit JobRefunded(jobId, job.budget);
    }

    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        totalWithdrawable -= amount;
        emit Withdrawal(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Adds a new verifier set for future jobs. Existing jobs keep their snapshot.
    function setVerifiers(address[] calldata verifiers, uint256 quorum) external onlyOwner {
        _setVerifiers(verifiers, quorum);
    }

    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorUpdated(coordinator_);
    }

    /// @notice Applies to jobs created from now on. Existing jobs keep their snapshot.
    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        emit ArbiterUpdated(arbiter_);
    }

    // ------------------------------------------------------------------ view

    function getJob(bytes32 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function hashVerdict(Verdict calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VERDICT_TYPEHASH,
                    v.jobId,
                    v.passed,
                    v.finalCheckpoint,
                    v.lineageRoot,
                    v.qualityReport,
                    keccak256(abi.encodePacked(v.payees)),
                    keccak256(abi.encodePacked(v.amounts)),
                    v.refund,
                    v.expiry
                )
            )
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // -------------------------------------------------------------- internal

    function _checkSignatures(bytes32 digest, bytes[] calldata signatures, uint32 setId) private view {
        if (signatures.length < quorumOf[setId]) revert NotEnoughSignatures();
        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            // ECDSA.recover rejects malleable signatures and the zero address.
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= previous) revert SignersNotAscending();
            if (!isVerifier[setId][signer]) revert UnknownVerifier(signer);
            previous = signer;
        }
    }

    function _applyVerdict(bytes32 jobId, Job storage job) private {
        uint256 paid;
        _release(job.budget);
        for (uint256 i; i < job.payees.length; ++i) {
            paid += job.amounts[i];
            _credit(job.payees[i], job.amounts[i]);
        }
        _credit(job.client, job.refund);
        if (paid == 0) {
            job.state = State.Refunded;
            emit JobRefunded(jobId, job.refund);
        } else {
            job.state = State.Settled;
            emit JobSettled(jobId, paid, job.refund);
        }
    }

    function _settleBond(Job storage job, address to) private {
        uint256 bond = job.bond;
        job.bond = 0;
        _release(bond);
        _credit(to, bond);
    }

    function _release(uint256 amount) private {
        totalLocked -= amount;
    }

    function _credit(address account, uint256 amount) private {
        withdrawable[account] += amount;
        totalWithdrawable += amount;
    }

    function _setVerifiers(address[] memory verifiers, uint256 quorum) private {
        if (verifiers.length == 0 || verifiers.length > MAX_VERIFIERS) revert BadVerifierSet();
        if (quorum == 0 || quorum > verifiers.length) revert BadVerifierSet();
        uint32 setId = ++currentVerifierSet;
        for (uint256 i; i < verifiers.length; ++i) {
            address verifier = verifiers[i];
            if (verifier == address(0) || isVerifier[setId][verifier]) revert BadVerifierSet();
            isVerifier[setId][verifier] = true;
        }
        quorumOf[setId] = quorum;
        emit VerifierSetUpdated(setId, verifiers, quorum);
    }
}
