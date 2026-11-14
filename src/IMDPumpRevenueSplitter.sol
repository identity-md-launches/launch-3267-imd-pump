// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IMD PUMP revenue splitter
/// @notice Splits eligible net platform revenue, delivered in IMD, into the IMD PUMP allocation
/// model: 20% IMD buyback-and-burn, 15% developer IMD rewards, 25% ecosystem treasury,
/// 20% development and operations, 20% NFT worker rewards. 35% of every unit of revenue is
/// therefore directed at IMD burns and developer IMD accumulation; 65% keeps the platform running.
///
/// How revenue arrives: the platform operator computes eligible net revenue off chain (net
/// platform revenue, never trading volume or users' funds), converts it to IMD, and sends the IMD
/// to this contract, either with a plain `transfer` followed by {distribute}, or in one call with
/// {depositAndDistribute}. Anyone may call {distribute}: it has no privileged effect, it only
/// applies the fixed split to whatever revenue is waiting.
///
/// How the burn works: the IMD token on Ethereum exposes no `burn` function, so a burn is a
/// transfer to the burn destination the owner configures with {setBurnSink}. Until that is set,
/// the burn share is held here and recorded in {pendingBurn}; every other share is paid out
/// immediately. Once the sink is set, {burnPending} (or the next {distribute}) sends everything
/// accumulated, including the share that accrued before the sink was named. Every burn emits
/// {BurnExecuted} with the amount and destination. That record proves a transfer to the configured
/// sink, not that the sink is a burn address: whoever verifies a burn checks the sink in
/// {BurnSinkUpdated} and {BurnExecuted} against the address the IMD project recognises as its
/// burn address.
///
/// Trust assumptions: the owner (the requester) can change the allocation, the four recipient
/// addresses and the burn sink, each through an event-emitting setter. The owner cannot touch
/// IMD PUMP holders' balances or any revenue already paid out. Every setter first distributes any
/// revenue already waiting here under the terms in force when it arrived, so a setting change
/// applies only to revenue delivered after it; a change and a permissionless {distribute} cannot
/// race over the same revenue. The one exception is {pendingBurn}: it is held until the owner
/// names the burn sink, so the sink the owner names receives it. Ownership moves only in two
/// steps; {renounceOwnership} is disabled because an ownerless splitter could never have its burn
/// sink set, stranding the burn share forever. The owner can recover tokens other than IMD that
/// were sent here by mistake.
contract IMDPumpRevenueSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator: every allocation sums to this.
    uint16 public constant BPS = 10_000;

    /// @notice Launch allocation: 20% of revenue buys and burns IMD.
    uint16 public constant LAUNCH_BURN_BPS = 2_000;
    /// @notice Launch allocation: 15% of revenue goes to the developer as IMD.
    uint16 public constant LAUNCH_DEVELOPER_BPS = 1_500;
    /// @notice Launch allocation: 25% of revenue goes to the IMD ecosystem treasury.
    uint16 public constant LAUNCH_TREASURY_BPS = 2_500;
    /// @notice Launch allocation: 20% of revenue funds development and operations.
    uint16 public constant LAUNCH_OPERATIONS_BPS = 2_000;
    /// @notice Launch allocation: 20% of revenue funds IMD NFT worker rewards.
    uint16 public constant LAUNCH_NFT_WORKERS_BPS = 2_000;

    /// @notice Shares of each unit of revenue, in basis points. Always sums to {BPS}.
    struct Allocation {
        uint16 burnBps;
        uint16 developerBps;
        uint16 treasuryBps;
        uint16 operationsBps;
        uint16 nftWorkersBps;
    }

    /// @notice Where each paid-out share goes. The burn share goes to {burnSink}.
    struct Recipients {
        address developer;
        address treasury;
        address operations;
        address nftWorkers;
    }

    /// @notice The revenue currency: IMD, the ERC-20 the launch pairs IMD PUMP with.
    IERC20 public immutable REVENUE_TOKEN;

    /// @notice The current allocation.
    Allocation public allocation;
    /// @notice The current recipients.
    Recipients public recipients;
    /// @notice The burn destination. Unset until the owner configures it with {setBurnSink}.
    address public burnSink;
    /// @notice IMD allocated to burning that is still held here because {burnSink} was unset
    /// when it was allocated.
    uint256 public pendingBurn;

    /// @notice Lifetime revenue that has been distributed through this contract.
    uint256 public totalDistributed;
    /// @notice Lifetime IMD sent to the burn sink.
    uint256 public totalBurned;
    /// @notice Lifetime IMD sent to the developer.
    uint256 public totalToDeveloper;

    event AllocationUpdated(
        uint16 burnBps, uint16 developerBps, uint16 treasuryBps, uint16 operationsBps, uint16 nftWorkersBps
    );
    event DeveloperUpdated(address indexed previous, address indexed current);
    event TreasuryUpdated(address indexed previous, address indexed current);
    event OperationsUpdated(address indexed previous, address indexed current);
    event NftWorkersUpdated(address indexed previous, address indexed current);
    event BurnSinkUpdated(address indexed previous, address indexed current);
    event RevenueDistributed(
        address indexed caller,
        uint256 revenue,
        uint256 burnShare,
        uint256 developerShare,
        uint256 treasuryShare,
        uint256 operationsShare,
        uint256 nftWorkersShare
    );
    event BurnDeferred(uint256 pendingBurn);
    event BurnExecuted(address indexed sink, uint256 amount);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error SelfRecipient();
    error InvalidAllocation(uint256 sum);
    error NothingToDistribute();
    error NothingToBurn();
    error BurnSinkNotConfigured();
    error RevenueTokenNotRecoverable();
    error ZeroAmount();
    error RenounceDisabled();

    /// @param owner_ The launch owner: the requester. Never the factory.
    /// @param payout_ The address that initially receives every paid-out share (developer,
    /// treasury, operations and NFT workers). The owner can re-point each one later.
    /// @param revenueToken_ The IMD token the revenue is delivered in.
    /// @dev Makes no external call: the launch runs constructors on an empty chain.
    constructor(address owner_, address payout_, address revenueToken_) Ownable(owner_) {
        if (payout_ == address(0) || revenueToken_ == address(0)) revert ZeroAddress();
        REVENUE_TOKEN = IERC20(revenueToken_);
        recipients = Recipients({developer: payout_, treasury: payout_, operations: payout_, nftWorkers: payout_});
        allocation = Allocation({
            burnBps: LAUNCH_BURN_BPS,
            developerBps: LAUNCH_DEVELOPER_BPS,
            treasuryBps: LAUNCH_TREASURY_BPS,
            operationsBps: LAUNCH_OPERATIONS_BPS,
            nftWorkersBps: LAUNCH_NFT_WORKERS_BPS
        });
        emit DeveloperUpdated(address(0), payout_);
        emit TreasuryUpdated(address(0), payout_);
        emit OperationsUpdated(address(0), payout_);
        emit NftWorkersUpdated(address(0), payout_);
        emit AllocationUpdated(
            LAUNCH_BURN_BPS, LAUNCH_DEVELOPER_BPS, LAUNCH_TREASURY_BPS, LAUNCH_OPERATIONS_BPS, LAUNCH_NFT_WORKERS_BPS
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Revenue flow
    // ---------------------------------------------------------------------------------------------

    /// @notice Pulls `amount` IMD from the caller and distributes everything waiting here.
    /// @dev Moves tokens only from `msg.sender`, so the caller must have approved this contract.
    function depositAndDistribute(uint256 amount) external nonReentrant returns (uint256 revenue) {
        if (amount == 0) revert ZeroAmount();
        REVENUE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        revenue = _distribute();
    }

    /// @notice Distributes all IMD revenue waiting here according to the current allocation.
    /// @dev Callable by anyone. Reverts if nothing new has arrived since the last distribution.
    function distribute() external nonReentrant returns (uint256 revenue) {
        revenue = _distribute();
    }

    /// @notice Sends every IMD allocated to burning to the configured burn sink.
    /// @dev Callable by anyone once the owner has set {burnSink}.
    function burnPending() external nonReentrant {
        if (burnSink == address(0)) revert BurnSinkNotConfigured();
        if (pendingBurn == 0) revert NothingToBurn();
        _executeBurn();
    }

    /// @notice IMD held here that has not been distributed yet (excludes {pendingBurn}).
    function undistributedRevenue() public view returns (uint256) {
        uint256 balance = REVENUE_TOKEN.balanceOf(address(this));
        uint256 pending = pendingBurn;
        return balance > pending ? balance - pending : 0;
    }

    /// @notice The shares {distribute} would pay right now, in the order burn, developer,
    /// treasury, operations, NFT workers. Rounding dust goes to the treasury.
    function previewDistribution()
        external
        view
        returns (
            uint256 burnShare,
            uint256 developerShare,
            uint256 treasuryShare,
            uint256 operationsShare,
            uint256 nftWorkersShare
        )
    {
        return _split(undistributedRevenue(), allocation);
    }

    /// @notice Basis points of revenue directed at IMD (burn plus developer rewards): 3,500 at launch.
    function imdDirectedBps() external view returns (uint16) {
        return allocation.burnBps + allocation.developerBps;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner settings
    // ---------------------------------------------------------------------------------------------
    // Every setter settles revenue that is already waiting before it writes, so revenue delivered
    // under the old allocation and recipients is paid under them, and only later revenue follows
    // the new setting. Without this, a setter and a permissionless {distribute} would race in the
    // mempool over whatever was in flight.

    /// @notice Replaces the allocation. The five shares must sum to exactly {BPS}.
    /// @dev Meant for the sustainability review the requester plans after three months. Revenue
    /// already waiting is distributed under the old allocation first.
    function setAllocation(
        uint16 burnBps,
        uint16 developerBps,
        uint16 treasuryBps,
        uint16 operationsBps,
        uint16 nftWorkersBps
    ) external nonReentrant onlyOwner {
        uint256 sum = uint256(burnBps) + developerBps + treasuryBps + operationsBps + nftWorkersBps;
        if (sum != BPS) revert InvalidAllocation(sum);
        _settleWaitingRevenue();
        allocation = Allocation({
            burnBps: burnBps,
            developerBps: developerBps,
            treasuryBps: treasuryBps,
            operationsBps: operationsBps,
            nftWorkersBps: nftWorkersBps
        });
        emit AllocationUpdated(burnBps, developerBps, treasuryBps, operationsBps, nftWorkersBps);
    }

    /// @notice Re-points the developer rewards recipient. Revenue already waiting is paid to the
    /// previous recipient first.
    function setDeveloper(address account) external nonReentrant onlyOwner {
        _checkRecipient(account);
        _settleWaitingRevenue();
        emit DeveloperUpdated(recipients.developer, account);
        recipients.developer = account;
    }

    /// @notice Re-points the IMD ecosystem treasury recipient. Revenue already waiting is paid to
    /// the previous recipient first.
    function setTreasury(address account) external nonReentrant onlyOwner {
        _checkRecipient(account);
        _settleWaitingRevenue();
        emit TreasuryUpdated(recipients.treasury, account);
        recipients.treasury = account;
    }

    /// @notice Re-points the development and operations recipient. Revenue already waiting is
    /// paid to the previous recipient first.
    function setOperations(address account) external nonReentrant onlyOwner {
        _checkRecipient(account);
        _settleWaitingRevenue();
        emit OperationsUpdated(recipients.operations, account);
        recipients.operations = account;
    }

    /// @notice Re-points the IMD NFT worker rewards recipient. Revenue already waiting is paid to
    /// the previous recipient first.
    function setNftWorkers(address account) external nonReentrant onlyOwner {
        _checkRecipient(account);
        _settleWaitingRevenue();
        emit NftWorkersUpdated(recipients.nftWorkers, account);
        recipients.nftWorkers = account;
    }

    /// @notice Sets the destination the burn share is sent to.
    /// @dev Required before any burn share leaves this contract. The IMD token has no burn
    /// function, so the IMD project's recognised burn address is what belongs here. The owner
    /// chooses this address: {pendingBurn}, including everything that accrued while the sink was
    /// unset, goes to whatever sink is configured when it is flushed, and {BurnExecuted} records
    /// that destination so anyone can check it is a genuine burn address. Revenue already waiting
    /// is distributed first, so its burn share follows the previous sink (or joins {pendingBurn}
    /// if none was set).
    function setBurnSink(address sink) external nonReentrant onlyOwner {
        if (sink == address(0)) revert ZeroAddress();
        if (sink == address(this)) revert SelfRecipient();
        _settleWaitingRevenue();
        emit BurnSinkUpdated(burnSink, sink);
        burnSink = sink;
    }

    /// @notice Disabled. Ownership moves only through {transferOwnership} and {acceptOwnership}.
    /// @dev An ownerless splitter could never have {burnSink} set or corrected, which would strand
    /// the burn share of all past and future revenue in this contract, and could never change the
    /// allocation or the recipients again.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Recovers a token other than IMD that was sent here by mistake.
    /// @dev IMD is revenue and can only leave through {distribute} and the burn.
    function recoverToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(REVENUE_TOKEN)) revert RevenueTokenNotRecoverable();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit TokenRecovered(address(token), to, amount);
        token.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _distribute() private returns (uint256 revenue) {
        revenue = undistributedRevenue();
        if (revenue == 0) revert NothingToDistribute();

        Allocation memory a = allocation;
        (
            uint256 burnShare,
            uint256 developerShare,
            uint256 treasuryShare,
            uint256 operationsShare,
            uint256 nftWorkersShare
        ) = _split(revenue, a);

        // Effects before interactions.
        pendingBurn += burnShare;
        totalDistributed += revenue;
        totalToDeveloper += developerShare;
        emit RevenueDistributed(
            msg.sender, revenue, burnShare, developerShare, treasuryShare, operationsShare, nftWorkersShare
        );

        Recipients memory r = recipients;
        if (developerShare > 0) REVENUE_TOKEN.safeTransfer(r.developer, developerShare);
        if (treasuryShare > 0) REVENUE_TOKEN.safeTransfer(r.treasury, treasuryShare);
        if (operationsShare > 0) REVENUE_TOKEN.safeTransfer(r.operations, operationsShare);
        if (nftWorkersShare > 0) REVENUE_TOKEN.safeTransfer(r.nftWorkers, nftWorkersShare);

        if (pendingBurn > 0) {
            if (burnSink != address(0)) _executeBurn();
            else emit BurnDeferred(pendingBurn);
        }
    }

    /// @dev Distributes revenue already waiting, if any, so a setting change never applies to it.
    function _settleWaitingRevenue() private {
        if (undistributedRevenue() > 0) _distribute();
    }

    function _executeBurn() private {
        address sink = burnSink;
        uint256 amount = pendingBurn;
        pendingBurn = 0;
        totalBurned += amount;
        emit BurnExecuted(sink, amount);
        REVENUE_TOKEN.safeTransfer(sink, amount);
    }

    function _split(uint256 revenue, Allocation memory a)
        private
        pure
        returns (
            uint256 burnShare,
            uint256 developerShare,
            uint256 treasuryShare,
            uint256 operationsShare,
            uint256 nftWorkersShare
        )
    {
        burnShare = (revenue * a.burnBps) / BPS;
        developerShare = (revenue * a.developerBps) / BPS;
        operationsShare = (revenue * a.operationsBps) / BPS;
        nftWorkersShare = (revenue * a.nftWorkersBps) / BPS;
        // The treasury takes its share plus the rounding dust, so the five shares always sum to
        // the revenue exactly and nothing is left stranded.
        treasuryShare = revenue - burnShare - developerShare - operationsShare - nftWorkersShare;
    }

    function _checkRecipient(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(this)) revert SelfRecipient();
    }
}
