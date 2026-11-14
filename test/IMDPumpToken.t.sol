// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDPumpToken} from "../src/IMDPumpToken.sol";

/// @notice Deploys the token the way the factory does: from a contract whose `msg.sender` becomes
/// the holder of the whole supply.
contract FactoryStandIn {
    function deployToken() external returns (IMDPumpToken) {
        return new IMDPumpToken();
    }
}

contract IMDPumpTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    FactoryStandIn factory;
    IMDPumpToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new FactoryStandIn();
        token = factory.deployToken();
    }

    // -------------------------------------------------------------------------------- metadata

    function test_metadata() public view {
        assertEq(token.name(), "IMD PUMP");
        assertEq(token.symbol(), "IMDPUMP");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedOnceToDeployer() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    // -------------------------------------------------------------------------------- transfers

    function test_transferMovesExactlyWhatIsSent() public {
        vm.prank(address(factory));
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 1_000e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 400e18));
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.totalSupply(), SUPPLY, "transfers must not change the supply");
    }

    function testFuzz_transfersAreUntaxed(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(address(factory));
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(to), SUPPLY);
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferFromWithAllowance() public {
        vm.prank(address(factory));
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 60e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 60e18));
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(address(factory));
        token.transfer(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    // -------------------------------------------------------------------------------- burning

    function test_holderCanBurnOwnTokens() public {
        vm.prank(address(factory));
        token.transfer(alice, 100e18);

        vm.expectEmit(address(token));
        emit IMDPumpToken.Burned(alice, 40e18);
        vm.prank(alice);
        token.burn(40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), SUPPLY - 40e18);
    }

    function test_burnMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_nobodyCanBurnAnotherHoldersTokens() public {
        vm.prank(address(factory));
        token.transfer(alice, 100e18);
        // There is no burnFrom at all: the call misses and the balance stays.
        vm.prank(address(factory));
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 100e18);
    }

    // -------------------------------------------------------------------------------- no admin surface

    function test_supplyCannotGrow() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "transferOwnership(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    function test_noOwnerOrPause() public {
        (bool hasOwner,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);
        (bool paused,) = address(token).call(abi.encodeWithSignature("pause()"));
        assertFalse(paused);
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, 24_576);
    }
}
