// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMD PUMP (IMDPUMP)
/// @notice A plain, fixed-supply ERC-20 with no transfer taxes, no owner and no way to mint
/// after deployment. The whole supply of 1,000,000,000 tokens (18 decimals) is minted once to the
/// deployer in the constructor; the launch factory is that deployer and pays the supply out.
/// @dev The requester asked for the token itself to stay free of additional transfer taxes so
/// trading stays simple. Everything that directs platform earnings toward IMD burns and developer
/// rewards lives in {IMDPumpRevenueSplitter}, not in this token. Holders may burn their own tokens;
/// nobody can burn, freeze or move anyone else's.
contract IMDPumpToken is ERC20 {
    /// @notice The whole supply, minted once: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Emitted when a holder burns their own tokens.
    event Burned(address indexed holder, uint256 amount);

    constructor() ERC20("IMD PUMP", "IMDPUMP") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Burns `amount` of the caller's own tokens, permanently reducing the supply.
    /// @dev Only the caller's balance can be burned. There is deliberately no `burnFrom`.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }
}
