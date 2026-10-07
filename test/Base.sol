// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {ISwapRouter02} from "../src/interfaces/IExternal.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPool {
    address public token0;
    address public token1;
    int24 public tick;
    uint24 public fee;
    bool public revertObserve;
    uint16 public cardinalityNext;

    constructor(address a, address b, uint24 f) {
        token0 = a;
        token1 = b;
        fee = f;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setRevertObserve(bool v) external {
        revertObserve = v;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory tc, uint160[] memory sp) {
        require(!revertObserve, "OLD");
        tc = new int56[](2);
        sp = new uint160[](2);
        tc[0] = 0;
        tc[1] = int56(tick) * int56(uint56(ago[0]));
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        cardinalityNext = n;
    }
}

contract MockRouter {
    MockERC20 public wsnet;
    address public WETH9;
    uint256 public rate = 0.99e18; // wsNET per ETH
    bool public fail;

    constructor(MockERC20 w, address weth_) {
        wsnet = w;
        WETH9 = weth_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setFail(bool f) external {
        fail = f;
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata p) external payable returns (uint256 out) {
        require(!fail, "router down");
        require(msg.value == p.amountIn, "value");
        out = (msg.value * rate) / 1e18;
        require(out >= p.amountOutMinimum, "slippage");
        wsnet.mint(p.recipient, out);
    }
}

contract MockTen {
    bool public failDonate;
    bool public pullHalf;
    uint256 public total;

    function setFail(bool f) external {
        failDonate = f;
    }

    function setPullHalf(bool f) external {
        pullHalf = f;
    }

    function donateReward(address asset, uint256 amount) external {
        require(!failDonate, "ten down");
        uint256 take = pullHalf ? amount / 2 : amount;
        IERC20(asset).transferFrom(msg.sender, address(this), take);
        total += take;
    }
}

/// @dev Test harness: the randomness is the first signature word, so tests can force any outcome.
contract TenBlocksHarness is TenBlocks {
    constructor(Config memory c) TenBlocks(c) {}

    function _beacon(uint256, uint256[2] calldata sig) internal pure override returns (uint256) {
        return sig[0];
    }

    function slice(uint256 total, uint256 paid, uint256 stake, uint256 claimedBefore, uint256 winnerTotal)
        external
        pure
        returns (uint256)
    {
        return _slice(total, paid, stake, claimedBefore, winnerTotal);
    }
}

abstract contract Base is Test {
    MockERC20 weth;
    MockERC20 usdg;
    MockERC20 wsnet;
    MockPool poolA;
    MockPool poolB;
    MockRouter router;
    MockTen ten;
    TenBlocksHarness game;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address ops = makeAddr("ops");
    uint256 constant TIP = 0.00003 ether; // resolver tip cap

    receive() external payable {} // the test contract is the default resolver and collects tips

    address buyback = makeAddr("buyback");
    address owner = makeAddr("owner");

    function _params() internal view returns (TenBlocks.Params memory p) {
        p = TenBlocks.Params({
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
            buybackWallet: buyback,
            opsWallet: ops,
            deploysOpen: true
        });
    }

    function _config() internal view returns (TenBlocks.Config memory c) {
        c = TenBlocks.Config({
            wsnet: address(wsnet),
            weth: address(weth),
            usdg: address(usdg),
            router: address(router),
            poolEthUsdg: address(poolA),
            feeEthUsdg: 500,
            poolUsdgWsnet: address(poolB),
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
            owner: owner,
            params: _params()
        });
    }

    function setUpGame() internal {
        weth = new MockERC20("WETH", "WETH");
        usdg = new MockERC20("USDG", "USDG");
        wsnet = new MockERC20("wsNET", "wsNET");
        // token order: pool A is WETH/USDG, pool B is USDG/wsNET (order as on the real pools)
        poolA = new MockPool(address(weth), address(usdg), 500);
        poolB = new MockPool(address(usdg), address(wsnet), 10000);
        router = new MockRouter(wsnet, address(weth));
        ten = new MockTen();
        game = new TenBlocksHarness(_config());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    // ---- time helpers
    function _open(uint256 r) internal {
        vm.warp(game.roundStart(r) + 1);
    }

    function _resolvable(uint256 r) internal {
        vm.warp(game.beaconUnlock(r) + 1);
    }

    // ---- deploy helpers
    function _squares(uint8 n) internal pure returns (uint8[] memory s) {
        s = new uint8[](n);
        for (uint8 i = 0; i < n; i++) s[i] = i;
    }

    function _amounts(uint8 n, uint96 each) internal pure returns (uint96[] memory a) {
        a = new uint96[](n);
        for (uint8 i = 0; i < n; i++) a[i] = each;
    }

    function _deployAll(address who, uint96 each) internal returns (uint96 total) {
        total = each * 25;
        vm.prank(who);
        game.deploy{value: total}(_squares(25), _amounts(25, each));
    }

    function _deployOn(address who, uint8 square, uint96 amount) internal {
        uint8[] memory s = new uint8[](1);
        s[0] = square;
        uint96[] memory a = new uint96[](1);
        a[0] = amount;
        vm.prank(who);
        game.deploy{value: amount}(s, a);
    }

    // ---- randomness search: a value whose square (and Payload hit) match the wish for round r
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
        _resolvable(r);
        game.resolve(r, [_rvFor(r, square, hit), uint256(0)]);
    }

    function _one(uint256 r) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = r;
    }
}
