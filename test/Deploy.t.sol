// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IMDPumpToken} from "../src/IMDPumpToken.sol";
import {IMDPumpRevenueSplitter} from "../src/IMDPumpRevenueSplitter.sol";

contract DeployTest is Test {
    function test_deployWithConfig() public {
        Deploy deployer = new Deploy();
        address owner = makeAddr("owner");
        address payout = makeAddr("payout");
        address imd = makeAddr("imd");
        (IMDPumpToken token, IMDPumpRevenueSplitter splitter) =
            deployer.deploy(Deploy.Config({owner: owner, payout: payout, revenueToken: imd}));

        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(deployer)), token.totalSupply(), "the deployer holds the supply");
        assertEq(splitter.owner(), owner);
        assertEq(address(splitter.REVENUE_TOKEN()), imd);
        (address dev,,,) = splitter.recipients();
        assertEq(dev, payout);
    }

    function test_constantsMatchTheBrief() public {
        Deploy deployer = new Deploy();
        assertEq(deployer.IMD_MAINNET(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(deployer.REQUESTER_PAYOUT(), 0x83027AD9d0D5374335086c539dADD1db983441B0);
    }
}
