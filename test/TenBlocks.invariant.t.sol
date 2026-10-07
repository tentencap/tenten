// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base, TenBlocksHarness, MockRouter, MockTen} from "./Base.sol";
import {Test} from "forge-std/Test.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

contract Handler is Test {
    TenBlocksHarness public game;
    MockRouter public router;
    MockTen public ten;
    address[4] public actors;
    uint256[] public deposited; // rounds with deposits, in order
    uint256 public nextIdx;
    mapping(uint256 => uint256) public refundedEth; // ETH paid back from unresolved rounds, per round
    uint256 public ops;
    uint256 public deployedTotal;

    receive() external payable {} // the handler resolves, so it receives resolver tips

    constructor(TenBlocksHarness g, MockRouter r, MockTen t, address a, address b, address c, address d) {
        game = g;
        router = r;
        ten = t;
        actors = [a, b, c, d];
    }

    function _one(uint256 r) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = r;
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % 4];
    }

    function roundsList() external view returns (uint256[] memory) {
        return deposited;
    }

    function _toOpenWindow() internal {
        uint256 g = game.GENESIS_TIME();
        if (block.timestamp < g) vm.warp(g);
        uint256 t = (block.timestamp - g) % 90;
        if (t >= 60) vm.warp(block.timestamp + (90 - t));
    }

    function deployRandom(uint256 who, uint8 nRaw, uint256 seed, uint256 amtSeed) external {
        ops++;
        address p = _actor(who);
        uint256 n = bound(nRaw, 1, 25);
        uint256 each = bound(amtSeed, 1e14 / n + 1, 3e16);
        _toOpenWindow();
        uint8[] memory s = new uint8[](n);
        uint96[] memory a = new uint96[](n);
        uint256 start = seed % 25;
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            s[i] = uint8((start + i) % 25);
            a[i] = uint96(each + (i % 3) * 1e12); // a few distinct amounts
            sum += a[i];
        }
        vm.prank(p);
        try game.deploy{value: sum}(s, a) {
            deployedTotal += sum;
            (bool ex, uint256 r) = game.lastDepositedRound();
            if (ex && (deposited.length == 0 || deposited[deposited.length - 1] != r)) deposited.push(r);
        } catch {}
    }

    function advance(uint256 secs) external {
        ops++;
        vm.warp(block.timestamp + bound(secs, 0, 600));
    }

    function bigAdvance(uint256 secs) external {
        ops++;
        vm.warp(block.timestamp + bound(secs, 0, 5 days));
    }

    function resolveNext(uint256 seed) external {
        ops++;
        if (nextIdx >= deposited.length) return;
        uint256 r = deposited[nextIdx];
        uint8 st = game.getRound(r).status;
        if (st >= 2) {
            nextIdx++;
            return;
        }
        if (block.timestamp < game.beaconUnlock(r)) vm.warp(game.beaconUnlock(r) + 1);
        uint256 rv = uint256(keccak256(abi.encode(seed, r)));
        try game.resolve(r, [rv, uint256(0)]) {
            nextIdx++;
        } catch {}
    }

    function forceWinner(uint256 seed, uint8 square) external {
        ops++;
        if (nextIdx >= deposited.length) return;
        uint256 r = deposited[nextIdx];
        if (game.getRound(r).status != 1) return;
        if (block.timestamp < game.beaconUnlock(r)) vm.warp(game.beaconUnlock(r) + 1);
        uint256 sq = bound(square, 0, 24);
        for (uint256 i = 0; i < 300; i++) {
            uint256 rv = uint256(keccak256(abi.encode(seed, i)));
            if (uint256(keccak256(abi.encodePacked(rv, r, "sq"))) % 25 == sq) {
                try game.resolve(r, [rv, uint256(0)]) {
                    nextIdx++;
                } catch {}
                return;
            }
        }
    }

    function claim(uint256 who, uint256 idx, bool takeWs) external {
        ops++;
        if (deposited.length == 0) return;
        address p = _actor(who);
        uint256 r = deposited[idx % deposited.length];
        vm.prank(p);
        try game.claim(_one(r), takeWs) {} catch {}
    }

    function claimTo(uint256 who, uint256 idx) external {
        ops++;
        if (deposited.length == 0) return;
        address p = _actor(who);
        uint256 r = deposited[idx % deposited.length];
        vm.prank(p);
        try game.claimTo(payable(_actor(who + 1)), _one(r), true) {} catch {}
    }

    function withdraw(uint256 who) external {
        ops++;
        vm.prank(_actor(who));
        try game.withdraw() {} catch {}
    }

    function checkpoint(uint256 who) external {
        ops++;
        game.checkpoint(_actor(who));
    }

    function convert() external {
        ops++;
        try game.convert() {} catch {}
    }

    function convertLater() external {
        ops++;
        vm.warp(block.timestamp + 1 hours + 1);
        try game.convert() {} catch {}
    }

    function releaseEpoch(uint256 e) external {
        ops++;
        uint256 n = game.epochCount();
        try game.releaseEpoch(uint32(e % n)) {} catch {}
    }

    function releaseCarry() external {
        ops++;
        try game.releaseCarry() {} catch {}
    }

    function refundEmpty(uint256 who, uint256 idx) external {
        ops++;
        if (deposited.length == 0) return;
        vm.prank(_actor(who));
        try game.refundEmpty(deposited[idx % deposited.length]) {} catch {}
    }

    function refundUnresolved(uint256 who, uint256 idx) external {
        ops++;
        if (deposited.length == 0) return;
        uint256 r = deposited[idx % deposited.length];
        address p = _actor(who);
        if (game.getRound(r).status == 1) {
            uint256 ready = game.beaconUnlock(r) + game.REFUND_TIMEOUT();
            if (block.timestamp < ready) vm.warp(ready);
        }
        uint256 before = p.balance;
        vm.prank(p);
        try game.refund(r) {
            refundedEth[r] += p.balance - before;
        } catch {}
    }

    function flushHolders() external {
        ops++;
        try game.flushHolders() {} catch {}
    }

    function sweepPayload() external {
        ops++;
        try game.sweepPayload() {} catch {}
    }

    function feedHolders() external {
        ops++;
        try game.feedHolders() {} catch {}
    }

    function sweepBuyback() external {
        ops++;
        try game.sweepBuyback() {} catch {}
    }

    function sweepOps() external {
        ops++;
        try game.sweepOps() {} catch {}
    }

    function closeEpoch() external {
        ops++;
        try game.closeEpoch() {} catch {}
    }

    function convertEpoch(uint256 e) external {
        ops++;
        uint256 n = game.epochCount();
        try game.convertEpoch(uint32(e % n)) {} catch {}
    }

    function setRouterFail(bool f) external {
        ops++;
        router.setFail(f);
    }

    function setTenFail(bool f) external {
        ops++;
        ten.setFail(f);
    }
}

