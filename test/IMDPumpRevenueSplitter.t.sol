// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMDPumpToken} from "../src/IMDPumpToken.sol";
import {IMDPumpRevenueSplitter} from "../src/IMDPumpRevenueSplitter.sol";
import {MockIMD, NoReturnToken, ReentrantToken, IReenterTarget} from "./mocks/MockIMD.sol";

contract IMDPumpRevenueSplitterTest is Test {
    uint16 constant BPS = 10_000;

    MockIMD imd;
    IMDPumpRevenueSplitter splitter;

    address owner = makeAddr("owner");
    address payout = makeAddr("payout");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    address developer = makeAddr("developer");
    address treasury = makeAddr("treasury");
    address operations = makeAddr("operations");
    address nftWorkers = makeAddr("nftWorkers");
    address sink = makeAddr("burnSink");

    function setUp() public {
        imd = new MockIMD();
        splitter = new IMDPumpRevenueSplitter(owner, payout, address(imd));
    }

    function _fund(uint256 amount) internal {
        imd.mint(address(splitter), amount);
    }

    function _pointRecipientsApart() internal {
        vm.startPrank(owner);
        splitter.setDeveloper(developer);
        splitter.setTreasury(treasury);
        splitter.setOperations(operations);
        splitter.setNftWorkers(nftWorkers);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------ construction

    function test_constructorState() public view {
        assertEq(splitter.owner(), owner);
        assertEq(address(splitter.REVENUE_TOKEN()), address(imd));
        (address dev, address tre, address ops, address nft) = splitter.recipients();
        assertEq(dev, payout);
        assertEq(tre, payout);
        assertEq(ops, payout);
        assertEq(nft, payout);
        (uint16 b, uint16 d, uint16 t, uint16 o, uint16 n) = splitter.allocation();
        assertEq(b, 2_000);
        assertEq(d, 1_500);
        assertEq(t, 2_500);
        assertEq(o, 2_000);
        assertEq(n, 2_000);
        assertEq(uint256(b) + d + t + o + n, BPS);
        assertEq(splitter.imdDirectedBps(), 3_500, "35% combined for burns and developer accumulation");
        assertEq(splitter.burnSink(), address(0), "burn sink is unset until the owner configures it");
        assertEq(splitter.pendingBurn(), 0);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IMDPumpRevenueSplitter(address(0), payout, address(imd));
    }

    function test_constructorRejectsZeroPayout() public {
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        new IMDPumpRevenueSplitter(owner, address(0), address(imd));
    }

    function test_constructorRejectsZeroRevenueToken() public {
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        new IMDPumpRevenueSplitter(owner, payout, address(0));
    }

    function test_constructorMakesNoExternalCall() public {
        // Deploying against an address with no code must succeed: the launch runs constructors on
        // an empty chain.
        address noCode = makeAddr("noCode");
        IMDPumpRevenueSplitter s = new IMDPumpRevenueSplitter(owner, payout, noCode);
        assertEq(address(s.REVENUE_TOKEN()), noCode);
    }

    function test_constructorDoesNotTouchTheLaunchToken() public {
        IMDPumpToken token = new IMDPumpToken();
        uint256 supply = token.totalSupply();
        new IMDPumpRevenueSplitter(owner, payout, address(imd));
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), supply);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(splitter).code.length, 24_576);
    }

    // ------------------------------------------------------------------------------ distribution

    function test_distributeAppliesTheLaunchModel() public {
        _pointRecipientsApart();
        _fund(100e18);

        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.RevenueDistributed(operator, 100e18, 20e18, 15e18, 25e18, 20e18, 20e18);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.BurnDeferred(20e18);
        vm.prank(operator);
        uint256 revenue = splitter.distribute();

        assertEq(revenue, 100e18);
        assertEq(imd.balanceOf(developer), 15e18, "15 of every 100 goes to the developer");
        assertEq(imd.balanceOf(treasury), 25e18);
        assertEq(imd.balanceOf(operations), 20e18);
        assertEq(imd.balanceOf(nftWorkers), 20e18);
        assertEq(
            imd.balanceOf(treasury) + imd.balanceOf(operations) + imd.balanceOf(nftWorkers),
            65e18,
            "65 support the platform"
        );
        assertEq(splitter.pendingBurn(), 20e18, "20 of every 100 is held for the burn until the sink is set");
        assertEq(imd.balanceOf(address(splitter)), 20e18);
        assertEq(splitter.totalDistributed(), 100e18);
        assertEq(splitter.totalToDeveloper(), 15e18);
        assertEq(splitter.totalBurned(), 0);
        assertEq(splitter.undistributedRevenue(), 0);
    }

    function test_distributeWithSinglePayoutAddress() public {
        _fund(100e18);
        splitter.distribute();
        assertEq(imd.balanceOf(payout), 80e18, "everything but the burn share reaches the named payout address");
        assertEq(splitter.pendingBurn(), 20e18);
    }

    function test_distributeWithNothingWaitingReverts() public {
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToDistribute.selector);
        splitter.distribute();
    }

    function test_distributeTwiceWithoutNewRevenueReverts() public {
        _fund(100e18);
        splitter.distribute();
        // Only the pending burn is left; it is not new revenue.
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToDistribute.selector);
        splitter.distribute();
    }

    function test_pendingBurnIsNotRedistributed() public {
        _fund(100e18);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 20e18);

        _fund(50e18);
        assertEq(splitter.undistributedRevenue(), 50e18);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 30e18, "20 + 10, never re-split");
        assertEq(imd.balanceOf(payout), 120e18);
        assertEq(splitter.totalDistributed(), 150e18);
    }

    function test_previewMatchesDistribution() public {
        _fund(1_234_567e15);
        (uint256 b, uint256 d, uint256 t, uint256 o, uint256 n) = splitter.previewDistribution();
        assertEq(b + d + t + o + n, 1_234_567e15);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.RevenueDistributed(address(this), 1_234_567e15, b, d, t, o, n);
        splitter.distribute();
    }

    function test_roundingDustGoesToTreasury() public {
        _pointRecipientsApart();
        _fund(7);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 1); // 7 * 0.20 = 1.4
        assertEq(imd.balanceOf(developer), 1); // 7 * 0.15 = 1.05
        assertEq(imd.balanceOf(operations), 1); // 7 * 0.20 = 1.4
        assertEq(imd.balanceOf(nftWorkers), 1);
        assertEq(imd.balanceOf(treasury), 3); // 7 - 4, the 1.75 share plus dust
    }

    function testFuzz_distributionConservesRevenue(uint256 revenue) public {
        revenue = bound(revenue, 1, 1e30);
        _pointRecipientsApart();
        _fund(revenue);
        splitter.distribute();
        uint256 paid =
            imd.balanceOf(developer) + imd.balanceOf(treasury) + imd.balanceOf(operations) + imd.balanceOf(nftWorkers);
        assertEq(paid + splitter.pendingBurn(), revenue, "every unit of revenue is accounted for");
        assertEq(imd.balanceOf(address(splitter)), splitter.pendingBurn(), "only the burn share stays behind");
        assertApproxEqAbs(imd.balanceOf(developer), (revenue * 15) / 100, 1);
        assertApproxEqAbs(splitter.pendingBurn(), (revenue * 20) / 100, 1);
    }

    function testFuzz_distributionConservesRevenueUnderAnyAllocation(
        uint256 revenue,
        uint16 burnBps,
        uint16 developerBps,
        uint16 treasuryBps,
        uint16 operationsBps
    ) public {
        revenue = bound(revenue, 1, 1e30);
        burnBps = uint16(bound(burnBps, 0, BPS));
        developerBps = uint16(bound(developerBps, 0, BPS - burnBps));
        treasuryBps = uint16(bound(treasuryBps, 0, BPS - burnBps - developerBps));
        operationsBps = uint16(bound(operationsBps, 0, BPS - burnBps - developerBps - treasuryBps));
        uint16 nftWorkersBps = BPS - burnBps - developerBps - treasuryBps - operationsBps;

        _pointRecipientsApart();
        vm.prank(owner);
        splitter.setAllocation(burnBps, developerBps, treasuryBps, operationsBps, nftWorkersBps);
        _fund(revenue);
        splitter.distribute();

        uint256 paid =
            imd.balanceOf(developer) + imd.balanceOf(treasury) + imd.balanceOf(operations) + imd.balanceOf(nftWorkers);
        assertEq(paid + splitter.pendingBurn(), revenue);
        assertEq(splitter.pendingBurn(), (revenue * burnBps) / BPS);
        assertEq(imd.balanceOf(developer), (revenue * developerBps) / BPS);
        assertEq(imd.balanceOf(operations), (revenue * operationsBps) / BPS);
        assertEq(imd.balanceOf(nftWorkers), (revenue * nftWorkersBps) / BPS);
        assertGe(imd.balanceOf(treasury), (revenue * treasuryBps) / BPS);
    }

    function test_depositAndDistributePullsFromCaller() public {
        imd.mint(operator, 100e18);
        vm.startPrank(operator);
        imd.approve(address(splitter), 100e18);
        uint256 revenue = splitter.depositAndDistribute(100e18);
        vm.stopPrank();

        assertEq(revenue, 100e18);
        assertEq(imd.balanceOf(operator), 0);
        assertEq(imd.balanceOf(payout), 80e18);
        assertEq(splitter.pendingBurn(), 20e18);
    }

    function test_depositAndDistributeIncludesRevenueAlreadyWaiting() public {
        _fund(40e18);
        imd.mint(operator, 60e18);
        vm.startPrank(operator);
        imd.approve(address(splitter), 60e18);
        uint256 revenue = splitter.depositAndDistribute(60e18);
        vm.stopPrank();
        assertEq(revenue, 100e18);
    }

    function test_depositAndDistributeRejectsZero() public {
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAmount.selector);
        splitter.depositAndDistribute(0);
    }

    function test_depositAndDistributeWithoutApprovalReverts() public {
        imd.mint(operator, 100e18);
        vm.prank(operator);
        vm.expectRevert();
        splitter.depositAndDistribute(100e18);
        assertEq(imd.balanceOf(operator), 100e18);
    }

    // ------------------------------------------------------------------------------ burning

    function test_burnPendingRevertsUntilSinkConfigured() public {
        _fund(100e18);
        splitter.distribute();
        vm.expectRevert(IMDPumpRevenueSplitter.BurnSinkNotConfigured.selector);
        splitter.burnPending();
        assertEq(splitter.pendingBurn(), 20e18, "the burn share is kept, not lost");
    }

    function test_burnPendingRevertsWithNothingPending() public {
        vm.prank(owner);
        splitter.setBurnSink(sink);
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToBurn.selector);
        splitter.burnPending();
    }

    function test_burnPendingSendsAccumulatedShareOnceConfigured() public {
        _fund(100e18);
        splitter.distribute();
        _fund(100e18);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 40e18);

        vm.prank(owner);
        splitter.setBurnSink(sink);

        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.BurnExecuted(sink, 40e18);
        vm.prank(stranger);
        splitter.burnPending();

        assertEq(imd.balanceOf(sink), 40e18);
        assertEq(splitter.pendingBurn(), 0);
        assertEq(splitter.totalBurned(), 40e18);
        assertEq(imd.balanceOf(address(splitter)), 0);
    }

    function test_distributeBurnsImmediatelyWhenSinkConfigured() public {
        vm.prank(owner);
        splitter.setBurnSink(sink);
        _fund(100e18);

        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.BurnExecuted(sink, 20e18);
        splitter.distribute();

        assertEq(imd.balanceOf(sink), 20e18);
        assertEq(imd.balanceOf(payout), 80e18);
        assertEq(splitter.pendingBurn(), 0);
        assertEq(imd.balanceOf(address(splitter)), 0);
    }

    function test_distributeFlushesEarlierDeferredBurn() public {
        _fund(100e18);
        splitter.distribute();
        vm.prank(owner);
        splitter.setBurnSink(sink);
        _fund(100e18);
        splitter.distribute();
        assertEq(imd.balanceOf(sink), 40e18, "the deferred 20 and the new 20 burn together");
        assertEq(splitter.totalBurned(), 40e18);
    }

    // ------------------------------------------------------------------------------ owner settings

    function test_setAllocation() public {
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.AllocationUpdated(2_500, 1_500, 2_500, 2_000, 1_500);
        vm.prank(owner);
        splitter.setAllocation(2_500, 1_500, 2_500, 2_000, 1_500);
        assertEq(splitter.imdDirectedBps(), 4_000);

        _fund(100e18);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 25e18);
        assertEq(imd.balanceOf(payout), 75e18);
    }

    function test_setAllocationRejectsWrongSum() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 9_999));
        splitter.setAllocation(2_000, 1_500, 2_500, 2_000, 1_999);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 10_001));
        splitter.setAllocation(2_000, 1_500, 2_500, 2_000, 2_001);
    }

    function test_setAllocationOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.setAllocation(2_000, 1_500, 2_500, 2_000, 2_000);
    }

    function test_recipientSetters() public {
        vm.startPrank(owner);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.DeveloperUpdated(payout, developer);
        splitter.setDeveloper(developer);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.TreasuryUpdated(payout, treasury);
        splitter.setTreasury(treasury);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.OperationsUpdated(payout, operations);
        splitter.setOperations(operations);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.NftWorkersUpdated(payout, nftWorkers);
        splitter.setNftWorkers(nftWorkers);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.BurnSinkUpdated(address(0), sink);
        splitter.setBurnSink(sink);
        vm.stopPrank();

        (address dev, address tre, address ops, address nft) = splitter.recipients();
        assertEq(dev, developer);
        assertEq(tre, treasury);
        assertEq(ops, operations);
        assertEq(nft, nftWorkers);
        assertEq(splitter.burnSink(), sink);
    }

    function test_settersRejectZeroAndSelf() public {
        vm.startPrank(owner);
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.setDeveloper(address(0));
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.setTreasury(address(0));
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.setOperations(address(0));
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.setNftWorkers(address(0));
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.setBurnSink(address(0));
        vm.expectRevert(IMDPumpRevenueSplitter.SelfRecipient.selector);
        splitter.setDeveloper(address(splitter));
        vm.expectRevert(IMDPumpRevenueSplitter.SelfRecipient.selector);
        splitter.setBurnSink(address(splitter));
        vm.stopPrank();
    }

    function test_settersOnlyOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        splitter.setDeveloper(developer);
        vm.expectRevert(unauthorized);
        splitter.setTreasury(treasury);
        vm.expectRevert(unauthorized);
        splitter.setOperations(operations);
        vm.expectRevert(unauthorized);
        splitter.setNftWorkers(nftWorkers);
        vm.expectRevert(unauthorized);
        splitter.setBurnSink(sink);
        vm.stopPrank();
    }

    function test_ownershipTransfersInTwoSteps() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        splitter.transferOwnership(newOwner);
        assertEq(splitter.owner(), owner, "ownership does not move until accepted");
        assertEq(splitter.pendingOwner(), newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.acceptOwnership();

        vm.prank(newOwner);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), newOwner);
    }

    function test_renounceOwnershipIsDisabledWhileBurnSinkUnset() public {
        _fund(100e18);
        splitter.distribute();
        assertEq(splitter.pendingBurn(), 20e18);
        assertEq(splitter.burnSink(), address(0));

        vm.prank(owner);
        vm.expectRevert(IMDPumpRevenueSplitter.RenounceDisabled.selector);
        splitter.renounceOwnership();

        assertEq(splitter.owner(), owner, "the owner keeps the power to set the burn sink");
        vm.prank(owner);
        splitter.setBurnSink(sink);
        splitter.burnPending();
        assertEq(imd.balanceOf(sink), 20e18, "the burn share is never stranded");
    }

    function test_renounceOwnershipIsDisabledEvenWithBurnSinkSet() public {
        vm.prank(owner);
        splitter.setBurnSink(sink);
        vm.prank(owner);
        vm.expectRevert(IMDPumpRevenueSplitter.RenounceDisabled.selector);
        splitter.renounceOwnership();
        assertEq(splitter.owner(), owner);
    }

    function test_renounceOwnershipRefusesStrangers() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.renounceOwnership();
    }

    // ------------------------------------------------------------------- setters settle revenue first

    function test_setAllocationSettlesWaitingRevenueUnderTheOldSplit() public {
        _pointRecipientsApart();
        _fund(1_000e18);
        assertEq(splitter.undistributedRevenue(), 1_000e18);

        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.RevenueDistributed(owner, 1_000e18, 200e18, 150e18, 250e18, 200e18, 200e18);
        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.AllocationUpdated(2_000, 500, 3_500, 2_000, 2_000);
        vm.prank(owner);
        splitter.setAllocation(2_000, 500, 3_500, 2_000, 2_000);

        assertEq(splitter.undistributedRevenue(), 0, "nothing delivered under the old split is left to re-split");
        assertEq(imd.balanceOf(developer), 150e18, "the developer gets 15% of what was earned at 15%");
        assertEq(imd.balanceOf(treasury), 250e18);

        // A front-running distribute() has nothing left to take, and later revenue follows the cut.
        vm.prank(developer);
        vm.expectRevert(IMDPumpRevenueSplitter.NothingToDistribute.selector);
        splitter.distribute();
        _fund(1_000e18);
        splitter.distribute();
        assertEq(imd.balanceOf(developer), 200e18, "150 + 50 under the new 5% share");
        assertEq(imd.balanceOf(treasury), 600e18, "250 + 350 under the new 35% share");
    }

    function test_setDeveloperSettlesWaitingRevenueToThePreviousDeveloper() public {
        _pointRecipientsApart();
        _fund(1_000e18);
        address newDeveloper = makeAddr("newDeveloper");

        vm.prank(owner);
        splitter.setDeveloper(newDeveloper);

        assertEq(splitter.undistributedRevenue(), 0);
        assertEq(imd.balanceOf(developer), 150e18, "revenue earned while D was the recipient goes to D");
        assertEq(imd.balanceOf(newDeveloper), 0);
        _fund(1_000e18);
        splitter.distribute();
        assertEq(imd.balanceOf(newDeveloper), 150e18, "later revenue goes to the new recipient");
        assertEq(imd.balanceOf(developer), 150e18);
    }

    function test_everyRecipientSetterSettlesWaitingRevenueFirst() public {
        _pointRecipientsApart();
        address replacement = makeAddr("replacement");

        _fund(100e18);
        vm.prank(owner);
        splitter.setTreasury(replacement);
        assertEq(imd.balanceOf(treasury), 25e18);

        _fund(100e18);
        vm.prank(owner);
        splitter.setOperations(replacement);
        assertEq(imd.balanceOf(operations), 40e18);

        _fund(100e18);
        vm.prank(owner);
        splitter.setNftWorkers(replacement);
        assertEq(imd.balanceOf(nftWorkers), 60e18);

        // The replacement is treasury from the second delivery on (25 of the second 100) and
        // treasury plus operations from the third (25 + 20): never anything earned before it was named.
        assertEq(imd.balanceOf(replacement), 25e18 + 45e18, "the replacement only receives what it was named for");
        assertEq(splitter.undistributedRevenue(), 0);
        assertEq(splitter.totalDistributed(), 300e18);
    }

    function test_setBurnSinkSettlesWaitingRevenueUnderThePreviousSink() public {
        address oldSink = makeAddr("oldSink");
        vm.prank(owner);
        splitter.setBurnSink(oldSink);
        _fund(100e18);

        vm.prank(owner);
        splitter.setBurnSink(sink);

        assertEq(imd.balanceOf(oldSink), 20e18, "the burn share of revenue already waiting follows the old sink");
        assertEq(imd.balanceOf(sink), 0);
        assertEq(splitter.undistributedRevenue(), 0);
    }

    function test_setBurnSinkWithNoPreviousSinkKeepsTheWaitingBurnSharePending() public {
        _fund(100e18);
        vm.prank(owner);
        splitter.setBurnSink(sink);
        // The waiting revenue was settled with the sink unset, so its burn share joins pendingBurn
        // and leaves on the next burnPending(), to the sink the owner has now named.
        assertEq(imd.balanceOf(payout), 80e18);
        assertEq(splitter.pendingBurn(), 20e18);
        splitter.burnPending();
        assertEq(imd.balanceOf(sink), 20e18);
    }

    function test_settersWithNothingWaitingDistributeNothing() public {
        _fund(100e18);
        splitter.distribute();
        assertEq(splitter.totalDistributed(), 100e18);

        vm.recordLogs();
        vm.startPrank(owner);
        splitter.setAllocation(2_500, 1_500, 2_500, 2_000, 1_500);
        splitter.setDeveloper(developer);
        splitter.setTreasury(treasury);
        splitter.setOperations(operations);
        splitter.setNftWorkers(nftWorkers);
        splitter.setBurnSink(sink);
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 6, "one event per setter, no distribution");
        assertEq(splitter.totalDistributed(), 100e18);
        assertEq(splitter.pendingBurn(), 20e18, "pendingBurn is not touched by setters");
    }

    function test_setterSettlementIsReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        IMDPumpRevenueSplitter target = new IMDPumpRevenueSplitter(owner, payout, address(evil));
        evil.setTarget(IReenterTarget(address(target)));
        evil.mint(address(target), 100e18);

        vm.prank(owner);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        target.setDeveloper(developer);
        assertEq(evil.balanceOf(address(target)), 100e18, "nothing moved");
        (address dev,,,) = target.recipients();
        assertEq(dev, payout, "the setting did not change");
    }

    function test_invalidAllocationIsRefusedBeforeSettling() public {
        _fund(100e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMDPumpRevenueSplitter.InvalidAllocation.selector, 9_999));
        splitter.setAllocation(2_000, 1_500, 2_500, 2_000, 1_999);
        assertEq(splitter.undistributedRevenue(), 100e18, "a rejected setter changes nothing");
    }

    // ------------------------------------------------------------------------------ recovery

    function test_recoverStrayToken() public {
        IMDPumpToken stray = new IMDPumpToken();
        stray.transfer(address(splitter), 5e18);

        vm.expectEmit(address(splitter));
        emit IMDPumpRevenueSplitter.TokenRecovered(address(stray), treasury, 5e18);
        vm.prank(owner);
        splitter.recoverToken(IERC20(address(stray)), treasury, 5e18);
        assertEq(stray.balanceOf(treasury), 5e18);
    }

    function test_recoverStrayTokenWithoutBoolReturn() public {
        NoReturnToken usdtLike = new NoReturnToken();
        usdtLike.mint(address(splitter), 7);
        vm.prank(owner);
        splitter.recoverToken(IERC20(address(usdtLike)), treasury, 7);
        assertEq(usdtLike.balanceOf(treasury), 7);
    }

    function test_recoverRefusesRevenueToken() public {
        _fund(100e18);
        vm.prank(owner);
        vm.expectRevert(IMDPumpRevenueSplitter.RevenueTokenNotRecoverable.selector);
        splitter.recoverToken(IERC20(address(imd)), owner, 100e18);
        assertEq(imd.balanceOf(address(splitter)), 100e18);
    }

    function test_recoverValidation() public {
        IMDPumpToken stray = new IMDPumpToken();
        vm.startPrank(owner);
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAddress.selector);
        splitter.recoverToken(IERC20(address(stray)), address(0), 1);
        vm.expectRevert(IMDPumpRevenueSplitter.ZeroAmount.selector);
        splitter.recoverToken(IERC20(address(stray)), treasury, 0);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.recoverToken(IERC20(address(stray)), stranger, 1);
    }

    // ------------------------------------------------------------------------------ hardening

    function test_rejectsEther() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(splitter).call{value: 1}("");
        assertFalse(ok, "the splitter only handles IMD");
    }

    function test_reentrantRevenueTokenIsRefused() public {
        ReentrantToken evil = new ReentrantToken();
        IMDPumpRevenueSplitter target = new IMDPumpRevenueSplitter(owner, payout, address(evil));
        evil.setTarget(IReenterTarget(address(target)));
        evil.mint(address(target), 100e18);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        target.distribute();
        assertEq(evil.balanceOf(address(target)), 100e18, "nothing moved");
    }

    function test_nonStandardRevenueTokenStillDistributes() public {
        NoReturnToken odd = new NoReturnToken();
        IMDPumpRevenueSplitter target = new IMDPumpRevenueSplitter(owner, payout, address(odd));
        odd.mint(address(target), 100);
        target.distribute();
        assertEq(odd.balanceOf(payout), 80);
        assertEq(target.pendingBurn(), 20);
    }
}
