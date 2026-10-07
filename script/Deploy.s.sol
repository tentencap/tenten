// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TenBlocks} from "../src/TenBlocks.sol";
import {HolderPot} from "../src/HolderPot.sol";

/// @notice Deploys HolderPot and TenBlocks on Robinhood Chain (chain id 4663).
/// @dev DRY RUN BY DEFAULT: without `--broadcast` forge only simulates, nothing is sent. This script never
///      reads a private key: signing is done by the flags you give forge (`--ledger`, `--account <keystore>`
///      or `--trezor`) when YOU run it with `--broadcast`.
///
///      Environment (all addresses are public):
///        PROFILE            "rehearsal" (tiny limits, short timeouts, to test every path) or "production"
///        OWNER              owner of the game and of the pot (the Safe)
///        KEEPER             operator of the HolderPot (the automatic keeper wallet)
///        BUYBACK_WALLET     receives the 1% buyback share (ETH)
///        OPS_WALLET         receives the 1% operations share (ETH)
///        GENESIS_DELAY      seconds from deployment to round 0 (at least 3600); default 7200
///      Run: forge script script/Deploy.s.sol --rpc-url robinhood            (dry run)
///           forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --ledger ...   (real, by you)
contract Deploy is Script {
    // verified on chain
    address constant WSNET = 0x63C12667638f2Ae6fC6ae09B43D98Ec84a8586eA;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant POOL_ETH_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // 0.01%, the deep pool
    address constant POOL_USDG_WSNET = 0x8315627976cab8bd937eB53D44D009e265D0e4DC; // 1%

    function run() external {
        require(block.chainid == 4663, "this script is for Robinhood Chain (4663)");
        bool production = keccak256(bytes(vm.envOr("PROFILE", string("rehearsal")))) == keccak256("production");
        address owner = vm.envAddress("OWNER");
        address keeper = vm.envAddress("KEEPER");
        address buyback = vm.envAddress("BUYBACK_WALLET");
        address opsWallet = vm.envAddress("OPS_WALLET");
        uint256 delay = vm.envOr("GENESIS_DELAY", uint256(7200));
        require(delay >= 3600, "genesis must be at least 1 hour away (the TWAP window must fill)");
        require(owner != address(0) && keeper != address(0), "owner and keeper required");
        if (production) {
            // the owner must be a contract (a Safe), not a single key
            require(owner.code.length > 0, "production: OWNER must be a Safe (contract)");
            require(buyback.code.length > 0 && opsWallet.code.length > 0, "production: wallets must be Safes");
            require(keeper.code.length == 0, "production: KEEPER should be a plain wallet, not a contract");
        }

        TenBlocks.Config memory c = _config(production, delay);
        c.owner = owner;

        vm.startBroadcast();
        HolderPot pot = new HolderPot(WSNET, owner, keeper);
        c.params = _params(production, address(pot), buyback, opsWallet);
        TenBlocks game = new TenBlocks(c);
        vm.stopBroadcast();

        console2.log("PROFILE", production ? "production" : "rehearsal");
        console2.log("HolderPot", address(pot));
        console2.log("TenBlocks  ", address(game));
        console2.log("genesis  ", uint256(c.genesisTime));
        console2.log("owner    ", owner);
        console2.log("keeper   ", keeper);
        console2.log("Next: run script/Verify.s.sol with GAME and POT set, then publish the addresses.");
    }

    function _config(bool production, uint256 delay) internal view returns (TenBlocks.Config memory c) {
        c = TenBlocks.Config({
            wsnet: WSNET,
            weth: WETH,
            usdg: USDG,
            router: ROUTER,
            poolEthUsdg: POOL_ETH_USDG,
            feeEthUsdg: 100,
            poolUsdgWsnet: POOL_USDG_WSNET,
            feeUsdgWsnet: 10000,
            genesisTime: uint64(block.timestamp + delay),
            beaconBuffer: 12,
            // the rehearsal shortens the safety nets so that every escape path can be exercised in a day
            refundTimeout: production ? 24 hours : 1 hours,
            carryTimeout: production ? 3 days : 2 hours,
            epochMaxEth: production ? 0.25 ether : 0.05 ether,
            epochMaxAge: 15 minutes,
            minEpochEth: production ? 0.003 ether : 0.0005 ether,
            twapSeconds: 1800,
            conversionTimeout: production ? 3 days : 2 hours,
            dormancy: production ? 90 days : 1 days,
            paramsDelay: production ? 24 hours : 1 hours,
            owner: address(0), // set by the caller
            params: _params(production, address(0), address(0), address(0))
        });
    }

    function _params(bool production, address sink, address buyback, address opsWallet)
        internal
        pure
        returns (TenBlocks.Params memory p)
    {
        p = TenBlocks.Params({
            winnerCredBps: 500, // 5% wsNET to winners
            holdersBps: 100, // 1% wsNET to TEN holders
            payloadBps: 200, // 2% ETH Payload
            buybackBps: 100, // 1% ETH buyback wallet
            opsBps: 100, // 1% ETH operations (resolver tip first)
            payloadOdds: 625,
            payloadCapMult: 25,
            claimFeeBps: 1000,
            maxDeviationBps: 300,
            minPerSquare: 1e13, // 0.00001 ETH
            minDeployTotal: 1e14, // 0.0001 ETH
            // opening limits are prudent and can be raised later with 24 h notice
            maxPerPlayerRound: production ? uint96(0.25 ether) : uint96(0.01 ether),
            maxPerRound: production ? uint96(2 ether) : uint96(0.05 ether),
            tipCap: 0.00003 ether,
            holdersSink: sink,
            buybackWallet: buyback,
            opsWallet: opsWallet,
            deploysOpen: true
        });
    }
}
