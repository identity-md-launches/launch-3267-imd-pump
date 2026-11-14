// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fail after moving tokens, to test rollback of both token and splitter state.
contract FaultyRevenueToken is ERC20 {
    enum Failure {
        None,
        ReturnFalse,
        Revert
    }

    address public failedRecipient;
    Failure public outgoingFailure;
    Failure public incomingFailure;

    error TransferRefused(address recipient);

    constructor() ERC20("Failure test currency", "FAIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function failOutgoing(address recipient, Failure failure) external {
        failedRecipient = recipient;
        outgoingFailure = failure;
    }

    function failIncoming(Failure failure) external {
        incomingFailure = failure;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        if (to != failedRecipient) return true;
        return _finish(outgoingFailure, to);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, value);
        return _finish(incomingFailure, to);
    }

    function _finish(Failure failure, address to) private pure returns (bool) {
        if (failure == Failure.Revert) revert TransferRefused(to);
        return failure != Failure.ReturnFalse;
    }
}

/// @dev A callback can be attached to either the initial pull or an outgoing payout.
contract CallbackRevenueToken is ERC20 {
    address public target;
    bytes public callback;
    bool public onIncoming;
    bool public bubbleFailure;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackCount;
    bool private entered;

    constructor() ERC20("Callback test currency", "CALL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address target_, bytes calldata callback_, bool onIncoming_, bool bubbleFailure_) external {
        target = target_;
        callback = callback_;
        onIncoming = onIncoming_;
        bubbleFailure = bubbleFailure_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (entered || target == address(0)) return;
        if (onIncoming ? to != target : from != target) return;
        entered = true;
        ++callbackCount;
        (bool ok, bytes memory result) = target.call(callback);
        callbackSucceeded = ok;
        callbackResult = result;
        entered = false;
        if (bubbleFailure && !ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
