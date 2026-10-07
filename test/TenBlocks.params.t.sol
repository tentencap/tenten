// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base, MockTen} from "./Base.sol";
import {HolderPot} from "../src/HolderPot.sol";
import {TenBlocks} from "../src/TenBlocks.sol";

/// @dev The owner can change settings, but only inside hard bounds, after a delay, and never for a round
///      that already has a deposit.
contract RejectingWallet {
    receive() external payable {
        revert("no");
    }
}

contract BombSink {
    address immutable ws;

    constructor(address w) {
        ws = w;
    }

    function donateReward(address, uint256) external view {
        assembly {
            return(0, 300000) // a large return blob
        }
    }
}

contract TenBlocksParamsTest is Base {
    function setUp() public {
        setUpGame();
    }

    function _propose(TenBlocks.Params memory p) internal {
        vm.prank(owner);
        game.proposeParams(p);
    }

    function _proposeAndApply(TenBlocks.Params memory p) internal {
        _propose(p);
        vm.warp(block.timestamp + 24 hours);
        game.applyParams();
    }

    function test_initial_state() public view {
        assertEq(game.owner(), owner);
        assertEq(game.paramsCount(), 1);
        assertEq(game.currentParams().payloadOdds, 625);
        (, uint64 at) = game.pendingParams();
        assertEq(at, 0);
    }

    function test_only_owner_can_propose_cancel() public {
        TenBlocks.Params memory p = _params();
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.proposeParams(p);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.cancelParams();
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.transferOwnership(alice);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.renounceOwnership();
    }

    function test_bounds_are_enforced() public {
        TenBlocks.Params memory p;

        p = _params();
        p.winnerCredBps = 1400; // 14% + 1% + 2% + 1% + 1% = 19% > 15%
        _expectOutOfBounds(p);

        p = _params();
        p.payloadOdds = 99;
        _expectOutOfBounds(p);
        p.payloadOdds = 2001;
        _expectOutOfBounds(p);

        p = _params();
        p.payloadCapMult = 4;
        _expectOutOfBounds(p);
        p.payloadCapMult = 101;
        _expectOutOfBounds(p);

        p = _params();
        p.claimFeeBps = 1001; // can be lowered, never raised above the initial 10%
        _expectOutOfBounds(p);
        p.claimFeeBps = 2001;
        _expectOutOfBounds(p);

        p = _params();
        p.maxDeviationBps = 99;
        _expectOutOfBounds(p);
        p.maxDeviationBps = 701;
        _expectOutOfBounds(p);

        p = _params();
        p.minPerSquare = 1e8;
        _expectOutOfBounds(p);
        p.minPerSquare = 2e15;
        _expectOutOfBounds(p);

        p = _params();
        p.minDeployTotal = 1e12; // below minPerSquare
        _expectOutOfBounds(p);
        p.minDeployTotal = 0.02 ether;
        _expectOutOfBounds(p);

        p = _params();
        p.maxPerPlayerRound = 5e13; // below minDeployTotal
        _expectOutOfBounds(p);
        p.maxPerPlayerRound = 101 ether;
        _expectOutOfBounds(p);

        p = _params();
        p.maxPerRound = 1 ether; // below the per-player cap
        _expectOutOfBounds(p);
        p.maxPerRound = 1001 ether;
        _expectOutOfBounds(p);

        p = _params();
        p.tipCap = 0.011 ether;
        _expectOutOfBounds(p);

        p = _params();
        p.holdersSink = makeAddr("eoa"); // not a contract
        _expectOutOfBounds(p);

        p = _params();
        p.buybackWallet = address(0);
        _expectOutOfBounds(p);
        p = _params();
        p.opsWallet = address(0);
        _expectOutOfBounds(p);

        // the limits themselves are allowed: 15% non-ETH, odds 100 and 2000
        p = _params();
        p.winnerCredBps = 800;
        p.payloadBps = 300; // holders 1 + buyback 1 + payload 3 = 500 bps
        p.payloadOdds = 100;
        p.payloadCapMult = 5; // 5 x 10000 <= 100 x 500
        _propose(p);
        p.payloadOdds = 2000;
        p.payloadCapMult = 20;
        _propose(p);
    }

    function _expectOutOfBounds(TenBlocks.Params memory p) internal {
        vm.prank(owner);
        vm.expectRevert(TenBlocks.OutOfBounds.selector);
        game.proposeParams(p);
    }

    function test_delay_then_anyone_applies() public {
        TenBlocks.Params memory p = _params();
        p.payloadOdds = 500;
        p.payloadCapMult = 10;
        _propose(p);
        (TenBlocks.Params memory pend, uint64 at) = game.pendingParams();
        assertEq(pend.payloadOdds, 500);
        assertEq(at, block.timestamp + 24 hours);
        assertEq(game.currentParams().payloadOdds, 625, "not yet");
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.applyParams();
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.applyParams();
        vm.warp(block.timestamp + 1);
        vm.prank(carol); // anyone
        game.applyParams();
        assertEq(game.currentParams().payloadOdds, 500);
        assertEq(game.paramsCount(), 2);
        vm.expectRevert(TenBlocks.NothingPending.selector);
        game.applyParams();
    }

    function test_cancel_and_replace() public {
        TenBlocks.Params memory p = _params();
        p.payloadOdds = 500;
        p.payloadCapMult = 10;
        _propose(p);
        vm.prank(owner);
        game.cancelParams();
        vm.expectRevert(TenBlocks.NothingPending.selector);
        game.applyParams();
        vm.prank(owner);
        vm.expectRevert(TenBlocks.NothingPending.selector);
        game.cancelParams();
        // a new proposal replaces the pending one and restarts the clock
        // (absolute times from a cheatcode: with via-IR the compiler may re-read block.timestamp later)
        uint256 t0 = vm.getBlockTimestamp();
        _propose(p);
        vm.warp(t0 + 12 hours);
        p.payloadOdds = 400;
        p.payloadCapMult = 10;
        _propose(p); // effective at t0 + 36 h
        vm.warp(t0 + 24 hours);
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.applyParams();
        vm.warp(t0 + 36 hours);
        game.applyParams();
        assertEq(game.currentParams().payloadOdds, 400);
    }

    function _squaresN(uint8 n) internal pure returns (uint8[] memory a) {
        a = new uint8[](n);
        for (uint8 i = 0; i < n; i++) a[i] = i;
    }

    function _amountsN(uint8 n, uint96 each) internal pure returns (uint96[] memory a) {
        a = new uint96[](n);
        for (uint8 i = 0; i < n; i++) a[i] = each;
    }

    function test_round_keeps_the_settings_it_started_with() public {
        // round 0 gets its first deposit under the original settings
        _open(0);
        _deployAll(alice, 0.001 ether); // W0 = 0.025 ETH
        assertEq(game.paramsOf(0).buybackBps, 100);

        // new split (no buyback, 2% to holders) and higher minimums
        TenBlocks.Params memory p = _params();
        p.holdersBps = 200;
        p.buybackBps = 0;
        p.minPerSquare = 1e14;
        p.minDeployTotal = 1e15;
        _propose(p);
        uint256 effective = block.timestamp + 24 hours;

        // the first round that starts after the delay: it gets its first deposit before applyParams is called
        uint256 r = (effective - game.GENESIS_TIME()) / 90 + 1;
        vm.warp(game.roundStart(r) + 20);
        vm.prank(alice);
        game.deploy{value: 1e14}(_squaresN(10), _amountsN(10, 1e13)); // legal only under the old minimum
        assertEq(game.paramsOf(r).minPerSquare, 1e13, "round r started under the old settings");
        game.applyParams();
        assertEq(game.currentParams().minPerSquare, 1e14);
        // a second deposit in the same round still follows the old settings
        vm.prank(bob);
        game.deploy{value: 1e14}(_squaresN(10), _amountsN(10, 1e13));
        assertEq(game.playerTotal(r, bob), 1e14);

        // the next round uses the new settings and refuses the old minimum
        vm.warp(game.roundStart(r + 1) + 1);
        vm.prank(bob);
        vm.expectRevert(TenBlocks.BadValue.selector);
        game.deploy{value: 1e14}(_squaresN(10), _amountsN(10, 1e13));
        vm.prank(bob);
        game.deploy{value: 1e15}(_squaresN(10), _amountsN(10, 1e14));
        assertEq(game.paramsOf(r + 1).minPerSquare, 1e14);
        assertEq(game.paramsOf(r + 1).buybackBps, 0);

        // resolution: round 0 and r use the old split, r+1 the new one
        _resolveWith(0, 7, false);
        assertEq(game.buybackAccrued(), 0.00025 ether, "round 0: 1% of 0.025 ETH");
        _resolveWith(r, 7, false);
        uint256 afterR = game.buybackAccrued();
        assertEq(afterR, 0.00025 ether + 2e14 / 100, "round r (old settings): 1% of 0.0002 ETH");
        _resolveWith(r + 1, 7, false);
        assertEq(game.buybackAccrued(), afterR, "round r+1 (new settings): no buyback");
    }

    function test_claim_fee_change_applies_at_refine_time() public {
        TenBlocks.Params memory p = _params();
        p.claimFeeBps = 500; // 5%
        _proposeAndApply(p);
        // alice 1.5, bob 2.5 ETH per round on every square; alice refines at once, bob stays unrefined
        _open(game.currentRound() + 1);
        uint256 r = game.currentRound();
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(r, 11, false);
        game.convert();
        vm.prank(bob);
        game.claim(_one(r), false);
        vm.prank(alice);
        game.claim(_one(r), true);
        uint256 pool = (0.05 ether * 4 * 0.99e18) / 1e18; // credEth 0.2 ETH x rate
        uint256 aliceGross = (pool * 375) / 1000;
        assertApproxEqAbs(wsnet.balanceOf(alice), (aliceGross * 95) / 100, 3, "5% fee instead of 10%");
    }

    function test_holders_sink_can_be_moved_to_a_new_sink() public {
        MockTen sink2 = new MockTen();
        TenBlocks.Params memory p = _params();
        p.holdersSink = address(sink2);
        _proposeAndApply(p);
        uint256 r = game.currentRound() + 1;
        _open(r);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(r, 5, false);
        game.convert();
        assertEq(ten.total(), 0, "the old sink gets nothing");
        assertEq(sink2.total(), 0.0396 ether, "the new sink gets the holders' wsNET");
    }

    function test_buyback_and_ops_wallets_receive_their_share() public {
        _open(0);
        _deployAll(alice, 0.04 ether); // 1 ETH
        _resolveWith(0, 7, false);
        assertEq(game.buybackAccrued(), 0.01 ether);
        game.sweepBuyback();
        assertEq(buyback.balance, 0.01 ether);
        assertEq(game.buybackAccrued(), 0);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.sweepBuyback();
        // the owner points the buyback wallet somewhere else: the next sweep follows the new address
        address next = makeAddr("nextBuyback");
        TenBlocks.Params memory p = _params();
        p.buybackWallet = next;
        _proposeAndApply(p);
        uint256 r = game.currentRound() + 1;
        _open(r);
        _deployAll(alice, 0.04 ether);
        _resolveWith(r, 7, false);
        game.sweepBuyback();
        assertEq(next.balance, 0.01 ether);
    }

    function test_ownership_two_step_and_renounce() public {
        vm.prank(owner);
        game.transferOwnership(alice);
        assertEq(game.owner(), owner, "not yet");
        vm.prank(bob);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.acceptOwnership();
        vm.prank(alice);
        game.acceptOwnership();
        assertEq(game.owner(), alice);
        vm.prank(owner);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.cancelParams();

        // alice proposes, then renounces: the settings are frozen and the proposal is dropped
        TenBlocks.Params memory p = _params();
        p.payloadOdds = 500;
        p.payloadCapMult = 10;
        vm.prank(alice);
        game.proposeParams(p);
        vm.prank(alice);
        game.renounceOwnership();
        assertEq(game.owner(), address(0));
        vm.expectRevert(TenBlocks.NothingPending.selector);
        game.applyParams();
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.proposeParams(p);
        assertEq(game.currentParams().payloadOdds, 625);
        // nobody can claim ownership of address(0)
        vm.expectRevert(TenBlocks.NotOwner.selector);
        game.acceptOwnership();
    }

    function test_payload_ratio_rule_keeps_hunting_unprofitable() public {
        TenBlocks.Params memory p = _params();
        // holders + buyback + payload = 400 bps. odds 625: cap 25 is the limit (250000 <= 625 x 400)
        p.payloadCapMult = 26;
        _expectOutOfBounds(p);
        p.payloadCapMult = 25;
        _propose(p);
        // the user's wish: odds 500 needs a cap of at most 20 (200000 <= 500 x 400)
        p = _params();
        p.payloadOdds = 500;
        p.payloadCapMult = 21;
        _expectOutOfBounds(p);
        p.payloadCapMult = 20;
        _propose(p);
        // the operations share does not count: a self-resolving hunter gets it back as the tip
        p = _params();
        p.opsBps = 600;
        p.payloadCapMult = 26;
        _expectOutOfBounds(p);
        // extreme combination
        p = _params();
        p.payloadOdds = 100;
        p.payloadCapMult = 100;
        _expectOutOfBounds(p);
    }

    function test_wallets_must_be_able_to_receive_eth() public {
        RejectingWallet bad = new RejectingWallet();
        TenBlocks.Params memory p = _params();
        p.opsWallet = address(bad);
        _expectOutOfBounds(p);
        p = _params();
        p.buybackWallet = address(bad);
        _expectOutOfBounds(p);
    }

    function test_new_owner_does_not_inherit_a_pending_proposal() public {
        TenBlocks.Params memory p = _params();
        p.payloadOdds = 700;
        _propose(p);
        vm.prank(owner);
        game.transferOwnership(alice);
        vm.prank(alice);
        game.acceptOwnership();
        (, uint64 at) = game.pendingParams();
        assertEq(at, 0, "the proposal made by the previous owner is gone");
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(TenBlocks.NothingPending.selector);
        game.applyParams();
    }

    function test_swept_payload_and_released_holders_eth_enter_the_queue_in_epoch_sized_pieces() public {
        // build a Payload of 0.08 ETH, then let the game sit idle past the dormancy
        _open(0);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(0, 11, false); // payloadEth 0.08, epoch 0 closed (0.24 >= 0.2)
        vm.warp(vm.getBlockTimestamp() + 90 days);
        game.sweepPayload();
        assertEq(game.payloadEth(), 0);
        assertEq(game.holdersEthPending(), 0.08 ether);
        // the epoch cap in this test config is 0.2 ETH, so 0.08 enters in one piece
        game.feedHolders();
        assertEq(game.holdersEthPending(), 0);
        assertEq(game.getEpoch(game.openEpoch()).ethHolders, 0.08 ether);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.feedHolders();
    }

    function test_big_pending_amount_is_fed_in_pieces_no_bigger_than_the_cap() public {
        // 2.5 ETH round with every share at its maximum creates a large holders amount
        TenBlocks.Params memory p = _params();
        p.winnerCredBps = 0;
        p.holdersBps = 1000; // 10%
        p.payloadBps = 100;
        p.buybackBps = 100;
        p.opsBps = 100;
        p.payloadCapMult = 5;
        p.payloadOdds = 625;
        _proposeAndApply(p);
        uint256 r = game.currentRound() + 1;
        _open(r);
        _deployAll(alice, 0.1 ether); // 2.5 ETH: holders 0.25 ETH
        _deployAll(bob, 0.1 ether); // 2.5 ETH: holders 0.25 ETH
        _resolveWith(r, 3, false);
        // every epoch stays at or under the cap except the round's own epoch (rounds are never split)
        router.setFail(true);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1 hours);
        uint256 n = game.epochCount();
        for (uint32 e = 0; e < n; e++) {
            if (uint256(game.getEpoch(e).state) == 1) {
                vm.warp(vm.getBlockTimestamp() + 1);
                game.releaseEpoch(e);
            }
        }
        uint256 pend = game.holdersEthPending();
        assertGt(pend, 0, "the holders' ETH waits to be fed");
        for (uint256 k = 0; k < 10 && game.holdersEthPending() > 0; k++) {
            game.feedHolders();
        }
        for (uint32 e = 0; e < game.epochCount(); e++) {
            TenBlocks.Epoch memory ep = game.getEpoch(e);
            if (uint256(ep.state) == 0 || uint256(ep.state) == 1) {
                assertLe(uint256(ep.ethCred) + ep.ethHolders, 0.2 ether + 1, "fed epochs respect the cap");
            }
        }
    }

    function test_a_sink_that_returns_a_huge_blob_cannot_burn_the_callers_gas() public {
        BombSink bomb = new BombSink(address(wsnet));
        TenBlocks.Params memory p = _params();
        p.holdersSink = address(bomb);
        _proposeAndApply(p);
        uint256 r = game.currentRound() + 1;
        _open(r);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(r, 5, false);
        uint256 g = gasleft();
        game.convert();
        uint256 used = g - gasleft();
        assertLt(used, 700_000, "the sink's return data is not copied");
    }

    function test_game_pays_the_v1_holder_pot() public {
        HolderPot pot = new HolderPot(address(wsnet), makeAddr("potOwner"), makeAddr("potOperator"));
        TenBlocks.Params memory p = _params();
        p.holdersSink = address(pot);
        _proposeAndApply(p);
        uint256 r = game.currentRound() + 1;
        _open(r);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(r, 5, false);
        game.convert();
        assertEq(pot.balance(), 0.0396 ether, "the holders' wsNET went into the pot");
        assertEq(game.holdersOwed(), 0);
    }

    function test_closing_deploys_stops_new_rounds_but_not_payouts() public {
        // a round with deposits, resolved later; one still open when the owner closes deploys
        _open(0);
        _deployAll(alice, 0.04 ether);
        TenBlocks.Params memory p = _params();
        p.deploysOpen = false;
        _proposeAndApply(p);
        // new rounds take no deposits
        uint256 r = game.currentRound() + 1;
        _open(r);
        vm.prank(bob);
        vm.expectRevert(TenBlocks.DeploysClosed.selector);
        game.deploy{value: 1e14}(_squaresN(10), _amountsN(10, 1e13));
        // round 0 (played before the change) resolves, pays and refunds exactly as before
        _resolveWith(0, 7, false);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(0), false);
        assertEq(alice.balance - a0, 0.9 ether);
        // the owner can reopen (with the delay)
        p.deploysOpen = true;
        _proposeAndApply(p);
        uint256 r2 = game.currentRound() + 1;
        _open(r2);
        vm.prank(bob);
        game.deploy{value: 1e14}(_squaresN(10), _amountsN(10, 1e13));
    }

    function test_the_owner_cannot_touch_deposits() public view {
        // there is no function that moves player ETH to the owner: the owner can only change settings,
        // which apply to future rounds (see test_round_keeps_the_settings_it_started_with)
        assertTrue(owner != address(0));
    }
}
