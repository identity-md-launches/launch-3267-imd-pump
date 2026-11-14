// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stands in for IMD in tests: a plain 18-decimal ERC-20 with open minting. Like the real
/// IMD it has no burn function.
contract MockIMD is ERC20 {
    constructor() ERC20("Identity.md", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands in for an ERC-20 that does not return a bool from `transfer`, like USDT, to show
/// the splitter's SafeERC20 handling.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IReenterTarget {
    function distribute() external returns (uint256);
}

/// @notice A revenue token whose transfers call back into the splitter, to prove the reentrancy
/// guard holds.
contract ReentrantToken is ERC20 {
    IReenterTarget public target;
    bool public attacking;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(IReenterTarget target_) external {
        target = target_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(target) && !attacking) {
            attacking = true;
            target.distribute();
            attacking = false;
        }
    }
}
