// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base, MockERC20, MockPool, MockRouter, MockTen, TenBlocksHarness} from "./Base.sol";
import {TenBlocks} from "../src/TenBlocks.sol";

contract Rejecter {
    receive() external payable {
        revert("no eth");
    }

    function refundTo(TenBlocks g, address payable to, uint256 r) external {
        g.refundTo(to, r);
    }

    function deploySquare(TenBlocks g, uint8 s, uint96 a) external payable {
        uint8[] memory sq = new uint8[](1);
        uint96[] memory am = new uint96[](1);
        sq[0] = s;
        am[0] = a;
        g.deploy{value: msg.value}(sq, am);
    }

    function claim(TenBlocks g, uint256 r) external {
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        g.claim(rs, false);
    }

    function claimTo(TenBlocks g, address payable to, uint256 r) external {
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        g.claimTo(to, rs, false);
    }

    function resolve(TenBlocks g, uint256 r, uint256 rv) external {
        g.resolve(r, [rv, uint256(0)]);
    }

    function refund(TenBlocks g, uint256 r) external {
        g.refund(r);
    }
}

contract Reenterer {
    TenBlocks public game;
    uint256 public round;
    bool public blocked;
    bool public reentered;

    constructor(TenBlocks g) {
        game = g;
    }

    function deployAll(uint96 each) external payable {
        uint8[] memory s = new uint8[](25);
        uint96[] memory a = new uint96[](25);
        for (uint8 i = 0; i < 25; i++) {
            s[i] = i;
            a[i] = each;
        }
        game.deploy{value: msg.value}(s, a);
    }

    function go(uint256 r) external {
        round = r;
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        game.claim(rs, true);
    }

    receive() external payable {
        uint256[] memory rs = new uint256[](1);
        rs[0] = round;
        try game.claim(rs, true) {
            reentered = true;
        } catch {
            blocked = true; // reentrancy guard stopped it
        }
    }
}

