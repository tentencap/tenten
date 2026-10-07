// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {ISwapRouter02} from "../src/interfaces/IExternal.sol";
import {MockTen} from "./Base.sol";

/// @dev Randomness forced; everything else (WETH, USDG, wsNET, v3 pools, SwapRouter02) is the real chain.
contract ForkGame is TenBlocks {
    constructor(Config memory c) TenBlocks(c) {}

    function _beacon(uint256, uint256[2] calldata sig) internal pure override returns (uint256) {
        return sig[0];
    }
}

/// @dev Real BLS verification exposed, to compare with the live SLVR provider.
contract ExposedGame is TenBlocks {
    constructor(Config memory c) TenBlocks(c) {}

    function beaconView(uint256 r, uint256[2] calldata sig) external view returns (uint256) {
        return _beacon(r, sig);
    }
}

interface IProvider {
    function verifyBeacon(uint64 round, uint256[2] calldata sig) external view returns (bool);
}

interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

contract TenBlocksForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WSNET = 0x63C12667638f2Ae6fC6ae09B43D98Ec84a8586eA;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address constant POOL_A = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG 0.01% (the deep one, $24.8M)
    address constant POOL_B = 0x8315627976cab8bd937eB53D44D009e265D0e4DC; // USDG/wsNET 1%
    address constant SLVR_PROVIDER = 0x1F3B0992FaBCF77d4df7Baa416b9185e464d58f3;

    ForkGame game;
    MockTen ten;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _cfg() internal view returns (TenBlocks.Config memory c) {
        c = TenBlocks.Config({
            wsnet: WSNET,
            weth: WETH,
            usdg: USDG,
            router: ROUTER,
            poolEthUsdg: POOL_A,
            feeEthUsdg: 100,
            poolUsdgWsnet: POOL_B,
            feeUsdgWsnet: 10000,
            genesisTime: uint64(block.timestamp + 2000),
            beaconBuffer: 12,
            refundTimeout: 24 hours,
            carryTimeout: 3 days,
            epochMaxEth: 0.2 ether,
            epochMaxAge: 15 minutes,
            minEpochEth: 0.003 ether,
            twapSeconds: 1800,
            conversionTimeout: 3 days,
            dormancy: 90 days,
            paramsDelay: 24 hours,
            owner: address(0x0aa0),
            params: TenBlocks.Params({
                winnerCredBps: 500,
                holdersBps: 100,
                payloadBps: 200,
                buybackBps: 100,
                opsBps: 100,
                payloadOdds: 625,
                payloadCapMult: 25,
                claimFeeBps: 1000,
                maxDeviationBps: 300,
                minPerSquare: 1e13,
                minDeployTotal: 1e14,
                maxPerPlayerRound: 2.5 ether,
                maxPerRound: 10 ether,
                tipCap: 0.00003 ether,
                holdersSink: address(ten),
                buybackWallet: address(0x0bb0),
                opsWallet: address(0x0905),
                deploysOpen: true
            })
        });
    }

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("robinhood");
        ten = new MockTen();
        game = new ForkGame(_cfg());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    // ---- helpers
    function _open(uint256 r) internal {
        vm.warp(game.roundStart(r) + 1);
    }

    function _rvFor(uint256 r, uint8 square, bool wantHit) internal pure returns (uint256 rv) {
        for (uint256 i = 0; i < 200000; i++) {
            rv = uint256(keccak256(abi.encode("seed", i)));
            if (uint256(keccak256(abi.encodePacked(rv, r, "sq"))) % 25 != square) continue;
            bool hit = uint256(keccak256(abi.encodePacked(rv, r, "pl"))) % 625 == 0;
            if (hit == wantHit) return rv;
        }
        revert("no rv");
    }

    function _resolveWith(uint256 r, uint8 square, bool hit) internal {
        vm.warp(game.beaconUnlock(r) + 1);
        game.resolve(r, [_rvFor(r, square, hit), uint256(0)]);
    }

    function _all(address who, uint96 each) internal returns (uint96 total) {
        uint8[] memory s = new uint8[](25);
        uint96[] memory a = new uint96[](25);
        for (uint8 i = 0; i < 25; i++) {
            s[i] = i;
            a[i] = each;
        }
        total = each * 25;
        vm.prank(who);
        game.deploy{value: total}(s, a);
    }

    function _one(uint256 r) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = r;
    }

    function _path() internal pure returns (bytes memory) {
        return abi.encodePacked(WETH, uint24(100), USDG, uint24(10000), WSNET);
    }

    // ------------------------------------------------------------ tests
    function test_constructor_grows_observation_buffer() public view {
        (,,,, uint16 cardinalityNext,,) = IPoolSlot0(POOL_B).slot0();
        assertGe(cardinalityNext, 50);
    }

    function test_full_lifecycle_with_real_swap() public {
        _open(0);
        _all(alice, 0.06 ether); // 1.5 ETH
        _all(bob, 0.1 ether); // 2.5 ETH, together 4 ETH
        _resolveWith(0, 11, false);
        assertEq(uint256(game.getEpoch(0).state), 1, "epoch closed by size");

        uint256 expected = game.twapExpectedOut(0.28 ether);
        emit log_named_uint("TWAP-implied wsNET for 0.28 ETH (net of pool fees)", expected);
        uint256 g = gasleft();
        game.convert();
        emit log_named_uint("convert gas (real pools)", g - gasleft());
        TenBlocks.Epoch memory e = game.getEpoch(0);
        uint256 out = (uint256(e.rate) * 0.28 ether) / 1e18;
        emit log_named_uint("wsNET received for 0.28 ETH", out);
        emit log_named_uint("cost vs TWAP net of pool fees, bps", expected > out ? ((expected - out) * 10_000) / expected : 0);
        assertGe(out, (expected * 95) / 100, "inside the 5% tolerance");
        assertLe(out, (expected * 102) / 100, "not above the TWAP by much");
        assertGt(ten.total(), 0, "holders' share donated");
        assertGt(game.payloadEth(), 0);

        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(0), true);
        vm.prank(bob);
        game.claim(_one(0), true);
        assertEq(alice.balance - a0, 1.35 ether); // 37.5% of the 3.6 ETH pot
        uint256 ws = IERC20(WSNET).balanceOf(alice) + IERC20(WSNET).balanceOf(bob);
        uint256 pool = (uint256(game.getRound(0).credEth) * e.rate) / 1e18;
        assertApproxEqAbs(ws, pool, 3, "all wsNET of the pool reached the players");
        assertLe(game.reservedWs(), 3);
    }

    function test_manipulated_pool_reverts_then_twap_catches_up() public {
        _open(0);
        _all(alice, 0.06 ether);
        _all(bob, 0.1 ether);
        _resolveWith(0, 11, false);
        // an attacker pushes the thin wsNET price up with a large ETH buy right before conversion
        address atk = makeAddr("attacker");
        vm.deal(atk, 100 ether);
        vm.prank(atk);
        ISwapRouter02(ROUTER).exactInput{value: 20 ether}(
            ISwapRouter02.ExactInputParams({path: _path(), recipient: atk, amountIn: 20 ether, amountOutMinimum: 0})
        );
        vm.expectRevert(); // the router refuses: output is below the TWAP-based minimum
        game.convert();
        assertEq(uint256(game.getEpoch(0).state), 1, "epoch still waiting");
        // the price must be held for the whole TWAP window; once it has been, the epoch converts at market
        vm.warp(block.timestamp + 31 minutes);
        game.convert();
        assertEq(uint256(game.getEpoch(0).state), 2);
    }

    function test_twap_quote_close_to_quoter() public {
        vm.warp(block.timestamp + 31 minutes); // the thin pool's oldest observation must be older than the window
        uint256 amount = 0.25 ether;
        uint256 twap = game.twapExpectedOut(amount);
        (uint256 q,,,) = IQuoterV2(QUOTER).quoteExactInput(_path(), amount);
        emit log_named_uint("TWAP-implied", twap);
        emit log_named_uint("QuoterV2 (spot, after fees)", q);
        // the quote pays 1.05% fees and some impact; the pool can move, so allow a wide band
        assertGt(twap, (q * 70) / 100);
        assertLt(twap, (q * 140) / 100);
    }

    function test_bots_cover_all_squares_many_rounds_then_claim_all() public {
        address[5] memory bots;
        for (uint256 i = 0; i < 5; i++) {
            bots[i] = makeAddr(string.concat("bot", vm.toString(i)));
            vm.deal(bots[i], 100 ether);
        }
        uint256 totalIn;
        for (uint256 r = 0; r < 12; r++) {
            _open(r);
            for (uint256 i = 0; i < 5; i++) totalIn += _all(bots[i], uint96(0.0004 ether * (i + 1)));
            _resolveWith(r, uint8((r * 7) % 25), false);
        }
        // epochs close by age; convert everything that is closed
        vm.warp(block.timestamp + 2 hours);
        for (uint256 i = 0; i < 3; i++) {
            try game.convert() {} catch {}
        }
        uint256 paid;
        for (uint256 r = 0; r < 12; r++) {
            for (uint256 i = 0; i < 5; i++) {
                uint256 b0 = bots[i].balance;
                vm.prank(bots[i]);
                game.claim(_one(r), false);
                paid += bots[i].balance - b0;
            }
        }
        // bots covered every square: all rounds paid their whole 90% pot
        assertEq(paid, (totalIn * 90) / 100);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bots[i]);
            try game.withdraw() {} catch {}
        }
        assertLe(game.totalAttributed(), game.totalRefined());
    }

    function test_many_players_one_round_exact_shares() public {
        _open(0);
        uint256 n = 40;
        address[] memory ps = new address[](n);
        uint256 winSquare = 6;
        uint256 stakeSum;
        for (uint256 i = 0; i < n; i++) {
            ps[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.deal(ps[i], 10 ether);
            uint96 amt = uint96(1e14 + i * 3e13);
            uint8[] memory s = new uint8[](2);
            uint96[] memory a = new uint96[](2);
            s[0] = uint8(winSquare);
            s[1] = uint8((i + 10) % 25 == winSquare ? 20 : (i + 10) % 25);
            a[0] = amt;
            a[1] = amt;
            vm.prank(ps[i]);
            game.deploy{value: 2 * uint256(amt)}(s, a);
            stakeSum += amt;
        }
        _resolveWith(0, uint8(winSquare), false);
        TenBlocks.Round memory R = game.getRound(0);
        assertEq(R.winnerTotal, stakeSum);
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            uint256 b0 = ps[i].balance;
            vm.prank(ps[i]);
            game.claim(_one(0), false);
            paid += ps[i].balance - b0;
        }
        assertEq(paid, R.potEth, "the whole pot is paid, to the wei");
    }

    function test_payload_hit_pays_eth_to_the_winner() public {
        _open(0);
        _all(alice, 0.04 ether); // 1 ETH
        _all(bob, 0.08 ether); // 2 ETH
        _resolveWith(0, 11, false);
        uint256 pb = game.payloadEth(); // 2% of 3 ETH = 0.06
        assertEq(pb, 0.06 ether);
        _open(1);
        _all(alice, 0.04 ether); // 1 ETH: alice alone, so she is the sole winner
        _resolveWith(1, 2, true);
        // this round adds 0.02 ETH, then the whole 0.08 ETH is paid (cap 30 x 1 ETH)
        assertEq(game.getRound(1).payloadPaid, pb + 0.02 ether);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(_one(1), false);
        assertEq(alice.balance - a0, 0.9 ether + 0.08 ether, "90% of her round plus the whole Payload");
    }

    function test_empty_square_on_fork() public {
        _open(0);
        uint8[] memory s = new uint8[](1);
        uint96[] memory a = new uint96[](1);
        s[0] = 1;
        a[0] = 0.01 ether;
        vm.prank(alice);
        game.deploy{value: 0.01 ether}(s, a);
        _resolveWith(0, 9, false);
        assertEq(game.getRound(0).status, 3);
        assertEq(game.carryEth(), 0.009 ether);
    }

    function test_bls_matches_the_live_provider() public {
        // real drand beacons verify in our library exactly as in SLVR's deployed provider
        uint256 R0 = 21_000_000;
        string memory json = vm.readFile("test/fixtures/drand_evmnet.json");
        bytes memory b = vm.parseJsonBytes(json, string.concat(".", vm.toString(R0)));
        uint256 w0;
        uint256 w1;
        assembly {
            w0 := mload(add(b, 32))
            w1 := mload(add(b, 64))
        }
        assertTrue(IProvider(SLVR_PROVIDER).verifyBeacon(uint64(R0), [w0, w1]), "live provider accepts it");
        assertFalse(IProvider(SLVR_PROVIDER).verifyBeacon(uint64(R0 + 1), [w0, w1]));

        uint64 g0 = 1790520997;
        vm.warp(g0 - 2000);
        TenBlocks.Config memory c = _cfg();
        c.genesisTime = g0;
        ExposedGame ex = new ExposedGame(c);
        assertEq(ex.drandRound(0), R0);
        assertEq(ex.beaconView(0, [w0, w1]), uint256(sha256(abi.encodePacked(w0, w1))));
        vm.expectRevert(TenBlocks.BadBeacon.selector);
        ex.beaconView(1, [w0, w1]);
    }
}

interface IPoolSlot0 {
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
