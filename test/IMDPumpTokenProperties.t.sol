// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDPumpToken} from "src/IMDPumpToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract IMDPumpTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant PAYOUT = 0x83027AD9d0D5374335086c539dADD1db983441B0;

    IMDPumpToken internal token;
    address internal holder = makeAddr("token holder");
    address internal spender = makeAddr("token spender");
    address internal recipient = makeAddr("token recipient");

    function setUp() public {
        token = new IMDPumpToken();
        token.transfer(holder, SUPPLY);
    }

    function test_zeroTransferFromAnEmptyAccountEmitsTransfer() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(spender, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transfer(recipient, 0));
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromNeedsNoAllowanceButStillRejectsZeroAddresses() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), recipient, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(holder, address(0), 0);
    }

    function test_zeroTransferToZeroAddressIsStillInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(holder);
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_zeroBurnEmitsBothEventsWithoutChangingSupply() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(spender, address(0), 0);
        vm.expectEmit(address(token));
        emit IMDPumpToken.Burned(spender, 0);
        vm.prank(spender);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_selfTransferOfFullBalancePreservesBalanceAndSupply() public {
        vm.prank(holder);
        assertTrue(token.transfer(holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSelfTransferConsumesOnlyAllowance() public {
        vm.prank(holder);
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, SUPPLY));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceSurvivesRepeatedTransfersAndCanBeRevoked() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(holder, recipient, 1);
        token.transferFrom(holder, recipient, SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(recipient), SUPPLY);

        vm.prank(holder);
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
    }

    function test_approvalOverwritesInsteadOfAddingAndRejectsZeroSpender() public {
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(address(token));
        emit IERC20.Approval(holder, spender, 1);
        assertTrue(token.approve(spender, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.stopPrank();
        assertEq(token.allowance(holder, spender), 1);
    }

    function test_failedTransferFromRollsBackAllowanceAndBalances() public {
        vm.prank(holder);
        token.approve(spender, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(holder, recipient, SUPPLY + 1);
        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(holder, address(0), 1);
        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumAmountsCannotTransferOrBurnBeyondSupply() public {
        bytes memory insufficient =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, type(uint256).max);
        vm.startPrank(holder);
        vm.expectRevert(insufficient);
        token.transfer(recipient, type(uint256).max);
        vm.expectRevert(insufficient);
        token.burn(type(uint256).max);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnEntireSupplyLeavesNoPositiveTransferOrBurnPossible() public {
        vm.prank(holder);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(0)), 0);

        vm.startPrank(holder);
        bytes memory insufficient = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1);
        vm.expectRevert(insufficient);
        token.burn(1);
        vm.expectRevert(insufficient);
        token.transfer(recipient, 1);
        assertTrue(token.transfer(recipient, 0));
        vm.stopPrank();
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_evenAnApprovedSpenderCannotBurnOnBehalfOfHolder() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", holder, SUPPLY));
        assertFalse(ok);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(holder, spender), type(uint256).max);
    }

    function test_supplyCanPassThroughLaunchRecipientsWithoutTaxes() public {
        address distributor = makeAddr("launch distributor");
        address pool = makeAddr("launch pool recipient");
        uint256 swarm = SUPPLY / 10;
        uint256 poolShare = SUPPLY / 2;
        vm.startPrank(holder);
        token.transfer(distributor, swarm);
        token.transfer(pool, poolShare);
        token.transfer(PAYOUT, SUPPLY - swarm - poolShare);
        vm.stopPrank();
        vm.prank(distributor);
        token.transfer(recipient, swarm);
        vm.prank(pool);
        token.transfer(spender, 1e18);
        vm.prank(spender);
        token.transfer(pool, 1e18);

        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), swarm);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(PAYOUT), SUPPLY - swarm - poolShare);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_roundTripTransfersLoseNoTokens(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, amount));
        vm.prank(recipient);
        assertTrue(token.transfer(holder, amount));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_finiteAllowanceTracksOnlySuccessfulSpending(uint256 approval, uint256 amount) public {
        approval = bound(approval, 0, SUPPLY);
        amount = bound(amount, 0, approval);
        vm.prank(holder);
        token.approve(spender, approval);
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        uint256 remaining = approval - amount;
        assertEq(token.allowance(holder, spender), remaining);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(holder), SUPPLY - amount);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, remaining + 1)
        );
        vm.prank(spender);
        token.transferFrom(holder, recipient, remaining + 1);
        assertEq(token.allowance(holder, spender), remaining);
        assertEq(token.balanceOf(recipient), amount);
    }

    function testFuzz_burnOnlyRemovesCallersBalance(uint256 transferred, uint256 burned) public {
        transferred = bound(transferred, 0, SUPPLY);
        burned = bound(burned, 0, transferred);
        vm.prank(holder);
        token.transfer(recipient, transferred);
        vm.prank(recipient);
        token.burn(burned);
        assertEq(token.balanceOf(holder), SUPPLY - transferred);
        assertEq(token.balanceOf(recipient), transferred - burned);
        assertEq(token.totalSupply() + burned, SUPPLY);
        assertEq(token.balanceOf(holder) + token.balanceOf(recipient), token.totalSupply());
    }
}
