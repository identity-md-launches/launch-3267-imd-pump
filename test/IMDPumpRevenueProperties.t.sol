// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMDPumpRevenueSplitter} from "src/IMDPumpRevenueSplitter.sol";
import {MockIMD, NoReturnToken} from "./mocks/MockIMD.sol";
import {FaultyRevenueToken, CallbackRevenueToken} from "./mocks/AdversarialRevenueToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract IMDPumpRevenuePropertiesTest is Test {
    address internal constant OWNER = 0x83027AD9d0D5374335086c539dADD1db983441B0;
    MockIMD internal imd;
    IMDPumpRevenueSplitter internal splitter;
    address internal operator = makeAddr("revenue operator");
    address internal stranger = makeAddr("revenue stranger");
    address[5] internal destinations;

    function setUp() public {
        for (uint256 i; i < 5; ++i) {
            destinations[i] = makeAddr(string.concat("revenue destination ", vm.toString(i)));
        }
        imd = new MockIMD();
        splitter = _newSplitter(address(imd));
    }

    function _newSplitter(address currency) internal returns (IMDPumpRevenueSplitter s) {
        s = new IMDPumpRevenueSplitter(OWNER, OWNER, currency);
        vm.startPrank(OWNER);
        s.setDeveloper(destinations[1]);
        s.setTreasury(destinations[2]);
        s.setOperations(destinations[3]);
        s.setNftWorkers(destinations[4]);
        vm.stopPrank();
    }

    function _setSink(IMDPumpRevenueSplitter s) internal {
        vm.prank(OWNER);
        s.setBurnSink(destinations[0]);
    }

    function _configuration(IMDPumpRevenueSplitter s) internal view returns (bytes32) {
        (uint16 b, uint16 d, uint16 t, uint16 o, uint16 n) = s.allocation();
        bytes32 allocationHash = keccak256(abi.encode(b, d, t, o, n));
        (address dev, address treasury, address ops, address nft) = s.recipients();
        bytes32 recipientHash = keccak256(abi.encode(dev, treasury, ops, nft));
        return keccak256(abi.encode(allocationHash, recipientHash, s.burnSink()));
    }

    function _accounting(IMDPumpRevenueSplitter s, IERC20 currency) internal view returns (bytes32) {
        uint256[5] memory paid;
        for (uint256 i; i < 5; ++i) {
            paid[i] = currency.balanceOf(destinations[i]);
        }
        return keccak256(
            abi.encode(
                s.pendingBurn(),
                s.totalDistributed(),
                s.totalBurned(),
                s.totalToDeveloper(),
                s.undistributedRevenue(),
                currency.balanceOf(address(s)),
                currency.balanceOf(operator),
                currency.allowance(operator, address(s)),
                paid
            )
        );
    }

    function test_oneWeiIsPaidToTreasuryAndCannotBeDistributedTwice() public {
        imd.mint(address(splitter), 1);
        (uint256 b, uint256 d, uint256 t, uint256 o, uint256 n) = splitter.previewDistribution();
        assertEq(b + d + o + n, 0);
        assertEq(t, 1);
        vm.prank(stranger);
        assertEq(splitter.distribute(), 1);
        assertEq(imd.balanceOf(destinations[2]), 1);
        assertEq(imd.balanceOf(stranger), 0);
        assertEq(splitter.pendingBurn(), 0);
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToDistribute.selector);
        splitter.distribute();
    }

    function test_allRevenueCanBeAssignedToEachIndividualBucket() public {
        // Pin every 0%/100% corner, including all-burn with no paid-out shares.
        for (uint256 bucket; bucket < 5; ++bucket) {
            IMDPumpRevenueSplitter s = _newSplitter(address(imd));
            _setSink(s);
            uint16[5] memory rates;
            rates[bucket] = 10_000;
            vm.prank(OWNER);
            s.setAllocation(rates[0], rates[1], rates[2], rates[3], rates[4]);
            uint256[5] memory beforeBalances;
            for (uint256 i; i < 5; ++i) {
                beforeBalances[i] = imd.balanceOf(destinations[i]);
            }
            imd.mint(address(s), 10_001);
            assertEq(s.distribute(), 10_001);
            for (uint256 i; i < 5; ++i) {
                assertEq(imd.balanceOf(destinations[i]) - beforeBalances[i], i == bucket ? 10_001 : 0);
            }
            assertEq(s.totalDistributed(), 10_001);
            assertEq(s.totalBurned(), bucket == 0 ? 10_001 : 0);
            assertEq(s.totalToDeveloper(), bucket == 1 ? 10_001 : 0);
            assertEq(s.imdDirectedBps(), bucket < 2 ? 10_000 : 0);
            assertEq(imd.balanceOf(address(s)), 0);
        }
    }

    function test_deferredBurnSurvivesAllocationChangeAndNewRevenue() public {
        imd.mint(address(splitter), 100);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 20);
        vm.prank(OWNER);
        splitter.setAllocation(0, 10_000, 0, 0, 0);
        imd.mint(address(splitter), 50);
        (uint256 burnShare, uint256 developerShare,,,) = splitter.previewDistribution();
        assertEq(burnShare, 0);
        assertEq(developerShare, 50);
        _setSink(splitter);
        vm.prank(stranger);
        assertEq(splitter.distribute(), 50);
        assertEq(imd.balanceOf(destinations[0]), 20);
        assertEq(imd.balanceOf(destinations[1]), 65);
        assertEq(splitter.totalDistributed(), 150);
        assertEq(splitter.totalBurned(), 20);
        assertEq(splitter.totalToDeveloper(), 65);
        assertEq(splitter.pendingBurn(), 0);
    }

    function test_burnPendingDoesNotConsumeNewUnallocatedRevenue() public {
        imd.mint(address(splitter), 100);
        splitter.distribute();
        imd.mint(address(splitter), 37);
        _setSink(splitter);
        vm.prank(stranger);
        splitter.burnPending();
        assertEq(splitter.totalDistributed(), 100);
        assertEq(splitter.totalToDeveloper(), 15);
        assertEq(splitter.totalBurned(), 20);
        assertEq(splitter.undistributedRevenue(), 37);
        assertEq(imd.balanceOf(address(splitter)), 37);
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToBurn.selector);
        splitter.burnPending();
        assertEq(splitter.distribute(), 37);
        assertEq(splitter.totalDistributed(), 137);
    }

    function test_newRecipientsOnlyReceiveLaterDistributions() public {
        imd.mint(address(splitter), 100);
        splitter.distribute();
        address replacement = makeAddr("replacement for all payouts");
        vm.startPrank(OWNER);
        splitter.setDeveloper(replacement);
        splitter.setTreasury(replacement);
        splitter.setOperations(replacement);
        splitter.setNftWorkers(replacement);
        vm.stopPrank();
        imd.mint(address(splitter), 100);
        splitter.distribute();
        assertEq(imd.balanceOf(destinations[1]), 15);
        assertEq(imd.balanceOf(destinations[2]), 25);
        assertEq(imd.balanceOf(destinations[3]), 20);
        assertEq(imd.balanceOf(destinations[4]), 20);
        assertEq(imd.balanceOf(replacement), 80);
        assertEq(splitter.pendingBurn(), 40);
        assertEq(splitter.totalToDeveloper(), 30);
    }

    function test_changingBurnDestinationAffectsOnlyUnsentBurns() public {
        _setSink(splitter);
        imd.mint(address(splitter), 100);
        splitter.distribute();
        address nextSink = makeAddr("second mock burn destination");
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.BurnSinkUpdated(destinations[0], nextSink);
        vm.prank(OWNER);
        splitter.setBurnSink(nextSink);
        imd.mint(address(splitter), 100);
        splitter.distribute();
        assertEq(imd.balanceOf(destinations[0]), 20);
        assertEq(imd.balanceOf(nextSink), 20);
        assertEq(splitter.totalBurned(), 40);
    }

    function test_insufficientDepositorBalanceRestoresAllowanceAndAllAccounting() public {
        imd.mint(operator, 9);
        imd.mint(address(splitter), 100);
        splitter.distribute();
        vm.prank(operator);
        imd.approve(address(splitter), 10);
        bytes32 beforeState = _accounting(splitter, imd);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, operator, 9, 10));
        vm.prank(operator);
        splitter.depositAndDistribute(10);
        assertEq(_accounting(splitter, imd), beforeState);
    }

    function test_zeroDepositDoesNotDistributeAlreadyWaitingRevenue() public {
        imd.mint(address(splitter), 100);
        bytes32 beforeState = _accounting(splitter, imd);
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAmount.selector);
        vm.prank(stranger);
        splitter.depositAndDistribute(0);
        assertEq(_accounting(splitter, imd), beforeState);
    }

    function test_insufficientApprovalCannotUseAnotherDepositorsApproval() public {
        imd.mint(operator, 100);
        vm.prank(operator);
        imd.approve(address(splitter), 100);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(splitter), 0, 100)
        );
        vm.prank(stranger);
        splitter.depositAndDistribute(100);
        assertEq(imd.balanceOf(operator), 100);
        assertEq(imd.allowance(operator, address(splitter)), 100);
        assertEq(splitter.totalDistributed(), 0);
    }

    function test_allRecipientSettersRejectTheSplitterItselfWithoutChangingConfig() public {
        bytes32 beforeState = _configuration(splitter);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPumpRevenueSplitter.SelfRecipient.selector);
        splitter.setTreasury(address(splitter));
        vm.expectRevert(IMDPumpRevenueSplitter.SelfRecipient.selector);
        splitter.setOperations(address(splitter));
        vm.expectRevert(IMDPumpRevenueSplitter.SelfRecipient.selector);
        splitter.setNftWorkers(address(splitter));
        vm.stopPrank();
        assertEq(_configuration(splitter), beforeState);
    }

    function test_allocationValidationUsesWideSumAndPreservesConfig() public {
        bytes32 beforeState = _configuration(splitter);
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 0));
        splitter.setAllocation(0, 0, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 327_675));
        splitter.setAllocation(type(uint16).max, type(uint16).max, type(uint16).max, type(uint16).max, type(uint16).max);
        // A uint16 sum would wrap this invalid configuration to precisely 10,000.
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 75_536));
        splitter.setAllocation(65_535, 10_001, 0, 0, 0);
        vm.stopPrank();
        assertEq(_configuration(splitter), beforeState);
    }

    function test_pendingOwnerHasNoPowerAndReplacementRevokesTheFirstNominee() public {
        vm.prank(OWNER);
        splitter.transferOwnership(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        splitter.setDeveloper(operator);
        vm.prank(OWNER);
        splitter.transferOwnership(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        splitter.acceptOwnership();
        vm.prank(stranger);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), stranger);
        assertEq(splitter.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vm.prank(OWNER);
        splitter.setBurnSink(destinations[0]);
        vm.prank(stranger);
        splitter.setBurnSink(destinations[0]);
        assertEq(splitter.burnSink(), destinations[0]);
    }

    function test_cancelledOwnershipCannotBeAccepted() public {
        vm.startPrank(OWNER);
        splitter.transferOwnership(operator);
        splitter.transferOwnership(address(0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), OWNER);
        assertEq(splitter.pendingOwner(), address(0));
    }

    function test_renouncingConfiguredOwnershipClearsNomineeAndLeavesPublicDistributionLive() public {
        _setSink(splitter);
        vm.startPrank(OWNER);
        splitter.transferOwnership(operator);
        splitter.renounceOwnership();
        vm.stopPrank();
        assertEq(splitter.owner(), address(0));
        assertEq(splitter.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        splitter.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vm.prank(OWNER);
        splitter.setAllocation(10_000, 0, 0, 0, 0);
        imd.mint(address(splitter), 100);
        vm.prank(stranger);
        assertEq(splitter.distribute(), 100);
        assertEq(imd.balanceOf(destinations[0]), 20);
    }

    function test_noReturnCurrencySupportsPullDeferredBurnAndLaterFlush() public {
        NoReturnToken odd = new NoReturnToken();
        IMDPumpRevenueSplitter s = _newSplitter(address(odd));
        odd.mint(operator, 100);
        vm.startPrank(operator);
        odd.approve(address(s), 100);
        assertEq(s.depositAndDistribute(100), 100);
        vm.stopPrank();
        assertEq(odd.allowance(operator, address(s)), 0);
        assertEq(odd.balanceOf(operator), 0);
        assertEq(odd.balanceOf(destinations[1]), 15);
        assertEq(s.pendingBurn(), 20);
        _setSink(s);
        s.burnPending();
        assertEq(odd.balanceOf(destinations[0]), 20);
        assertEq(odd.balanceOf(address(s)), 0);
    }

    function test_recoveryOfCodeLessTokenFailsInsteadOfClaimingSuccess() public {
        address missing = makeAddr("no token deployed");
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, missing));
        vm.prank(OWNER);
        splitter.recoverToken(IERC20(missing), OWNER, 1);
    }

    function test_recoveryAboveStrayBalanceCannotMoveRevenue() public {
        MockIMD stray = new MockIMD();
        stray.mint(address(splitter), 2);
        imd.mint(address(splitter), 100);
        splitter.distribute();
        bytes32 beforeState = _accounting(splitter, imd);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(splitter), 2, 3));
        vm.prank(OWNER);
        splitter.recoverToken(stray, operator, 3);
        assertEq(stray.balanceOf(address(splitter)), 2);
        assertEq(stray.balanceOf(operator), 0);
        assertEq(_accounting(splitter, imd), beforeState);
        vm.prank(OWNER);
        splitter.recoverToken(stray, operator, 2);
        assertEq(stray.balanceOf(operator), 2);
        assertEq(_accounting(splitter, imd), beforeState);
    }

    function testFuzz_previewAndPayoutsRespectRoundingBounds(uint128 amountSeed, uint16[4] memory cuts) public {
        uint256 amount = bound(amountSeed, 1, type(uint128).max);
        // Sorted cut points generate all five shares, without duplicating _split's arithmetic.
        for (uint256 i; i < 4; ++i) {
            cuts[i] = uint16(bound(cuts[i], 0, 10_000));
        }
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (cuts[j] < cuts[i]) (cuts[i], cuts[j]) = (cuts[j], cuts[i]);
            }
        }
        uint16[5] memory rates = [cuts[0], cuts[1] - cuts[0], cuts[2] - cuts[1], cuts[3] - cuts[2], 10_000 - cuts[3]];
        vm.prank(OWNER);
        splitter.setAllocation(rates[0], rates[1], rates[2], rates[3], rates[4]);
        _setSink(splitter);
        imd.mint(address(splitter), amount);
        uint256[5] memory shares;
        (shares[0], shares[1], shares[2], shares[3], shares[4]) = splitter.previewDistribution();
        assertEq(shares[0] + shares[1] + shares[2] + shares[3] + shares[4], amount);
        assertEq(splitter.distribute(), amount);
        for (uint256 i; i < 5; ++i) {
            uint256 paid = imd.balanceOf(destinations[i]);
            assertEq(paid, shares[i], "preview must equal the actual credit");
            if (i == 2) {
                assertGe(paid * 10_000, amount * rates[i], "treasury receives all fractional remainders");
                assertLt(paid * 10_000 - amount * rates[i], 40_000, "at most four rounding remainders");
            } else {
                assertLe(paid * 10_000, amount * rates[i], "a rounded share cannot overpay");
                assertLt(amount * rates[i] - paid * 10_000, 10_000, "a rounded share loses less than one unit");
            }
        }
        assertEq(imd.balanceOf(address(splitter)), 0);
    }

    function testFuzz_invalidAllocationNeverChangesConfiguration(uint16[5] memory rates) public {
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            sum += rates[i];
        }
        if (sum == 10_000) {
            // Every fuzz input reaches a rejection; no discarded examples.
            ++rates[0];
            ++sum;
        }
        bytes32 beforeState = _configuration(splitter);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, sum));
        vm.prank(OWNER);
        splitter.setAllocation(rates[0], rates[1], rates[2], rates[3], rates[4]);
        assertEq(_configuration(splitter), beforeState);
    }

    function test_eachFailedPayoutRollsBackTheWholeDistributionAndCanBeRetried() public {
        for (uint256 recipientIndex; recipientIndex < 5; ++recipientIndex) {
            for (uint256 failure = 1; failure <= 2; ++failure) {
                FaultyRevenueToken bad = new FaultyRevenueToken();
                IMDPumpRevenueSplitter s = _newSplitter(address(bad));
                bad.mint(address(s), 100);
                s.distribute(); // Carry an existing 20-unit liability into the failing call.
                _setSink(s);
                bad.mint(address(s), 40);
                bad.mint(operator, 60);
                vm.prank(operator);
                bad.approve(address(s), 60);
                bad.failOutgoing(destinations[recipientIndex], FaultyRevenueToken.Failure(failure));
                bytes32 beforeState = _accounting(s, bad);
                bytes memory errorData = failure == 1
                    ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
                    : abi.encodeWithSelector(FaultyRevenueToken.TransferRefused.selector, destinations[recipientIndex]);
                vm.expectRevert(errorData);
                vm.prank(operator);
                s.depositAndDistribute(60);
                assertEq(_accounting(s, bad), beforeState, "partial payouts and allowance consumption must roll back");
                // Check the standalone route as well as the pull route.
                vm.expectRevert(errorData);
                s.distribute();
                assertEq(_accounting(s, bad), beforeState);
                bad.failOutgoing(destinations[recipientIndex], FaultyRevenueToken.Failure.None);
                vm.prank(operator);
                assertEq(s.depositAndDistribute(60), 100);
                assertEq(s.totalDistributed(), 200);
                assertEq(s.totalBurned(), 40);
                assertEq(s.totalToDeveloper(), 30);
                assertEq(s.pendingBurn(), 0);
                assertEq(bad.balanceOf(address(s)), 0);
                assertEq(bad.allowance(operator, address(s)), 0);
            }
        }
    }

    function test_failedIncomingTransferRestoresDepositorAndAllowance() public {
        for (uint256 failure = 1; failure <= 2; ++failure) {
            FaultyRevenueToken bad = new FaultyRevenueToken();
            IMDPumpRevenueSplitter s = _newSplitter(address(bad));
            bad.mint(operator, 100);
            vm.prank(operator);
            bad.approve(address(s), 100);
            bad.failIncoming(FaultyRevenueToken.Failure(failure));
            bytes32 beforeState = _accounting(s, bad);
            vm.expectRevert(
                failure == 1
                    ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
                    : abi.encodeWithSelector(FaultyRevenueToken.TransferRefused.selector, address(s))
            );
            vm.prank(operator);
            s.depositAndDistribute(100);
            assertEq(_accounting(s, bad), beforeState);
            bad.failIncoming(FaultyRevenueToken.Failure.None);
            vm.prank(operator);
            assertEq(s.depositAndDistribute(100), 100);
        }
    }

    function test_failedBurnDoesNotEraseTheLiabilityOrClaimABurn() public {
        FaultyRevenueToken bad = new FaultyRevenueToken();
        IMDPumpRevenueSplitter s = _newSplitter(address(bad));
        bad.mint(address(s), 100);
        s.distribute();
        _setSink(s);
        bad.mint(address(s), 7);
        bad.failOutgoing(destinations[0], FaultyRevenueToken.Failure.ReturnFalse);
        bytes32 beforeState = _accounting(s, bad);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        s.burnPending();
        assertEq(_accounting(s, bad), beforeState);
        bad.failOutgoing(destinations[0], FaultyRevenueToken.Failure.None);
        s.burnPending();
        assertEq(s.totalBurned(), 20);
        assertEq(s.pendingBurn(), 0);
        assertEq(s.undistributedRevenue(), 7);
    }

    function test_falseReturningRecoveryRollsBackStrayTransfer() public {
        FaultyRevenueToken bad = new FaultyRevenueToken();
        bad.mint(address(splitter), 100);
        bad.failOutgoing(operator, FaultyRevenueToken.Failure.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        vm.prank(OWNER);
        splitter.recoverToken(bad, operator, 100);
        assertEq(bad.balanceOf(address(splitter)), 100);
        assertEq(bad.balanceOf(operator), 0);
    }

    function test_everyGuardedEntryRejectsCrossFunctionReentryFromEachTransferPhase() public {
        for (uint256 phase; phase < 3; ++phase) {
            for (uint256 reentry; reentry < 3; ++reentry) {
                CallbackRevenueToken callbackToken = new CallbackRevenueToken();
                IMDPumpRevenueSplitter s = _newSplitter(address(callbackToken));
                callbackToken.mint(address(s), 100);
                if (phase == 2) s.distribute();
                _setSink(s);
                bytes memory data = reentry == 0
                    ? abi.encodeCall(s.distribute, ())
                    : reentry == 1 ? abi.encodeCall(s.depositAndDistribute, (1)) : abi.encodeCall(s.burnPending, ());
                if (phase == 0) {
                    callbackToken.mint(operator, 100);
                    vm.prank(operator);
                    callbackToken.approve(address(s), 100);
                }
                callbackToken.configure(address(s), data, phase == 0, false);
                if (phase == 0) {
                    vm.prank(operator);
                    s.depositAndDistribute(100);
                } else if (phase == 1) {
                    s.distribute();
                } else {
                    s.burnPending();
                }
                assertGt(callbackToken.callbackCount(), 0, "the callback must actually have run");
                assertFalse(callbackToken.callbackSucceeded());
                assertEq(
                    callbackToken.callbackResult(),
                    abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
                );
                assertEq(s.totalDistributed(), phase == 0 ? 200 : 100);
                assertEq(s.totalBurned(), phase == 0 ? 40 : 20);
                assertEq(s.totalToDeveloper(), phase == 0 ? 30 : 15);
                assertEq(callbackToken.balanceOf(address(s)), 0);
            }
        }
    }

    function test_bubbledReentryDuringDepositRollsBackPullAndAllowsLaterRetry() public {
        CallbackRevenueToken callbackToken = new CallbackRevenueToken();
        IMDPumpRevenueSplitter s = _newSplitter(address(callbackToken));
        callbackToken.mint(operator, 100);
        vm.prank(operator);
        callbackToken.approve(address(s), 100);
        callbackToken.configure(address(s), abi.encodeCall(s.burnPending, ()), true, true);
        bytes32 beforeState = _accounting(s, callbackToken);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(operator);
        s.depositAndDistribute(100);
        assertEq(_accounting(s, callbackToken), beforeState);
        callbackToken.configure(address(s), abi.encodeCall(s.burnPending, ()), true, false);
        vm.prank(operator);
        assertEq(s.depositAndDistribute(100), 100);
        assertEq(s.pendingBurn(), 20);
    }
}
