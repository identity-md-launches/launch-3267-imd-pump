// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDPumpToken} from "src/IMDPumpToken.sol";

/// @dev The ledger follows requested operations, never copies balances back from the token.
contract IMDPumpTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    IMDPumpToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;
    bool public violation;

    constructor(IMDPumpToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("token invariant actor ", vm.toString(i)));
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        if (!_succeeds(from, abi.encodeCall(token.transfer, (to, amount)), true)) return;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        if (!_succeeds(owner, abi.encodeCall(token.approve, (spender, amount)), true)) return;
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = _amount(amountSeed, limit);
        if (!_succeeds(spender, abi.encodeCall(token.transferFrom, (owner, to, amount)), true)) return;
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function approveAndSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        approve(ownerSeed, spenderSeed, infinite ? type(uint256).max : amount);
        // A full-limit spend deliberately includes exhausting a finite approval.
        transferFrom(ownerSeed, spenderSeed, spenderSeed, 1);
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = _amount(amountSeed, expectedBalance[actor]);
        if (!_succeeds(actor, abi.encodeCall(token.burn, (amount)), false)) return;
        expectedBalance[actor] -= amount;
        burned += amount;
    }

    function overspend(uint256 actorSeed, uint256 toSeed, bool burnInstead) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = expectedBalance[actor];
        bytes memory data = burnInstead
            ? abi.encodeCall(token.burn, (balance + 1))
            : abi.encodeCall(token.transfer, (actors[toSeed % actors.length], balance + 1));
        _rejects(
            actor,
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actor, balance, balance + 1)
        );
    }

    function transferToZero(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        _rejects(
            actor,
            abi.encodeCall(token.transfer, (address(0), _amount(amountSeed, expectedBalance[actor]))),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function revokeAndTrySpending(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        approve(ownerSeed, spenderSeed, 0);
        _rejects(
            spender,
            abi.encodeCall(token.transferFrom, (owner, spender, 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
    }

    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        if (seed % 8 == 0) return 0;
        if (seed % 8 == 1) return limit;
        return bound(seed, 0, limit);
    }

    function _succeeds(address from, bytes memory data, bool returnsBool) private returns (bool ok) {
        bytes memory result;
        vm.prank(from);
        (ok, result) = address(token).call(data);
        if (!ok || (returnsBool && keccak256(result) != keccak256(abi.encode(true)))) violation = true;
    }

    function _rejects(address from, bytes memory data, bytes memory expectedError) private {
        vm.prank(from);
        (bool ok, bytes memory result) = address(token).call(data);
        if (ok || keccak256(result) != keccak256(expectedError)) violation = true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract IMDPumpTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    IMDPumpToken internal token;
    IMDPumpTokenHandler internal handler;

    function setUp() public {
        token = new IMDPumpToken();
        handler = new IMDPumpTokenHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.approveAndSpend.selector;
        selectors[4] = handler.burn.selector;
        selectors[5] = handler.overspend.selector;
        selectors[6] = handler.transferToZero.selector;
        selectors[7] = handler.revokeAndTrySpending.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyEqualsAllBalancesAndOnlyHolderBurnsReduceIt() public view {
        uint256 balances;
        for (uint256 i; i < 4; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(balances, token.totalSupply());
        assertEq(token.totalSupply() + handler.burned(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_balancesAndAllowancesMatchTheIndependentLedger() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "incorrect holder balance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
        }
    }

    function invariant_validCallsSucceedAndInvalidCallsFailForTheExpectedReason() public view {
        // Persistent flag: an unexpected revert cannot disappear into fail_on_revert=false.
        assertFalse(handler.violation(), "token operation violated its postcondition");
    }
}
