// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMDPumpRevenueSplitter} from "src/IMDPumpRevenueSplitter.sol";
import {MockIMD} from "../mocks/MockIMD.sol";

contract IMDPumpRevenueHandler is Test {
    address internal constant REQUESTER = 0x83027AD9d0D5374335086c539dADD1db983441B0;
    uint256 internal constant MAX_DEPOSIT = 1e30;

    MockIMD public immutable imd;
    MockIMD public immutable stray;
    IMDPumpRevenueSplitter public immutable splitter;

    // Two disjoint addresses per bucket allow recipient rotation while retaining the
    // complete history of actual credits. Aliased buckets are covered by unit tests.
    address[10] public accounts;
    address[3] public operators;
    address[3] public owners;
    uint256[5] public choices;
    uint16[5] public rates;
    address public expectedOwner;
    address public expectedPendingOwner;
    bool public sinkConfigured;

    uint256 public received;
    uint256 public unallocated;
    uint256 public expectedPending;
    uint256 public expectedDistributed;
    uint256 public expectedBurned;
    uint256 public expectedDeveloper;
    uint256 public strayInjected;
    uint256 public strayRecovered;
    uint256 public settlements;
    bool public violation;

    constructor(MockIMD imd_, MockIMD stray_) {
        imd = imd_;
        stray = stray_;
        expectedOwner = REQUESTER;
        owners[0] = REQUESTER;
        owners[1] = makeAddr("successor one");
        owners[2] = makeAddr("successor two");
        for (uint256 i; i < 3; ++i) {
            operators[i] = makeAddr(string.concat("operator ", vm.toString(i)));
        }
        for (uint256 i; i < 10; ++i) {
            accounts[i] = makeAddr(string.concat("bucket account ", vm.toString(i)));
        }
        rates = [uint16(2_000), 1_500, 2_500, 2_000, 2_000];
        splitter = new IMDPumpRevenueSplitter(REQUESTER, REQUESTER, address(imd));
        vm.startPrank(REQUESTER);
        splitter.setDeveloper(accounts[2]);
        splitter.setTreasury(accounts[4]);
        splitter.setOperations(accounts[6]);
        splitter.setNftWorkers(accounts[8]);
        vm.stopPrank();
    }

    function destination(uint256 bucket) public view returns (address) {
        return accounts[bucket * 2 + choices[bucket]];
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        address actor = operators[actorSeed % 3];
        uint256 amount = _amount(amountSeed);
        imd.mint(actor, amount);
        vm.prank(actor);
        imd.transfer(address(splitter), amount);
        received += amount;
        unallocated += amount;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = operators[actorSeed % 3];
        uint256 amount = _amount(amountSeed);
        imd.mint(actor, amount);
        vm.prank(actor);
        imd.approve(address(splitter), amount);
        uint256 revenue = unallocated + amount;
        uint256[10] memory beforeBalances = _balances();
        if (!_succeeds(actor, abi.encodeCall(splitter.depositAndDistribute, (amount)), abi.encode(revenue))) return;
        received += amount;
        _afterDistribution(revenue, beforeBalances);
    }

    function distribute(uint256 actorSeed) public {
        address actor = operators[actorSeed % 3];
        if (unallocated == 0) {
            _rejects(
                actor,
                abi.encodeCall(splitter.distribute, ()),
                abi.encodeWithSelector(IMDPumpRevenueSplitter.NothingToDistribute.selector)
            );
            return;
        }
        uint256 revenue = unallocated;
        uint256[10] memory beforeBalances = _balances();
        if (!_succeeds(actor, abi.encodeCall(splitter.distribute, ()), abi.encode(revenue))) return;
        _afterDistribution(revenue, beforeBalances);
    }

    function burnPending(uint256 actorSeed) public {
        address actor = operators[actorSeed % 3];
        if (!sinkConfigured || expectedPending == 0) {
            _rejects(
                actor,
                abi.encodeCall(splitter.burnPending, ()),
                abi.encodeWithSelector(
                    !sinkConfigured
                        ? IMDPumpRevenueSplitter.BurnSinkNotConfigured.selector
                        : IMDPumpRevenueSplitter.NothingToBurn.selector
                )
            );
            return;
        }
        uint256[10] memory beforeBalances = _balances();
        if (!_succeeds(actor, abi.encodeCall(splitter.burnPending, ()), "")) return;
        _checkCredits(beforeBalances, 0, expectedPending);
        for (uint256 bucket = 1; bucket < 5; ++bucket) {
            _checkCredits(beforeBalances, bucket, 0);
        }
        expectedBurned += expectedPending;
        expectedPending = 0;
    }

    function configure(uint256 action, uint256 seed, uint16[4] memory inputs) public {
        action %= 7;
        if (action == 0) {
            uint16[5] memory next;
            uint256 remaining = 10_000;
            for (uint256 i; i < 4; ++i) {
                next[i] = uint16(bound(inputs[i], 0, remaining));
                remaining -= next[i];
            }
            next[4] = uint16(remaining);
            if (!_setterSucceeds(abi.encodeCall(splitter.setAllocation, (next[0], next[1], next[2], next[3], next[4]))))
            return;
            rates = next;
        } else if (action == 1) {
            uint256 bucket = 1 + seed % 4;
            uint256 choice = (seed >> 8) % 2;
            address account = accounts[bucket * 2 + choice];
            bytes memory data;
            if (bucket == 1) data = abi.encodeCall(splitter.setDeveloper, (account));
            else if (bucket == 2) data = abi.encodeCall(splitter.setTreasury, (account));
            else if (bucket == 3) data = abi.encodeCall(splitter.setOperations, (account));
            else data = abi.encodeCall(splitter.setNftWorkers, (account));
            if (_setterSucceeds(data)) choices[bucket] = choice;
        } else if (action == 2) {
            uint256 choice = seed % 2;
            if (!_setterSucceeds(abi.encodeCall(splitter.setBurnSink, (accounts[choice])))) return;
            choices[0] = choice;
            sinkConfigured = true;
        } else if (action == 3) {
            address next = owners[seed % 3];
            if (_succeeds(expectedOwner, abi.encodeCall(splitter.transferOwnership, (next)), "")) {
                expectedPendingOwner = next;
            }
        } else if (action == 4) {
            if (expectedPendingOwner == address(0)) {
                address caller = operators[seed % 3];
                _rejects(
                    caller,
                    abi.encodeCall(splitter.acceptOwnership, ()),
                    abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)
                );
            } else if (_succeeds(expectedPendingOwner, abi.encodeCall(splitter.acceptOwnership, ()), "")) {
                expectedOwner = expectedPendingOwner;
                expectedPendingOwner = address(0);
            }
        } else if (action == 5) {
            // The owner can never renounce: an ownerless splitter could not name a burn sink.
            _rejects(
                expectedOwner,
                abi.encodeCall(splitter.renounceOwnership, ()),
                abi.encodeWithSelector(IMDPumpRevenueSplitter.RenounceDisabled.selector)
            );
        } else if (_succeeds(expectedOwner, abi.encodeCall(splitter.transferOwnership, (address(0))), "")) {
            expectedPendingOwner = address(0);
        }
    }

    /// @dev A setter first distributes revenue already waiting under the settings in force before
    /// it, so the credits are checked against the old rates, recipients and sink, which the caller
    /// only updates after this returns.
    function _setterSucceeds(bytes memory data) private returns (bool ok) {
        uint256 revenue = unallocated;
        uint256[10] memory beforeBalances = _balances();
        ok = _succeeds(expectedOwner, data, "");
        if (!ok) return false;
        if (revenue > 0) {
            ++settlements;
            _afterDistribution(revenue, beforeBalances);
        } else {
            // Nothing waiting: the setter moves no revenue and flushes no pending burn.
            for (uint256 bucket; bucket < 5; ++bucket) {
                _checkCredits(beforeBalances, bucket, 0);
            }
        }
    }

    function unauthorized(uint256 actorSeed, uint256 action) external {
        address caller = operators[actorSeed % 3];
        bytes memory data;
        action %= 9;
        if (action == 0) data = abi.encodeCall(splitter.setAllocation, (10_000, 0, 0, 0, 0));
        else if (action == 1) data = abi.encodeCall(splitter.setDeveloper, (caller));
        else if (action == 2) data = abi.encodeCall(splitter.setTreasury, (caller));
        else if (action == 3) data = abi.encodeCall(splitter.setOperations, (caller));
        else if (action == 4) data = abi.encodeCall(splitter.setNftWorkers, (caller));
        else if (action == 5) data = abi.encodeCall(splitter.setBurnSink, (caller));
        else if (action == 6) data = abi.encodeCall(splitter.transferOwnership, (caller));
        else if (action == 7) data = abi.encodeCall(splitter.renounceOwnership, ());
        else data = abi.encodeCall(splitter.recoverToken, (stray, caller, 1));
        _rejects(caller, data, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function recoverStray(uint256 actorSeed, uint256 amountSeed, uint256 recoverySeed) external {
        uint256 amount = _amount(amountSeed);
        stray.mint(address(splitter), amount);
        strayInjected += amount;
        uint256 held = strayInjected - strayRecovered;
        uint256 recovery = bound(recoverySeed, 0, held + 1);
        bytes memory data = abi.encodeCall(splitter.recoverToken, (stray, operators[actorSeed % 3], recovery));
        if (recovery == 0) {
            _rejects(expectedOwner, data, abi.encodeWithSelector(IMDPumpRevenueSplitter.ZeroAmount.selector));
        } else if (recovery > held) {
            _rejects(
                expectedOwner,
                data,
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(splitter), held, recovery
                )
            );
        } else if (_succeeds(expectedOwner, data, "")) {
            strayRecovered += recovery;
        }
    }

    function rejectRevenueRecovery(uint256 amountSeed) external {
        _rejects(
            expectedOwner,
            abi.encodeCall(splitter.recoverToken, (imd, expectedOwner, _amount(amountSeed))),
            abi.encodeWithSelector(IMDPumpRevenueSplitter.RevenueTokenNotRecoverable.selector)
        );
    }

    function rejectZeroDeposit(uint256 actorSeed) external {
        _rejects(
            operators[actorSeed % 3],
            abi.encodeCall(splitter.depositAndDistribute, (0)),
            abi.encodeWithSelector(IMDPumpRevenueSplitter.ZeroAmount.selector)
        );
    }

    function _afterDistribution(uint256 revenue, uint256[10] memory beforeBalances) private {
        uint256 paid;
        uint256 developerPaid;
        for (uint256 bucket = 1; bucket < 5; ++bucket) {
            uint256 active = bucket * 2 + choices[bucket];
            uint256 balance = imd.balanceOf(accounts[active]);
            if (balance < beforeBalances[active]) {
                violation = true;
                return;
            }
            uint256 credit = balance - beforeBalances[active];
            _checkCredits(beforeBalances, bucket, credit);
            _checkRounding(revenue, bucket, credit);
            paid += credit;
            if (bucket == 1) developerPaid = credit;
        }
        if (paid > revenue) {
            violation = true;
            return;
        }
        // Conservation determines the burn liability independently of the splitter's counters.
        uint256 burnShare = revenue - paid;
        _checkRounding(revenue, 0, burnShare);
        uint256 owed = expectedPending + burnShare;
        _checkCredits(beforeBalances, 0, sinkConfigured ? owed : 0);
        if (sinkConfigured) {
            expectedBurned += owed;
            expectedPending = 0;
        } else {
            expectedPending = owed;
        }
        expectedDistributed += revenue;
        expectedDeveloper += developerPaid;
        unallocated = 0;
    }

    function _checkRounding(uint256 revenue, uint256 bucket, uint256 credit) private {
        uint256 exactNumerator = revenue * rates[bucket];
        uint256 paidNumerator = credit * 10_000;
        if (bucket == 2) {
            if (paidNumerator < exactNumerator || paidNumerator - exactNumerator >= 40_000) violation = true;
        } else {
            if (paidNumerator > exactNumerator || exactNumerator - paidNumerator >= 10_000) violation = true;
        }
    }

    function _checkCredits(uint256[10] memory beforeBalances, uint256 bucket, uint256 credit) private {
        for (uint256 choice; choice < 2; ++choice) {
            uint256 index = bucket * 2 + choice;
            uint256 expected = beforeBalances[index] + (choice == choices[bucket] ? credit : 0);
            if (imd.balanceOf(accounts[index]) != expected) violation = true;
        }
    }

    function _balances() private view returns (uint256[10] memory values) {
        for (uint256 i; i < 10; ++i) {
            values[i] = imd.balanceOf(accounts[i]);
        }
    }

    function _amount(uint256 seed) private pure returns (uint256) {
        if (seed % 8 == 0) return 1;
        if (seed % 8 == 1) return 10_000;
        if (seed % 8 == 2) return MAX_DEPOSIT;
        return bound(seed, 1, MAX_DEPOSIT);
    }

    function _succeeds(address caller, bytes memory data, bytes memory expectedResult) private returns (bool ok) {
        bytes memory result;
        vm.prank(caller);
        (ok, result) = address(splitter).call(data);
        if (!ok || keccak256(result) != keccak256(expectedResult)) violation = true;
    }

    function _rejects(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(splitter).call(data);
        if (ok || keccak256(result) != keccak256(expectedError)) violation = true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract IMDPumpRevenueInvariantTest is Test {
    MockIMD internal imd;
    MockIMD internal stray;
    IMDPumpRevenueSplitter internal splitter;
    IMDPumpRevenueHandler internal handler;

    function setUp() public {
        imd = new MockIMD();
        stray = new MockIMD();
        handler = new IMDPumpRevenueHandler(imd, stray);
        splitter = handler.splitter();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.deposit.selector;
        selectors[2] = handler.distribute.selector;
        selectors[3] = handler.burnPending.selector;
        selectors[4] = handler.configure.selector;
        selectors[5] = handler.unauthorized.selector;
        selectors[6] = handler.recoverStray.selector;
        selectors[7] = handler.rejectRevenueRecovery.selector;
        selectors[8] = handler.rejectZeroDeposit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_allRevenueIsEitherPaidOwedOrWaiting() public view {
        uint256 holdings = imd.balanceOf(address(splitter));
        assertEq(holdings, handler.expectedPending() + handler.unallocated());
        assertEq(splitter.pendingBurn(), handler.expectedPending());
        assertEq(splitter.undistributedRevenue(), handler.unallocated());
        for (uint256 i; i < 10; ++i) {
            holdings += imd.balanceOf(handler.accounts(i));
        }
        assertEq(holdings, handler.received(), "revenue was lost or counted twice");
        assertEq(splitter.totalDistributed() + splitter.undistributedRevenue(), handler.received());
    }

    function invariant_lifetimeCountersMatchIndependentCredits() public view {
        assertEq(splitter.totalDistributed(), handler.expectedDistributed());
        assertEq(splitter.totalBurned(), handler.expectedBurned());
        assertEq(splitter.totalToDeveloper(), handler.expectedDeveloper());
        assertEq(imd.balanceOf(handler.accounts(0)) + imd.balanceOf(handler.accounts(1)), splitter.totalBurned());
        assertEq(imd.balanceOf(handler.accounts(2)) + imd.balanceOf(handler.accounts(3)), splitter.totalToDeveloper());
    }

    function invariant_onlyAcceptedOwnerActionsChangeConfiguration() public view {
        assertEq(splitter.owner(), handler.expectedOwner());
        assertEq(splitter.pendingOwner(), handler.expectedPendingOwner());
        assertEq(address(splitter.REVENUE_TOKEN()), address(imd));
        assertEq(splitter.burnSink(), handler.sinkConfigured() ? handler.destination(0) : address(0));
        (address d, address t, address o, address n) = splitter.recipients();
        assertEq(d, handler.destination(1));
        assertEq(t, handler.destination(2));
        assertEq(o, handler.destination(3));
        assertEq(n, handler.destination(4));
        (uint16 b, uint16 dev, uint16 tre, uint16 ops, uint16 nft) = splitter.allocation();
        assertEq(b, handler.rates(0));
        assertEq(dev, handler.rates(1));
        assertEq(tre, handler.rates(2));
        assertEq(ops, handler.rates(3));
        assertEq(nft, handler.rates(4));
        assertEq(uint256(b) + dev + tre + ops + nft, 10_000);
        assertEq(splitter.imdDirectedBps(), uint256(b) + dev);
    }

    function invariant_recoveringOtherTokensKeepsTheirSeparateLedger() public view {
        assertEq(stray.balanceOf(address(splitter)) + handler.strayRecovered(), handler.strayInjected());
        uint256 recovered;
        for (uint256 i; i < 3; ++i) {
            recovered += stray.balanceOf(handler.operators(i));
        }
        assertEq(recovered, handler.strayRecovered());
    }

    function invariant_expectedOutcomesAndPerPayoutRoundingAlwaysHold() public view {
        assertFalse(handler.violation(), "unexpected success, revert, payout, rounding, or return value");
    }

    function afterInvariant() public {
        // Every generated state can finish paying once the owner supplies a destination.
        uint16[4] memory unused;
        handler.configure(2, 0, unused);
        handler.distribute(0);
        handler.burnPending(1);
        invariant_expectedOutcomesAndPerPayoutRoundingAlwaysHold();
        invariant_allRevenueIsEitherPaidOwedOrWaiting();
        invariant_lifetimeCountersMatchIndependentCredits();
        assertEq(imd.balanceOf(address(splitter)), 0);
        assertEq(splitter.totalDistributed(), handler.received());
    }
}
