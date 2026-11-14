// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IMDPumpToken} from "../src/IMDPumpToken.sol";
import {IMDPumpRevenueSplitter} from "../src/IMDPumpRevenueSplitter.sol";

/// @title Reference deployment for IMD PUMP
/// @notice The launch itself is performed by the IMD factory from the built bytecode, with the
/// manifest's constructor arguments. This script documents the parameters and lets a developer
/// deploy the same pair of contracts to a local or test chain. It never runs in the launch.
/// @dev `deploy` takes its configuration as an argument so tests call it directly; `run` reads the
/// environment and hands a config over. Note that on a plain deployment the token's supply is
/// minted to whatever account broadcasts, because the token mints to `msg.sender`.
contract Deploy is Script {
    /// @notice IMD on Ethereum mainnet (chain id 1), the launch's pair currency and the splitter's
    /// revenue token.
    address public constant IMD_MAINNET = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    /// @notice The address the requester named to receive fees and payouts.
    address public constant REQUESTER_PAYOUT = 0x83027AD9d0D5374335086c539dADD1db983441B0;

    struct Config {
        /// The launch owner: the requester's address. Never the factory or a deployer wallet.
        address owner;
        /// Initial recipient of every paid-out share.
        address payout;
        /// The IMD token the revenue is delivered in.
        address revenueToken;
    }

    function deploy(Config memory config) public returns (IMDPumpToken token, IMDPumpRevenueSplitter splitter) {
        token = new IMDPumpToken();
        splitter = new IMDPumpRevenueSplitter(config.owner, config.payout, config.revenueToken);
    }

    /// @notice Reads `OWNER` from the environment (defaulting to the requester's payout address)
    /// and deploys against mainnet IMD. For local or test chains, set `REVENUE_TOKEN` as well.
    function run() external returns (IMDPumpToken token, IMDPumpRevenueSplitter splitter) {
        Config memory config = Config({
            owner: vm.envOr("OWNER", REQUESTER_PAYOUT),
            payout: vm.envOr("PAYOUT", REQUESTER_PAYOUT),
            revenueToken: vm.envOr("REVENUE_TOKEN", IMD_MAINNET)
        });
        vm.startBroadcast();
        (token, splitter) = deploy(config);
        vm.stopBroadcast();
    }
}
