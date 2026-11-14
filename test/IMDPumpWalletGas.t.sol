// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDPumpRevenueSplitter} from "src/IMDPumpRevenueSplitter.sol";
import {WalletGas} from "./helpers/WalletGas.sol";
import {MockIMD, NoReturnToken} from "./mocks/MockIMD.sol";

/// @dev SafeERC20 uses low-level calls for these entry points. The supplied helper searches
/// the minimum successful gas limit and compares return data and events with a generous limit.
contract IMDPumpWalletGasTest is WalletGas {
    address internal constant OWNER = 0x83027AD9d0D5374335086c539dADD1db983441B0;
    MockIMD internal imd;
    IMDPumpRevenueSplitter internal splitter;
    address internal operator = makeAddr("wallet operator");
    address internal developer = makeAddr("wallet developer");
    address internal treasury = makeAddr("wallet treasury");
    address internal operations = makeAddr("wallet operations");
    address internal workers = makeAddr("wallet workers");
    address internal sink = makeAddr("wallet mock burn destination");

    function setUp() public {
        imd = new MockIMD();
        splitter = new IMDPumpRevenueSplitter(OWNER, OWNER, address(imd));
        vm.startPrank(OWNER);
        splitter.setDeveloper(developer);
        splitter.setTreasury(treasury);
        splitter.setOperations(operations);
        splitter.setNftWorkers(workers);
        vm.stopPrank();
    }

    function test_walletGas_distributeWithDeferredBurn() public {
        imd.mint(address(splitter), 100e18);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.distribute, ()));
        assertEq(splitter.totalDistributed(), 0, "helper must restore state");
        vm.prank(operator);
        assertEq(splitter.distribute(), 100e18);
        assertEq(imd.balanceOf(developer), 15e18);
        assertEq(splitter.pendingBurn(), 20e18);
    }

    function test_walletGas_distributeWithAllPayoutsAndImmediateBurn() public {
        vm.prank(OWNER);
        splitter.setBurnSink(sink);
        imd.mint(address(splitter), 100e18);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.distribute, ()));
        splitter.distribute();
        assertEq(imd.balanceOf(sink), 20e18);
        assertEq(imd.balanceOf(developer), 15e18);
        assertEq(imd.balanceOf(treasury), 25e18);
        assertEq(imd.balanceOf(operations), 20e18);
        assertEq(imd.balanceOf(workers), 20e18);
        assertEq(imd.balanceOf(address(splitter)), 0);
    }

    function test_walletGas_distributeFlushesOldAndNewBurnsToAnExistingRecipient() public {
        imd.mint(address(splitter), 100e18);
        splitter.distribute();
        vm.prank(OWNER);
        splitter.setBurnSink(sink);
        imd.mint(sink, 1);
        imd.mint(address(splitter), 50e18);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.distribute, ()));
        assertEq(splitter.pendingBurn(), 20e18);
        splitter.distribute();
        assertEq(imd.balanceOf(sink), 30e18 + 1);
        assertEq(splitter.pendingBurn(), 0);
        assertEq(splitter.totalDistributed(), 150e18);
    }

    function test_walletGas_depositWithFiniteAllowanceAndRevenueAlreadyWaiting() public {
        imd.mint(address(splitter), 100e18);
        splitter.distribute();
        vm.prank(OWNER);
        splitter.setBurnSink(sink);
        imd.mint(address(splitter), 40e18);
        imd.mint(operator, 60e18);
        vm.prank(operator);
        imd.approve(address(splitter), 60e18);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.depositAndDistribute, (60e18)));
        assertEq(imd.balanceOf(operator), 60e18);
        assertEq(imd.allowance(operator, address(splitter)), 60e18);
        vm.prank(operator);
        assertEq(splitter.depositAndDistribute(60e18), 100e18);
        assertEq(imd.balanceOf(operator), 0);
        assertEq(imd.allowance(operator, address(splitter)), 0);
        assertEq(splitter.totalDistributed(), 200e18);
        assertEq(imd.balanceOf(sink), 40e18);
    }

    function test_walletGas_depositWithInfiniteAllowanceAndDeferredBurn() public {
        imd.mint(operator, 100e18);
        vm.prank(operator);
        imd.approve(address(splitter), type(uint256).max);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.depositAndDistribute, (100e18)));
        vm.prank(operator);
        splitter.depositAndDistribute(100e18);
        assertEq(imd.allowance(operator, address(splitter)), type(uint256).max);
        assertEq(splitter.pendingBurn(), 20e18);
        assertEq(imd.balanceOf(developer), 15e18);
    }

    function test_walletGas_burnPendingKeepsUnallocatedRevenue() public {
        imd.mint(address(splitter), 100e18);
        splitter.distribute();
        vm.prank(OWNER);
        splitter.setBurnSink(sink);
        imd.mint(address(splitter), 7);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.burnPending, ()));
        assertEq(splitter.pendingBurn(), 20e18);
        vm.prank(operator);
        splitter.burnPending();
        assertEq(imd.balanceOf(sink), 20e18);
        assertEq(splitter.totalBurned(), 20e18);
        assertEq(splitter.undistributedRevenue(), 7);
    }

    function test_walletGas_recoverEntireStrayBalance() public {
        MockIMD stray = new MockIMD();
        stray.mint(address(splitter), 100e18);
        imd.mint(address(splitter), 100e18);
        splitter.distribute();
        assertSameAtWalletGas(OWNER, address(splitter), abi.encodeCall(splitter.recoverToken, (stray, OWNER, 100e18)));
        vm.prank(OWNER);
        splitter.recoverToken(stray, OWNER, 100e18);
        assertEq(stray.balanceOf(OWNER), 100e18);
        assertEq(stray.balanceOf(address(splitter)), 0);
        assertEq(imd.balanceOf(address(splitter)), 20e18);
        assertEq(splitter.pendingBurn(), 20e18);
    }

    function test_walletGas_recoverTokenWithoutReturnData() public {
        NoReturnToken stray = new NoReturnToken();
        stray.mint(address(splitter), 100);
        bytes memory data = abi.encodeCall(splitter.recoverToken, (IERC20(address(stray)), OWNER, 100));
        assertSameAtWalletGas(OWNER, address(splitter), data);
        vm.prank(OWNER);
        splitter.recoverToken(IERC20(address(stray)), OWNER, 100);
        assertEq(stray.balanceOf(OWNER), 100);
    }

    function test_walletGas_noReturnRevenueAndSharedPayoutAddress() public {
        NoReturnToken odd = new NoReturnToken();
        IMDPumpRevenueSplitter s = new IMDPumpRevenueSplitter(OWNER, OWNER, address(odd));
        odd.mint(address(s), 100);
        assertSameAtWalletGas(operator, address(s), abi.encodeCall(s.distribute, ()));
        odd.mint(operator, 100);
        vm.prank(operator);
        odd.approve(address(s), 100);
        assertSameAtWalletGas(operator, address(s), abi.encodeCall(s.depositAndDistribute, (100)));
        vm.prank(operator);
        assertEq(s.depositAndDistribute(100), 200);
        assertEq(odd.balanceOf(OWNER), 160);
        vm.prank(OWNER);
        s.setBurnSink(sink);
        assertSameAtWalletGas(operator, address(s), abi.encodeCall(s.burnPending, ()));
        s.burnPending();
        assertEq(odd.balanceOf(sink), 40);
    }

    function test_walletGas_dustAndAllBurnAllocation() public {
        imd.mint(address(splitter), 1);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.distribute, ()));
        splitter.distribute();
        assertEq(imd.balanceOf(treasury), 1);
        vm.startPrank(OWNER);
        splitter.setBurnSink(sink);
        splitter.setAllocation(10_000, 0, 0, 0, 0);
        vm.stopPrank();
        imd.mint(address(splitter), 1);
        assertSameAtWalletGas(operator, address(splitter), abi.encodeCall(splitter.distribute, ()));
        splitter.distribute();
        assertEq(imd.balanceOf(sink), 1);
        assertEq(splitter.totalBurned(), 1);
    }
}
