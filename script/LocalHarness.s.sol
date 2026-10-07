// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {HolderPot} from "../src/HolderPot.sol";
import {Deploy} from "./Deploy.s.sol";

/// @dev LOCAL TESTING ONLY (anvil fork). Accepts any value as the random number so that the keeper can be
///      exercised end to end without waiting for real drand rounds. Never deploy this on a real network.
contract LocalHarnessGame is TenBlocks {
    constructor(Config memory c) TenBlocks(c) {}

    function _beacon(uint256, uint256[2] calldata sig) internal pure override returns (uint256) {
        return sig[0];
    }
}

contract LocalHarness is Deploy {
    function runLocal() external {
        address owner = vm.envAddress("OWNER");
        address keeper = vm.envAddress("KEEPER");
        TenBlocks.Config memory c = _config(false, 2000);
        c.owner = owner;
        vm.startBroadcast();
        HolderPot pot = new HolderPot(WSNET, owner, keeper);
        c.params = _params(false, address(pot), vm.envAddress("BUYBACK_WALLET"), vm.envAddress("OPS_WALLET"));
        LocalHarnessGame game = new LocalHarnessGame(c);
        vm.stopBroadcast();
        console2.log("POT ", address(pot));
        console2.log("GAME", address(game));
        console2.log("GENESIS", uint256(c.genesisTime));
    }
}