contract TenBlocksInvariantTest is Base {
    Handler h;
    address dave;

    function setUp() public {
        setUpGame();
        dave = makeAddr("dave");
        h = new Handler(game, router, ten, alice, bob, carol, dave);
        vm.deal(dave, 1000 ether);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](24);
        sel[0] = Handler.deployRandom.selector;
        sel[1] = Handler.advance.selector;
        sel[2] = Handler.bigAdvance.selector;
        sel[3] = Handler.resolveNext.selector;
        sel[4] = Handler.forceWinner.selector;
        sel[5] = Handler.claim.selector;
        sel[6] = Handler.claimTo.selector;
        sel[7] = Handler.withdraw.selector;
        sel[8] = Handler.checkpoint.selector;
        sel[9] = Handler.convert.selector;
        sel[10] = Handler.convertLater.selector;
        sel[11] = Handler.releaseEpoch.selector;
        sel[12] = Handler.releaseCarry.selector;
        sel[13] = Handler.refundEmpty.selector;
        sel[14] = Handler.refundUnresolved.selector;
        sel[15] = Handler.flushHolders.selector;
        sel[16] = Handler.sweepPayload.selector;
        sel[17] = Handler.setRouterFail.selector;
        sel[18] = Handler.setTenFail.selector;
        sel[19] = Handler.sweepOps.selector;
        sel[20] = Handler.closeEpoch.selector;
        sel[21] = Handler.convertEpoch.selector;
        sel[22] = Handler.sweepBuyback.selector;
        sel[23] = Handler.feedHolders.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sel}));
    }

    // ETH: the contract balance equals exactly what it owes (stakes of unresolved rounds, carry,
    // unpaid winners' pots, epoch ETH waiting for conversion, unpaid refunds).
    function _ethLiabilities() internal view returns (uint256 liab) {
        liab = uint256(game.carryEth()) + game.carryCredit() + game.payloadEth() + game.opsAccrued() + game.buybackAccrued() + game.holdersEthPending();
        uint256[] memory rs = h.roundsList();
        for (uint256 i = 0; i < rs.length; i++) {
            TenBlocks.Round memory R = game.getRound(rs[i]);
            if (R.status == 1) {
                liab += R.totalWager;
            } else if (R.status == 4) {
                liab += R.totalWager - h.refundedEth(rs[i]);
            } else if (R.status == 2) {
                liab += R.potEth - R.paidEth;
                if (game.getEpoch(R.epoch).state == 3) liab += R.credEth - R.paidPool;
            } else if (R.status == 3) {
                if (game.chainReleased(R.chainId)) liab += uint256(R.potEth) + R.credEth - R.paidEth;
            }
        }
        uint256 n = game.epochCount();
        for (uint32 e = 0; e < n; e++) {
            TenBlocks.Epoch memory E = game.getEpoch(e);
            if (E.state == 0 || E.state == 1) liab += uint256(E.ethCred) + E.ethHolders;
        }
    }

    function invariant_eth_balance_equals_liabilities() public view {
        assertEq(address(game).balance, _ethLiabilities());
    }

    function invariant_wsnet_solvency_and_dust() public view {
        uint256 owed = game.totalUnclaimed() + game.totalRefined() + game.holdersOwed();
        uint256 bal = wsnet.balanceOf(address(game));
        assertGe(bal, owed, "wsNET balance covers everything owed");
        assertLe(bal - owed, 20 * (h.ops() + 1), "only rounding dust above it");
    }

    function invariant_index_accounting() public view {
        assertLe(game.totalAttributed(), game.totalRefined());
        uint256 sum;
        address[4] memory a = [alice, bob, carol, dave];
        for (uint256 i = 0; i < 4; i++) {
            (uint256 bal,,) = game.minerState(a[i]);
            sum += bal;
        }
        assertEq(game.totalUnclaimed(), game.reservedWs() + sum, "totalUnclaimed = reserved + balances");
    }

    function invariant_round_payments_bounded() public view {
        uint256[] memory rs = h.roundsList();
        for (uint256 i = 0; i < rs.length; i++) {
            TenBlocks.Round memory R = game.getRound(rs[i]);
            if (R.status == 2) {
                assertLe(R.paidEth, R.potEth);
                assertLe(R.claimedStakeImm, R.winnerTotal);
                assertLe(R.claimedStakePool, R.winnerTotal);
                if (R.claimedStakeImm == R.winnerTotal) assertEq(R.paidEth, R.potEth, "no ETH dust once all claimed");
            }
        }
    }

    function invariant_resolution_order() public view {
        uint256[] memory rs = h.roundsList();
        for (uint256 i = 1; i < rs.length; i++) {
            TenBlocks.Round memory R = game.getRound(rs[i]);
            if (R.status == 2 || R.status == 3) {
                assertGe(game.getRound(rs[i - 1]).status, 2, "a round resolves only after its predecessor");
            }
        }
    }

    function afterInvariant() public {
        uint256[] memory rs = h.roundsList();
        uint256[5] memory c;
        for (uint256 i = 0; i < rs.length; i++) c[game.getRound(rs[i]).status]++;
        uint256 conv;
        uint256 rel;
        for (uint32 e = 0; e < game.epochCount(); e++) {
            uint8 st = game.getEpoch(e).state;
            if (st == 2) conv++;
            if (st == 3) rel++;
        }
        emit log_named_uint("rounds open", c[1]);
        emit log_named_uint("rounds winner", c[2]);
        emit log_named_uint("rounds empty", c[3]);
        emit log_named_uint("rounds skipped", c[4]);
        emit log_named_uint("epochs converted", conv);
        emit log_named_uint("epochs released", rel);
        emit log_named_uint("wsNET refined events totalUnclaimed", game.totalUnclaimed());
        emit log_named_uint("totalRefined", game.totalRefined());
    }
}
