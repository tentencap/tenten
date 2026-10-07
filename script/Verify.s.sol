// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {HolderPot} from "../src/HolderPot.sol";

/// @notice Read-only post-deploy check: reads every immutable and setting and fails if the wiring is wrong.
/// @dev Environment: GAME, POT, OWNER, KEEPER, BUYBACK_WALLET, OPS_WALLET. Run:
///      forge script script/Verify.s.sol --rpc-url robinhood
///      Sends nothing. A failed check reverts with the name of the check.
contract Verify is Script {
    function run() external {
        TenBlocks g = TenBlocks(vm.envAddress("GAME"));
        HolderPot pot = HolderPot(vm.envAddress("POT"));
        address owner = vm.envAddress("OWNER");
        address keeper = vm.envAddress("KEEPER");

        require(block.chainid == 4663, "chain");
        require(address(g).code.length > 0 && address(pot).code.length > 0, "contracts have code");
        require(g.owner() == owner, "game owner");
        require(g.pendingOwner() == address(0), "no pending owner");
        require(pot.owner() == owner, "pot owner");
        require(pot.operator() == keeper, "pot operator");
        require(address(pot.WSNET()) == g.WSNET(), "pot token is the game's wsNET");

        TenBlocks.Params memory p = g.currentParams();
        require(p.holdersSink == address(pot), "holders sink is the pot");
        require(p.buybackWallet == vm.envAddress("BUYBACK_WALLET"), "buyback wallet");
        require(p.opsWallet == vm.envAddress("OPS_WALLET"), "ops wallet");
        require(p.deploysOpen, "deploys open");
        (, uint64 pendingAt) = g.pendingParams();
        require(pendingAt == 0, "no pending settings");
        require(g.paramsCount() == 1, "only the initial settings exist");

        uint256 nonEth = uint256(p.winnerCredBps) + p.holdersBps + p.payloadBps + p.buybackBps + p.opsBps;
        require(nonEth <= g.MAX_NON_ETH_BPS(), "split inside the bound");
        require(uint256(p.payloadCapMult) * 10_000 <= uint256(p.payloadOdds) * (uint256(p.holdersBps) + p.buybackBps + p.payloadBps), "payload ratio rule");
        require(p.claimFeeBps <= g.CLAIM_FEE_MAX(), "claim fee within its ceiling");

        require(g.GENESIS_TIME() >= block.timestamp || block.timestamp < g.GENESIS_TIME() + 1 days, "genesis plausible");
        require(g.TWAP_SECONDS() >= 1800 || g.REFUND_TIMEOUT() < 24 hours, "rehearsal values are only for the rehearsal");

        console2.log("OK game", address(g));
        console2.log("OK pot ", address(pot));
        console2.log("genesis", uint256(g.GENESIS_TIME()));
        console2.log("maxPerPlayerRound", uint256(p.maxPerPlayerRound));
        console2.log("maxPerRound", uint256(p.maxPerRound));
        console2.log("refundTimeout", uint256(g.REFUND_TIMEOUT()));
        console2.log("conversionTimeout", uint256(g.CONVERSION_TIMEOUT()));
    }
}
