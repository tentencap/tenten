// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base, MockERC20, MockPool, MockRouter, MockTen} from "./Base.sol";
import {TenBlocks} from "../src/TenBlocks.sol";

/// @dev Real drand evmnet beacons (fetched from api.drand.sh) against the real BLS verification in TenBlocks.
contract TenBlocksBlsTest is Base {
    TenBlocks real;
    uint256 constant R0 = 21_000_000;
    uint64 constant G0 = 1790520997; // makes drandRound(k) = R0 + 30 k with a 12 s buffer

    function setUp() public {
        vm.warp(G0 - 2000);
        weth = new MockERC20("WETH", "WETH");
        usdg = new MockERC20("USDG", "USDG");
        wsnet = new MockERC20("wsNET", "wsNET");
        poolA = new MockPool(address(weth), address(usdg), 500);
        poolB = new MockPool(address(usdg), address(wsnet), 10000);
        router = new MockRouter(wsnet, address(weth));
        ten = new MockTen();
        TenBlocks.Config memory c = _config();
        c.genesisTime = G0;
        real = new TenBlocks(c);
        vm.deal(alice, 100 ether);
    }

    function _sig(uint256 k) internal view returns (uint256[2] memory s) {
        string memory json = vm.readFile("test/fixtures/drand_evmnet.json");
        bytes memory b = vm.parseJsonBytes(json, string.concat(".", vm.toString(R0 + 30 * k)));
        require(b.length == 64, "fixture");
        uint256 a;
        uint256 c;
        assembly {
            a := mload(add(b, 32))
            c := mload(add(b, 64))
        }
        s = [a, c];
    }

    function _dep(uint256 r) internal {
        vm.warp(real.roundStart(r) + 1);
        uint8[] memory sq = new uint8[](1);
        uint96[] memory am = new uint96[](1);
        sq[0] = 3;
        am[0] = 0.001 ether;
        vm.prank(alice);
        real.deploy{value: 0.001 ether}(sq, am);
    }

    function test_drand_round_mapping() public view {
        assertEq(real.drandRound(0), R0);
        assertEq(real.drandRound(1), R0 + 30);
        assertEq(real.drandRound(7), R0 + 210);
    }

    function test_real_beacons_resolve_in_order() public {
        for (uint256 k = 0; k < 6; k++) _dep(k);
        for (uint256 k = 0; k < 6; k++) {
            vm.warp(real.beaconUnlock(k) + 1);
            uint256 g = gasleft();
            real.resolve(k, _sig(k));
            uint256 used = g - gasleft();
            emit log_named_uint("resolve gas (real BLS)", used);
            assertGe(real.getRound(k).status, 2);
            uint256[2] memory s = _sig(k);
            uint256 rv = uint256(sha256(abi.encodePacked(s[0], s[1])));
            uint8 sq = uint8(uint256(keccak256(abi.encodePacked(rv, k, "sq"))) % 25);
            assertEq(real.getRound(k).winningSquare, sq);
        }
    }

    function test_wrong_round_signature_reverts() public {
        _dep(0);
        vm.warp(real.beaconUnlock(0) + 1);
        vm.expectRevert(TenBlocks.BadBeacon.selector);
        real.resolve(0, _sig(1)); // a valid beacon, but for another round
    }

    function test_forged_and_off_curve_signatures_revert() public {
        _dep(0);
        vm.warp(real.beaconUnlock(0) + 1);
        uint256[2] memory s = _sig(0);
        vm.expectRevert(TenBlocks.BadBeacon.selector);
        real.resolve(0, [s[0], s[1] + 1]); // off curve
        vm.expectRevert(TenBlocks.BadBeacon.selector);
        real.resolve(0, [uint256(1), uint256(2)]); // on the curve is (1,2): valid point, wrong signature
        vm.expectRevert(TenBlocks.BadBeacon.selector);
        real.resolve(0, [uint256(0), uint256(0)]);
        real.resolve(0, s); // the real one works
    }
}
