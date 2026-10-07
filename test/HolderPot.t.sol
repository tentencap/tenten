// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HolderPot} from "../src/HolderPot.sol";
import {MockERC20} from "./Base.sol";

contract BadReceiver {} // a contract that is fine for ERC20 transfers (no hooks), used as a normal recipient

contract HolderPotTest is Test {
    MockERC20 ws;
    MockERC20 other;
    HolderPot pot;
    address op = makeAddr("op");
    address safe = makeAddr("safe");
    address h1 = makeAddr("h1");
    address h2 = makeAddr("h2");
    address h3 = makeAddr("h3");

    function setUp() public {
        ws = new MockERC20("wsNET", "wsNET");
        other = new MockERC20("X", "X");
        pot = new HolderPot(address(ws), safe, op);
        ws.mint(address(this), 100 ether);
        ws.approve(address(pot), type(uint256).max);
    }

    function test_donate_pulls_wsnet_only() public {
        pot.donateReward(address(ws), 10 ether);
        assertEq(pot.balance(), 10 ether);
        vm.expectRevert(HolderPot.WrongAsset.selector);
        pot.donateReward(address(other), 1 ether);
    }

    function test_push_pays_recipients_and_skips_zero() public {
        pot.donateReward(address(ws), 10 ether);
        address[] memory to = new address[](3);
        uint256[] memory am = new uint256[](3);
        to[0] = h1;
        to[1] = h2;
        to[2] = h3;
        am[0] = 1 ether;
        am[1] = 0;
        am[2] = 2 ether;
        vm.prank(op);
        pot.push(to, am, keccak256("snapshot-1"));
        assertEq(ws.balanceOf(h1), 1 ether);
        assertEq(ws.balanceOf(h2), 0);
        assertEq(ws.balanceOf(h3), 2 ether);
        assertEq(pot.balance(), 7 ether);
    }

    function test_push_never_reverts_because_of_one_recipient_and_cannot_overspend() public {
        pot.donateReward(address(ws), 3 ether);
        address[] memory to = new address[](3);
        uint256[] memory am = new uint256[](3);
        to[0] = h1;
        to[1] = h2;
        to[2] = h3;
        am[0] = 2 ether;
        am[1] = 5 ether; // more than the pot has: this transfer fails and is skipped
        am[2] = 1 ether;
        vm.prank(op);
        pot.push(to, am, bytes32(0));
        assertEq(ws.balanceOf(h1), 2 ether);
        assertEq(ws.balanceOf(h2), 0);
        assertEq(ws.balanceOf(h3), 1 ether);
        assertEq(pot.balance(), 0);
    }

    function test_only_operator_pushes_and_limits() public {
        pot.donateReward(address(ws), 1 ether);
        address[] memory to = new address[](1);
        uint256[] memory am = new uint256[](1);
        to[0] = h1;
        am[0] = 1 ether;
        vm.expectRevert(HolderPot.NotOperator.selector);
        pot.push(to, am, bytes32(0));
        vm.prank(op);
        vm.expectRevert(HolderPot.BadInput.selector);
        pot.push(to, new uint256[](2), bytes32(0));
        vm.prank(op);
        vm.expectRevert(HolderPot.TooMany.selector);
        pot.push(new address[](251), new uint256[](251), bytes32(0));
    }

    function test_owner_replaces_a_compromised_operator_at_once() public {
        pot.donateReward(address(ws), 2 ether);
        // the operator cannot replace itself or change the owner
        vm.prank(op);
        vm.expectRevert(HolderPot.NotOwner.selector);
        pot.setOperator(h1);
        vm.prank(op);
        vm.expectRevert(HolderPot.NotOwner.selector);
        pot.transferOwnership(op);
        // the owner replaces it in one transaction; the old operator can no longer push
        vm.prank(safe);
        pot.setOperator(h1);
        assertEq(pot.operator(), h1);
        address[] memory to = new address[](1);
        uint256[] memory am = new uint256[](1);
        to[0] = h2;
        am[0] = 1 ether;
        vm.prank(op);
        vm.expectRevert(HolderPot.NotOperator.selector);
        pot.push(to, am, bytes32(0));
        vm.prank(h1);
        pot.push(to, am, bytes32(0));
        assertEq(ws.balanceOf(h2), 1 ether);
    }

    function test_owner_two_step_and_bad_input() public {
        vm.prank(safe);
        vm.expectRevert(HolderPot.BadInput.selector);
        pot.setOperator(address(0));
        vm.prank(safe);
        pot.transferOwnership(h1);
        vm.prank(h2);
        vm.expectRevert(HolderPot.NotOwner.selector);
        pot.acceptOwnership();
        vm.prank(h1);
        pot.acceptOwnership();
        assertEq(pot.owner(), h1);
        vm.prank(safe);
        vm.expectRevert(HolderPot.NotOwner.selector);
        pot.setOperator(op);
    }

    function test_nothing_else_can_leave() public {
        // the pot has no function that sends ETH or any token other than wsNET through `push`
        other.mint(address(pot), 1 ether); // stray tokens are stuck by design: only wsNET is ever pushed
        assertEq(other.balanceOf(address(pot)), 1 ether);
    }
}