contract TenBlocksTest is Base {
    function setUp() public {
        setUpGame();
    }

    // ------------------------------------------------------------ constructor
    function test_constructor_validation() public {
        TenBlocks.Config memory c = _config();
        c.genesisTime = uint64(block.timestamp + 1000); // less than the TWAP window ahead
        vm.expectRevert(TenBlocks.BadConfig.selector);
        new TenBlocksHarness(c);

        c = _config();
        c.params.holdersSink = makeAddr("nocode"); // the holders sink must be a contract
        vm.expectRevert(TenBlocks.OutOfBounds.selector);
        new TenBlocksHarness(c);

        c = _config();
        c.feeEthUsdg = 3000; // does not match the pool
        vm.expectRevert(TenBlocks.BadConfig.selector);
        new TenBlocksHarness(c);

        c = _config();
        c.params.opsWallet = address(0);
        vm.expectRevert(TenBlocks.OutOfBounds.selector);
        new TenBlocksHarness(c);

        c = _config();
        c.twapSeconds = 2 days;
        vm.expectRevert(TenBlocks.BadConfig.selector);
        new TenBlocksHarness(c);

        assertEq(poolB.cardinalityNext(), 200, "the thin pool's observation buffer is grown");
    }

    // ------------------------------------------------------------ deploy
    function test_deploy_basic() public {
        _open(0);
        uint96 total = _deployAll(alice, 0.001 ether);
        uint96[25] memory t = game.squareTotals(0);
        for (uint256 i = 0; i < 25; i++) assertEq(t[i], 0.001 ether);
        assertEq(game.playerTotal(0, alice), total);
        assertEq(game.getRound(0).totalWager, total);
        assertEq(game.getRound(0).status, 1);
        assertEq(game.recordCount(0, alice), 1, "select-all is one record");
        assertEq(address(game).balance, total);
    }

    function test_deploy_reverts() public {
        vm.expectRevert(TenBlocks.NotStarted.selector);
        game.currentRound();

        _open(0);
        uint8[] memory s = new uint8[](1);
        uint96[] memory a = new uint96[](1);
        s[0] = 0;
        a[0] = 1e13;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadValue.selector); // total below 0.0001 ETH
        game.deploy{value: 1e13}(s, a);

        a[0] = 0.0001 ether;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadValue.selector); // msg.value != sum
        game.deploy{value: 0.0001 ether + 1}(s, a);

        a[0] = 1e12; // below per-square minimum
        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadValue.selector);
        game.deploy{value: 0.0001 ether}(s, a);
        a[0] = 0.0001 ether;

        s[0] = 25;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadInput.selector);
        game.deploy{value: 0.0001 ether}(s, a);

        uint8[] memory s2 = new uint8[](2);
        uint96[] memory a2 = new uint96[](2);
        s2[0] = 3;
        s2[1] = 3;
        a2[0] = 0.0001 ether;
        a2[1] = 0.0001 ether;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadInput.selector);
        game.deploy{value: 0.0002 ether}(s2, a2);

        vm.prank(alice);
        vm.expectRevert(TenBlocks.BadInput.selector);
        game.deploy{value: 0.0001 ether}(new uint8[](0), new uint96[](0));

        vm.warp(game.bettingEnd(0));
        s[0] = 1;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.Closed.selector);
        game.deploy{value: 0.0001 ether}(s, a);
    }

    function test_caps() public {
        _open(0);
        _deployAll(alice, 0.1 ether); // 2.5 ETH = player cap
        vm.prank(alice);
        vm.expectRevert(TenBlocks.LimitPlayer.selector);
        game.deploy{value: 0.0001 ether}(_one8(0), _one96(0.0001 ether));
        _deployAll(bob, 0.1 ether);
        _deployAll(carol, 0.1 ether);
        address d = makeAddr("d");
        address e = makeAddr("e");
        vm.deal(d, 10 ether);
        vm.deal(e, 10 ether);
        _deployAll(d, 0.1 ether);
        assertEq(game.getRound(0).totalWager, 10 ether);
        vm.prank(e);
        vm.expectRevert(TenBlocks.LimitRound.selector);
        game.deploy{value: 0.0001 ether}(_one8(0), _one96(0.0001 ether));
    }

    function test_records_cap_and_fold() public {
        _open(0);
        _deployOn(alice, 0, 0.0001 ether);
        _deployOn(alice, 0, 0.0002 ether); // same mask folds
        assertEq(game.recordCount(0, alice), 1);
        assertEq(game.playerSquares(0, alice)[0], 0.0003 ether);
        for (uint8 i = 1; i < 25; i++) _deployOn(alice, i, 0.0001 ether);
        assertEq(game.recordCount(0, alice), 25);
        uint8[] memory s = new uint8[](2);
        uint96[] memory a = new uint96[](2);
        s[0] = 0;
        s[1] = 1; // a new mask: a 26th record
        a[0] = 0.0001 ether;
        a[1] = 0.0001 ether;
        vm.prank(alice);
        vm.expectRevert(TenBlocks.TooManyRecords.selector);
        game.deploy{value: 0.0002 ether}(s, a);
    }

    // ------------------------------------------------------------ resolve
    function test_resolve_guards() public {
        _open(0);
        _deployAll(alice, 0.001 ether);
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.resolve(0, [uint256(1), 0]);
        _resolvable(0);
        vm.expectRevert(TenBlocks.NotResolvable.selector); // round 5 has no deposits
        game.resolve(5, [uint256(1), 0]);
        game.resolve(0, [_rvFor(0, 3, false), uint256(0)]);
        vm.expectRevert(TenBlocks.NotResolvable.selector); // already resolved
        game.resolve(0, [uint256(1), 0]);
    }

    function test_resolve_strict_order() public {
        _open(0);
        _deployAll(alice, 0.001 ether);
        _open(1);
        _deployAll(bob, 0.001 ether);
        _resolvable(1);
        vm.expectRevert(TenBlocks.PrevPending.selector);
        game.resolve(1, [_rvFor(1, 2, false), uint256(0)]);
        game.resolve(0, [_rvFor(0, 2, false), uint256(0)]);
        game.resolve(1, [_rvFor(1, 2, false), uint256(0)]);
        assertEq(game.getRound(1).status, 2);
    }

    function test_resolveMany_cap_and_skips_resolved() public {
        for (uint256 r = 0; r < 3; r++) {
            _open(r);
            _deployAll(alice, 0.001 ether);
        }
        _resolvable(2);
        // somebody resolves round 0 first
        game.resolve(0, [_rvFor(0, 4, false), uint256(0)]);
        uint256[] memory rs = new uint256[](3);
        uint256[2][] memory sigs = new uint256[2][](3);
        for (uint256 r = 0; r < 3; r++) {
            rs[r] = r;
            sigs[r] = [_rvFor(r, 4, false), uint256(0)];
        }
        game.resolveMany(rs, sigs); // does not revert on the already resolved round 0
        assertEq(game.getRound(2).status, 2);
        vm.expectRevert(TenBlocks.TooManyRounds.selector);
        game.resolveMany(new uint256[](17), new uint256[2][](17));
    }

    function test_resolveAndDeploy_survives_a_front_runner() public {
        _open(0);
        _deployAll(alice, 0.001 ether);
        vm.warp(game.roundStart(1) + 20);
        uint256[2] memory sig = [_rvFor(0, 6, false), uint256(0)];
        // a keeper resolves round 0 first
        game.resolve(0, sig);
        vm.prank(bob);
        game.resolveAndDeploy{value: 0.001 ether}(0, sig, _one8(0), _one96(0.001 ether));
        assertEq(game.playerTotal(1, bob), 0.001 ether, "the deploy still goes through");
    }

    function test_resolveAndDeploy() public {
        _open(0);
        _deployAll(alice, 0.001 ether);
        vm.warp(game.roundStart(1) + 20);
        uint256[2] memory sig = [_rvFor(0, 6, false), uint256(0)];
        vm.prank(bob);
        uint256 b0 = bob.balance;
        game.resolveAndDeploy{value: 0.001 ether}(0, sig, _one8(0), _one96(0.001 ether));
        assertEq(game.getRound(0).status, 2);
        assertEq(game.playerTotal(1, bob), 0.001 ether);
        // bob paid 0.001 ETH for the deploy and received the resolver tip (capped)
        assertEq(b0 - bob.balance, 0.001 ether - TIP);
    }

    function test_refundable_blocks_resolve() public {
        _open(0);
        _deployAll(alice, 0.001 ether);
        vm.warp(game.beaconUnlock(0) + 24 hours);
        vm.expectRevert(TenBlocks.IsRefundable.selector);
        game.resolve(0, [uint256(1), 0]);
    }

    // ------------------------------------------------------------ split, operations and tips
    function test_split_and_resolver_tip() public {
        _open(0);
        _deployAll(alice, 0.04 ether); // 1 ETH
        uint256 t0 = address(this).balance;
        _resolveWith(0, 7, false);
        TenBlocks.Round memory R = game.getRound(0);
        assertEq(R.potEth, 0.9 ether, "90% ETH to winners");
        assertEq(R.credEth, 0.05 ether, "5% wsNET credit");
        TenBlocks.Epoch memory e = game.getEpoch(0);
        assertEq(e.ethCred, 0.05 ether);
        assertEq(e.ethHolders, 0.01 ether, "1% to TEN holders");
        assertEq(game.buybackAccrued(), 0.01 ether, "1% buyback");
        assertEq(game.payloadEth(), 0.02 ether, "2% Payload, in ETH");
        // 1% operations: the resolver is tipped up to the cap, the rest accrues to the operations wallet
        assertEq(address(this).balance - t0, TIP);
        assertEq(game.opsAccrued(), 0.01 ether - TIP);
        assertEq(address(game).balance, 1 ether - TIP);
    }

    function test_sweepOps_pays_wallet() public {
        _open(0);
        _deployAll(alice, 0.04 ether);
        _resolveWith(0, 7, false);
        vm.expectEmit(false, false, false, true);
        emit TenBlocks.OpsSwept(0.01 ether - TIP);
        game.sweepOps();
        assertEq(ops.balance, 0.01 ether - TIP);
        assertEq(game.opsAccrued(), 0);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.sweepOps();
    }

    function test_tip_forfeited_when_resolver_rejects_eth() public {
        Rejecter rej = new Rejecter();
        _open(0);
        _deployAll(alice, 0.04 ether);
        uint256 rv = _rvFor(0, 7, false);
        _resolvable(0);
        rej.resolve(game, 0, rv);
        assertEq(game.opsAccrued(), 0.01 ether, "the whole 1% goes to operations");
        assertEq(address(game).balance, 1 ether);
    }

    function test_small_round_tip_is_its_own_one_percent() public {
        _open(0);
        _deployOn(alice, 0, 0.001 ether); // ops share 0.00001 ETH < cap
        uint256 t0 = address(this).balance;
        _resolveWith(0, 0, false);
        assertEq(address(this).balance - t0, 0.00001 ether);
        assertEq(game.opsAccrued(), 0);
    }

    // ------------------------------------------------------------ settlement and claims
    function test_winner_shares_and_exact_claims() public {
        _open(0);
        _deployAll(alice, 0.01 ether); // 0.25
        _deployAll(bob, 0.03 ether); // 0.75
        _resolveWith(0, 7, false);
        TenBlocks.Round memory R = game.getRound(0);
        assertEq(R.status, 2);
        assertEq(R.winningSquare, 7);
        assertEq(R.winnerTotal, 0.04 ether);
        assertEq(R.potEth, 0.9 ether);

        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        vm.prank(alice);
        game.claim(_one(0), false);
        vm.prank(bob);
        game.claim(_one(0), false);
        assertEq(alice.balance - a0, 0.225 ether);
        assertEq(bob.balance - b0, 0.675 ether);

        vm.prank(alice);
        vm.expectRevert(TenBlocks.NothingToClaim.selector); // pool part is not converted yet
        game.claim(_one(0), false);
    }

    function test_loser_cannot_claim() public {
        _open(0);
        _deployOn(alice, 3, 0.01 ether);
        _deployOn(bob, 7, 0.01 ether);
        _resolveWith(0, 7, false);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NoStake.selector);
        game.claim(_one(0), false);
        vm.prank(carol);
        vm.expectRevert(TenBlocks.NoStake.selector);
        game.claim(_one(0), false);
    }

    function test_empty_square_carries_to_next_winner() public {
        _open(0);
        _deployOn(alice, 3, 0.02 ether);
        _resolveWith(0, 5, false);
        assertEq(game.getRound(0).status, 3);
        assertEq(game.carryEth(), 0.018 ether);
        assertEq(game.carryCredit(), 0.001 ether);
        // the holders' and Payload shares of the empty round still go through
        assertEq(game.getEpoch(0).ethHolders, 0.0002 ether);
        assertEq(game.payloadEth(), 0.0004 ether);

        _open(1);
        _deployAll(bob, 0.01 ether); // 0.25
        _resolveWith(1, 9, false);
        TenBlocks.Round memory r1 = game.getRound(1);
        assertEq(r1.potEth, 0.225 ether + 0.018 ether);
        assertEq(r1.credEth, 0.0125 ether + 0.001 ether);
        assertEq(game.carryEth(), 0);
        assertEq(game.carryCredit(), 0);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        game.claim(_one(1), false);
        assertEq(bob.balance - b0, 0.243 ether);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotWinnerRound.selector);
        game.claim(_one(0), false);
    }

    function test_chain_of_empty_rounds_then_winner() public {
        for (uint256 r = 0; r < 3; r++) {
            _open(r);
            _deployOn(alice, 1, 0.01 ether);
            _resolveWith(r, 2, false);
        }
        assertEq(game.carryEth(), 3 * 0.009 ether);
        _open(3);
        _deployOn(bob, 2, 0.01 ether);
        _resolveWith(3, 2, false);
        assertEq(game.getRound(3).potEth, 4 * 0.009 ether);
        assertEq(game.carryEth(), 0);
    }

    // ------------------------------------------------------------ conversion and the fee index
    // Two players: alice 1.5 ETH and bob 2.5 ETH on every square, W = 4 ETH. Non-ETH: 0.2 + 0.08 = 0.28 ETH,
    // which closes the epoch (>= 0.25). wsNET: pool 0.198, holders 0.0792 (rate 0.99).
    function _bigWinnerRound(uint256 r, uint8 square, bool hit) internal {
        _open(r);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _resolveWith(r, square, hit);
    }

    function test_convert_flow_and_fee_redistribution() public {
        _bigWinnerRound(0, 11, false);
        assertEq(uint256(game.getEpoch(0).state), 1, "epoch closed by size");
        game.convert();
        TenBlocks.Epoch memory e = game.getEpoch(0);
        assertEq(uint256(e.state), 2);
        assertEq(e.rate, 0.99e18);
        assertEq(ten.total(), 0.0396 ether, "TEN holders' 2%, in wsNET");
        uint256 pool = (uint256(game.getRound(0).credEth) * e.rate) / 1e18;
        assertEq(pool, 0.198 ether);
        assertEq(game.reservedWs(), pool);

        // alice (37.5% of the square) claims and refines at once; bob (62.5%) claims and refines last
        vm.prank(alice);
        game.claim(_one(0), true);
        uint256 aliceWs = wsnet.balanceOf(alice);
        uint256 aliceShare = (pool * 375) / 1000;
        assertApproxEqAbs(aliceWs, (aliceShare * 90) / 100, 2, "alice pays 10% to the unclaimed");

        vm.prank(bob);
        game.claim(_one(0), true);
        uint256 bobWs = wsnet.balanceOf(bob);
        assertApproxEqAbs(bobWs, (pool - aliceShare) + aliceShare / 10, 3, "bob is last: no fee, gets alice's fee");
        assertApproxEqAbs(aliceWs + bobWs, pool, 3, "nothing lost, nothing created");
        assertLe(game.reservedWs(), 3, "only rounding dust is left unattributed");
        assertLe(game.totalAttributed(), game.totalRefined() + 3);
    }

    function test_lone_claimer_pays_no_fee_even_with_rounding_dust() public {
        // regression for review A-1: three rounds in one epoch leave a few wei of unattributed dust
        for (uint256 r = 0; r < 3; r++) {
            _open(r);
            _deployAll(alice, 0.04 ether); // alice is the only winner each time
            _resolveWith(r, 3, false);
        }
        vm.warp(block.timestamp + 1 hours);
        game.convert();
        uint256[] memory rs = new uint256[](3);
        for (uint256 r = 0; r < 3; r++) rs[r] = r;
        vm.prank(alice);
        game.claim(rs, true);
        uint256 pool = 3 * ((uint256(0.05 ether) * 0.99e18) / 1e18);
        assertApproxEqAbs(wsnet.balanceOf(alice), pool, 3, "no 10% fee for the last holder");
        assertEq(game.totalRefined(), 0, "no fee was stranded");
    }

    function test_unclaimed_earns_fee_of_claimer() public {
        _bigWinnerRound(0, 11, false);
        game.convert();
        vm.prank(bob);
        game.claim(_one(0), false);
        (uint256 balBefore,, uint256 pendBefore) = game.minerState(bob);
        assertEq(pendBefore, 0);
        vm.prank(alice);
        game.claim(_one(0), true);
        (uint256 bal, uint256 acc, uint256 pend) = game.minerState(bob);
        assertEq(bal, balBefore);
        uint256 pool = 0.198 ether;
        uint256 aliceShare = (pool * 375) / 1000;
        assertApproxEqAbs(acc + pend, aliceShare / 10, 3, "bob earned 10% of alice's wsNET");
        vm.prank(bob);
        game.withdraw();
        assertApproxEqAbs(wsnet.balanceOf(bob), (pool - aliceShare) + aliceShare / 10, 4);
        vm.prank(bob);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.withdraw();
    }

    function test_refined_wsnet_is_never_taxed() public {
        // alice 1.5 ETH, bob 2.5 ETH, carol 0.5 ETH on every square: W = 4.5 ETH
        _open(0);
        _deployAll(alice, 0.06 ether);
        _deployAll(bob, 0.1 ether);
        _deployAll(carol, 0.02 ether);
        _resolveWith(0, 11, false);
        game.convert();
        vm.prank(bob);
        game.claim(_one(0), false); // bob leaves his wsNET unrefined
        vm.prank(carol);
        game.claim(_one(0), false); // carol too
        vm.prank(alice);
        game.claim(_one(0), true); // alice refines at once: her 10% becomes refined wsNET for bob and carol
        (uint256 bal, uint256 acc, uint256 pend) = game.minerState(bob);
        assertGt(acc + pend, 0, "bob has refined wsNET");
        uint256 refined = acc + pend;
        vm.prank(bob);
        game.withdraw();
        // the fee is 10% of the unrefined balance only; the refined part is paid in full
        assertApproxEqAbs(wsnet.balanceOf(bob), bal - bal / 10 + refined, 3);
    }

    function test_claim_before_and_after_conversion_in_two_steps() public {
        _bigWinnerRound(0, 11, false);
        vm.prank(alice);
        game.claim(_one(0), false); // ETH only, pool not converted
        game.convert();
        vm.prank(alice);
        game.claim(_one(0), false); // pool part now
        (uint256 bal,,) = game.minerState(alice);
        assertEq(bal, (0.198 ether * 375) / 1000);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NothingToClaim.selector);
        game.claim(_one(0), false);
    }

    function test_epoch_closes_by_age_and_convert() public {
        _open(0);
        _deployAll(alice, 0.004 ether); // W = 0.1 ETH, buckets 0.007 ETH
        _resolveWith(0, 0, false);
        vm.expectRevert(TenBlocks.NothingToDo.selector); // too young
        game.convert();
        vm.warp(block.timestamp + 1 hours);
        game.convert();
        assertEq(uint256(game.getEpoch(0).state), 2);
        assertEq(game.openEpoch(), 1);
    }

    function test_small_epoch_below_minimum_still_closes_after_the_timeout() public {
        // regression for review A-2: 0.00007 ETH of non-ETH share is below MIN_EPOCH_ETH
        _open(0);
        _deployOn(alice, 0, 0.001 ether);
        _resolveWith(0, 0, false);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.closeEpoch();
        vm.warp(block.timestamp + 3 days);
        game.closeEpoch();
        game.convert();
        assertEq(uint256(game.getEpoch(0).state), 2);
    }

    function test_age_close_persists_and_open_epoch_can_be_released() public {
        // regression for review B-1: the route is down; nothing may stay stuck
        router.setFail(true);
        _open(0);
        _deployAll(alice, 0.004 ether); // 0.007 ETH, above the minimum, below the cap
        _resolveWith(0, 0, false);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(bytes("router down"));
        game.convert();
        game.closeEpoch(); // the close is its own transaction and persists
        assertEq(uint256(game.getEpoch(0).state), 1);
        vm.warp(block.timestamp + 3 days);
        game.releaseEpoch(0);
        assertEq(uint256(game.getEpoch(0).state), 3);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(0), false);
        assertEq(alice.balance - a0, 0.095 ether, "alice gets 90% + 5% of 0.1 ETH in ETH");
    }

    function test_open_epoch_must_be_closed_before_it_can_be_released() public {
        router.setFail(true);
        _open(0);
        _deployAll(alice, 0.004 ether);
        _resolveWith(0, 0, false);
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 3 days + 1);
        vm.expectRevert(TenBlocks.NothingToDo.selector); // still open: release needs a closed epoch
        game.releaseEpoch(0);
        game.closeEpoch();
        vm.expectRevert(TenBlocks.TooEarly.selector); // and then the full timeout runs from the close
        game.releaseEpoch(0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        game.releaseEpoch(0);
        assertEq(uint256(game.getEpoch(0).state), 3);
    }

    function test_convertEpoch_skips_a_stuck_head_epoch() public {
        // regression for review B-2: an oversized head epoch must not block the next one
        _bigWinnerRound(0, 11, false); // epoch 0 closed, 0.28 ETH
        router.setFail(true);
        vm.expectRevert(bytes("router down"));
        game.convert();
        router.setFail(false);
        // make the head epoch fail on price, a later one fine
        poolB.setTick(1000);
        vm.expectRevert(bytes("slippage"));
        game.convertEpoch(0);
        poolB.setTick(0);
        _bigWinnerRound(1, 12, false); // epoch 1 closed
        poolB.setTick(1000);
        vm.expectRevert(bytes("slippage"));
        game.convertEpoch(1);
        poolB.setTick(0);
        game.convertEpoch(1); // converts the later epoch first
        assertEq(uint256(game.getEpoch(1).state), 2);
        assertEq(uint256(game.getEpoch(0).state), 1);
        game.convert(); // the head epoch converts afterwards
        assertEq(uint256(game.getEpoch(0).state), 2);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.convertEpoch(0);
    }

    function test_convert_guards() public {
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.convert();
        _bigWinnerRound(0, 1, false);
        poolB.setTick(1000);
        vm.expectRevert(bytes("slippage"));
        game.convert();
        poolB.setTick(0);
        poolB.setRevertObserve(true);
        vm.expectRevert(bytes("OLD"));
        game.convert();
        poolB.setRevertObserve(false);
        router.setFail(true);
        vm.expectRevert(bytes("router down"));
        game.convert();
        router.setFail(false);
        game.convert();
        assertEq(uint256(game.getEpoch(0).state), 2);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.convert();
    }

    function test_expected_out_is_net_of_pool_fees() public view {
        // both ticks at 0 => price 1; net of 0.05% and 1% pool fees
        uint256 net = game.twapExpectedOut(1 ether);
        assertEq(net, (((1 ether * (1_000_000 - 500)) / 1_000_000) * (1_000_000 - 10000)) / 1_000_000);
    }

    function test_donate_failure_parks_then_flush() public {
        ten.setFail(true);
        _bigWinnerRound(0, 1, false);
        game.convert();
        assertEq(ten.total(), 0);
        assertEq(game.holdersOwed(), 0.0396 ether);
        ten.setFail(false);
        game.flushHolders();
        assertEq(ten.total(), 0.0396 ether);
        assertEq(game.holdersOwed(), 0);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.flushHolders();
    }

    function test_donate_partial_pull_parks_remainder() public {
        ten.setPullHalf(true);
        _bigWinnerRound(0, 1, false);
        game.convert();
        assertEq(ten.total(), 0.0396 ether / 2);
        assertEq(game.holdersOwed(), 0.0396 ether - 0.0396 ether / 2);
        assertEq(wsnet.allowance(address(game), address(ten)), 0, "allowance cleared");
    }

    // ------------------------------------------------------------ Payload (ETH)
    function test_payload_hit_adds_to_winners_eth_pot() public {
        _bigWinnerRound(0, 11, false); // payload: 2% of 4 ETH = 0.08 ETH
        assertEq(game.payloadEth(), 0.08 ether);
        _open(1);
        _deployAll(alice, 0.04 ether); // 1 ETH
        _deployAll(bob, 0.04 ether); // 1 ETH
        _resolveWith(1, 4, true);
        TenBlocks.Round memory r = game.getRound(1);
        // this round adds 0.04 ETH first: 0.12 ETH; cap is 25 x the round's 2 ETH, so all of it is paid
        assertEq(r.payloadPaid, 0.12 ether);
        assertEq(game.payloadEth(), 0);
        assertEq(r.potEth, 1.8 ether + 0.12 ether);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(1), false);
        assertEq(alice.balance - a0, 0.96 ether);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        game.claim(_one(1), false);
        assertEq(bob.balance - b0, 0.96 ether, "last claimer takes the exact remainder");
    }

    function test_payload_cap_stops_dust_rounds_from_taking_it() public {
        // regression for review B-0: build a Payload, then a dust solo round hits
        _bigWinnerRound(0, 11, false); // Payload 0.08 ETH
        _open(1);
        _deployAll(alice, 1e13); // 0.00025 ETH, covers every square, sole winner
        _resolveWith(1, 4, true);
        TenBlocks.Round memory r = game.getRound(1);
        uint256 cap = uint256(0.00025 ether) * 25;
        assertEq(r.payloadPaid, cap, "a hit pays at most 25x the round's wager");
        assertEq(game.payloadEth(), 0.08 ether + 0.000005 ether - cap, "the rest stays for later hits");
    }

    function test_payload_no_hit_on_empty_square() public {
        _bigWinnerRound(0, 11, false);
        _open(1);
        _deployOn(alice, 0, 0.01 ether);
        _resolveWith(1, 5, true); // forced "hit" value but nobody backed the winning square
        assertEq(game.getRound(1).status, 3);
        assertEq(game.payloadEth(), 0.08 ether + 0.0002 ether);
    }

    function test_sweep_payload_after_dormancy_goes_to_holders_bucket() public {
        _bigWinnerRound(0, 11, false);
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.sweepPayload();
        vm.warp(block.timestamp + 90 days);
        game.sweepPayload();
        assertEq(game.payloadEth(), 0);
        assertEq(game.holdersEthPending(), 0.08 ether);
        game.feedHolders();
        assertEq(game.getEpoch(game.openEpoch()).ethHolders, 0.08 ether);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.sweepPayload();
    }

    // ------------------------------------------------------------ escape paths
    function test_refund_path_and_ordering_unblocks() public {
        _open(0);
        _deployAll(alice, 0.01 ether);
        _deployOn(bob, 2, 0.01 ether);
        _open(1);
        _deployAll(carol, 0.01 ether);
        vm.warp(game.beaconUnlock(0) + 24 hours);
        vm.expectRevert(TenBlocks.PrevPending.selector);
        game.resolve(1, [_rvFor(1, 3, false), uint256(0)]);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.refund(0);
        assertEq(alice.balance - a0, 0.25 ether);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.Settled.selector);
        game.refund(0);
        vm.prank(bob);
        game.refund(0);
        vm.prank(carol);
        vm.expectRevert(TenBlocks.NoStake.selector);
        game.refund(0);
        game.resolve(1, [_rvFor(1, 3, false), uint256(0)]);
        assertEq(game.getRound(1).status, 2);
        assertEq(address(game).balance, 0.25 ether - TIP);
    }

    function test_refundTo_for_a_wallet_that_cannot_receive_eth() public {
        // regression for review A-3 / B-5
        Rejecter rej = new Rejecter();
        _open(0);
        vm.deal(address(rej), 1 ether);
        rej.deploySquare{value: 0.01 ether}(game, 3, 0.01 ether);
        vm.warp(game.beaconUnlock(0) + 24 hours);
        vm.expectRevert(TenBlocks.SendFailed.selector);
        rej.refund(game, 0);
        uint256 c0 = carol.balance;
        rej.refundTo(game, payable(carol), 0);
        assertEq(carol.balance - c0, 0.01 ether);
    }

    function test_refund_not_before_timeout_and_skip() public {
        _open(0);
        _deployAll(alice, 0.01 ether);
        vm.warp(game.beaconUnlock(0) + 24 hours - 1);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.NotRefundable.selector);
        game.refund(0);
        vm.expectRevert(TenBlocks.NotRefundable.selector);
        game.skipRefundable(0);
        vm.warp(block.timestamp + 1);
        game.skipRefundable(0);
        assertEq(game.getRound(0).status, 4);
        vm.expectRevert(TenBlocks.NotRefundable.selector);
        game.skipRefundable(0);
    }

    function test_carry_release_and_refundEmpty() public {
        _open(0);
        _deployOn(alice, 3, 0.1 ether);
        _deployOn(bob, 4, 0.1 ether);
        _resolveWith(0, 5, false); // empty
        assertEq(game.carryEth(), 0.18 ether);
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.releaseCarry();
        vm.warp(block.timestamp + 3 days);
        game.releaseCarry();
        assertEq(game.carryEth(), 0);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.releaseCarry();
        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        vm.prank(alice);
        game.refundEmpty(0);
        vm.prank(bob);
        game.refundEmpty(0);
        assertEq((alice.balance - a0) + (bob.balance - b0), 0.19 ether, "90% + 5% of 0.2 ETH");
        vm.prank(alice);
        vm.expectRevert(TenBlocks.Settled.selector);
        game.refundEmpty(0);
    }

    function test_refundEmptyTo_alternate_recipient() public {
        Rejecter rej = new Rejecter();
        _open(0);
        vm.deal(address(rej), 1 ether);
        rej.deploySquare{value: 0.1 ether}(game, 3, 0.1 ether);
        _resolveWith(0, 5, false);
        vm.warp(block.timestamp + 3 days);
        game.releaseCarry();
        vm.expectRevert(TenBlocks.SendFailed.selector);
        vm.prank(address(rej));
        game.refundEmpty(0);
        uint256 c0 = carol.balance;
        vm.prank(address(rej));
        game.refundEmptyTo(payable(carol), 0);
        assertEq(carol.balance - c0, 0.095 ether);
    }

    function test_refundEmpty_requires_release() public {
        _open(0);
        _deployOn(alice, 3, 0.1 ether);
        _resolveWith(0, 5, false);
        vm.prank(alice);
        vm.expectRevert(TenBlocks.CarryNotReleased.selector);
        game.refundEmpty(0);
    }

    function test_releaseCarry_blocked_by_pending_round() public {
        _open(0);
        _deployOn(alice, 3, 0.1 ether);
        _resolveWith(0, 5, false);
        vm.warp(game.roundStart(1) + 3 days);
        uint256 r = game.currentRound();
        vm.warp(game.roundStart(r) + 1);
        _deployOn(bob, 1, 0.1 ether);
        vm.warp(block.timestamp + 5);
        vm.expectRevert(TenBlocks.PrevPending.selector);
        game.releaseCarry();
    }

    function test_release_epoch_pays_face_value_in_eth() public {
        router.setFail(true);
        _bigWinnerRound(0, 11, false);
        vm.expectRevert(bytes("router down"));
        game.convert();
        vm.expectRevert(TenBlocks.TooEarly.selector);
        game.releaseEpoch(0);
        vm.warp(block.timestamp + 3 days);
        game.releaseEpoch(0);
        assertEq(uint256(game.getEpoch(0).state), 3);
        assertEq(game.holdersEthPending(), 0.04 ether, "the holders' ETH waits to re-enter the queue");
        game.feedHolders();
        assertEq(game.getEpoch(game.openEpoch()).ethHolders, 0.04 ether, "and enters the open epoch");
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(0), false);
        // alice has 37.5% of the winning square: (3.6 + 0.2) ETH * 0.375
        assertEq(alice.balance - a0, 1.425 ether);
        vm.expectRevert(TenBlocks.NothingToDo.selector);
        game.releaseEpoch(0);
    }

    // ------------------------------------------------------------ attackers
    function test_reentrant_claim_is_blocked() public {
        Reenterer atk = new Reenterer(game);
        vm.deal(address(atk), 10 ether);
        _open(0);
        atk.deployAll{value: 1 ether}(0.04 ether);
        _deployOn(bob, 0, 0.01 ether);
        _resolveWith(0, 8, false);
        uint256 before = address(atk).balance;
        atk.go(0);
        assertTrue(atk.blocked(), "the re-entrant call was attempted and blocked");
        assertFalse(atk.reentered());
        assertEq(address(atk).balance - before, 0.909 ether); // 90% of the 1.01 ETH wagered
        vm.expectRevert(TenBlocks.NothingToClaim.selector);
        atk.go(0);
    }

    function test_rejecting_recipient_uses_claimTo() public {
        Rejecter rej = new Rejecter();
        _open(0);
        vm.deal(address(rej), 1 ether);
        rej.deploySquare{value: 0.001 ether}(game, 5, 0.001 ether);
        _resolveWith(0, 5, false);
        vm.expectRevert(TenBlocks.SendFailed.selector);
        rej.claim(game, 0);
        uint256 c0 = carol.balance;
        rej.claimTo(game, payable(carol), 0);
        assertEq(carol.balance - c0, 0.0009 ether);
    }

    // ------------------------------------------------------------ fuzz
    function testFuzz_slice_conserves(uint8 n, uint96 total, uint96 seed) public pure {
        n = uint8(bound(n, 1, 12));
        total = uint96(bound(total, 1, type(uint96).max / 2));
        uint256[] memory st = new uint256[](n);
        uint256 w;
        for (uint256 i = 0; i < n; i++) {
            st[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1e27);
            w += st[i];
        }
        uint256 paid;
        uint256 claimed;
        for (uint256 i = 0; i < n; i++) {
            uint256 amt = (claimed + st[i] >= w) ? total - paid : (uint256(total) * st[i]) / w;
            assertLe(paid + amt, total);
            paid += amt;
            claimed += st[i];
        }
        assertEq(paid, total, "exactly the whole pot is paid");
    }

    function testFuzz_deploy_accounting(uint8 n, uint96 seed) public {
        n = uint8(bound(n, 1, 25));
        _open(0);
        uint8[] memory s = new uint8[](n);
        uint96[] memory a = new uint96[](n);
        uint256 sum;
        for (uint8 i = 0; i < n; i++) {
            s[i] = i;
            a[i] = uint96(bound(uint256(keccak256(abi.encode(seed, i))), 1e13, 1e16));
            sum += a[i];
        }
        vm.assume(sum >= 1e14);
        vm.prank(alice);
        game.deploy{value: sum}(s, a);
        uint96[25] memory t = game.squareTotals(0);
        uint256 total;
        for (uint8 i = 0; i < n; i++) {
            assertEq(t[i], a[i]);
            total += t[i];
        }
        assertEq(total, sum);
        assertEq(game.getRound(0).totalWager, sum);
        assertEq(address(game).balance, sum);
    }

    function testFuzz_split_sums_to_wager(uint96 wager) public {
        wager = uint96(bound(wager, 1e14, 2.5 ether));
        _open(0);
        vm.deal(alice, 100 ether);
        uint8[] memory s = new uint8[](1);
        uint96[] memory a = new uint96[](1);
        s[0] = 0;
        a[0] = wager;
        vm.prank(alice);
        game.deploy{value: wager}(s, a);
        uint256 t0 = address(this).balance;
        _resolveWith(0, 0, false);
        uint256 tip = address(this).balance - t0;
        TenBlocks.Round memory R = game.getRound(0);
        uint256 epochEth = uint256(game.getEpoch(0).ethCred) + game.getEpoch(0).ethHolders;
        assertEq(uint256(R.potEth) + epochEth + game.payloadEth() + game.opsAccrued() + game.buybackAccrued() + tip, wager, "every wei is assigned");
        assertGe(R.potEth, (uint256(wager) * 90) / 100, "winners never get less than 90%");
    }

    // ------------------------------------------------------------ helpers
    function _one8(uint8 s) internal pure returns (uint8[] memory a) {
        a = new uint8[](1);
        a[0] = s;
    }

    function _one96(uint96 v) internal pure returns (uint96[] memory a) {
        a = new uint96[](1);
        a[0] = v;
    }
}
