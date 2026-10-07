// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BLS} from "./lib/BLS.sol";
import {ITen, ISwapRouter02, IUniswapV3PoolMin} from "./interfaces/IExternal.sol";

/// @title TenBlocks
/// @notice 5x5 ETH grid on Robinhood Chain. No proxy and no pause. An owner (a multisig) can change bounded, delayed settings; it can never touch player funds.
/// @dev See docs/SPEC.md. Adapted ideas and code from SLVR (MIT): drand BLS verification flow,
///      packed stake records, dividend index and checkpoint pattern. See LICENSE-THIRD-PARTY.md.
contract TenBlocks is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 public constant GRID = 25;
    uint256 public constant ROUND_DURATION = 90;
    uint256 public constant BETTING_DURATION = 60;
    uint256 public constant MAX_RECORDS = 25;
    uint256 public constant MAX_RESOLVE_BATCH = 16;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DUST_FLOOR = 1e9; // wsNET wei: a residue below this is not a holder

    // hard bounds on every adjustable setting (the owner can never go outside them)
    uint256 public constant MAX_NON_ETH_BPS = 1_500; // winners always keep at least 85% in ETH
    uint16 public constant MIN_PAYLOAD_ODDS = 100;
    uint16 public constant MAX_PAYLOAD_ODDS = 2_000;
    uint16 public constant MIN_CAP_MULT = 5;
    uint16 public constant MAX_CAP_MULT = 100;
    uint16 public constant MAX_CLAIM_FEE_BPS = 2_000; // ceiling for the initial fee; afterwards it can never exceed the initial value
    uint16 public constant MIN_DEVIATION_BPS = 100;
    uint16 public constant MAX_DEVIATION_BPS_LIMIT = 700;
    uint96 public constant MIN_PER_SQUARE_FLOOR = 1e9;
    uint96 public constant MAX_PER_SQUARE_CEIL = 1e15;
    uint96 public constant MAX_DEPLOY_TOTAL_CEIL = 0.01 ether;
    uint96 public constant MAX_PLAYER_CEIL = 100 ether;
    uint96 public constant MAX_ROUND_CEIL = 1_000 ether;
    uint96 public constant MAX_TIP_CEIL = 0.01 ether;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DONATE_GAS = 800_000;
    uint16 internal constant OBSERVATION_CARDINALITY = 200;

    // drand evmnet (same parameters as the SLVR provider)
    uint256 internal constant DRAND_GENESIS = 1727521075;
    uint256 internal constant DRAND_PERIOD = 3;
    bytes internal constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";
    uint256 internal constant PK0 = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant PK1 = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant PK2 = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;
    uint256 internal constant PK3 = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;

    // round status
    uint8 internal constant ST_NONE = 0;
    uint8 internal constant ST_OPEN = 1; // has deposits, not resolved
    uint8 internal constant ST_WINNER = 2;
    uint8 internal constant ST_EMPTY = 3;
    uint8 internal constant ST_SKIPPED = 4; // refundable and skipped in the ordering

    // epoch state
    uint8 internal constant EP_OPEN = 0;
    uint8 internal constant EP_CLOSED = 1;
    uint8 internal constant EP_CONVERTED = 2;
    uint8 internal constant EP_RELEASED = 3;
    uint8 internal constant EP_CONVERTING = 4; // transient, only while the swap is in flight

    // claim flag bits
    uint8 internal constant F_IMM = 1; // ETH part claimed (includes the Payload when it hit)
    uint8 internal constant F_POOL = 2; // wsNET pool part claimed
    uint8 internal constant F_REFUND = 4; // refunded (unresolved round or released carry)

    // ------------------------------------------------------------------ config (immutables)
    struct Config {
        address wsnet;
        address weth;
        address usdg;
        address router;
        address poolEthUsdg;
        uint24 feeEthUsdg;
        address poolUsdgWsnet;
        uint24 feeUsdgWsnet;
        uint64 genesisTime;
        uint32 beaconBuffer;
        uint64 refundTimeout;
        uint64 carryTimeout;
        uint256 epochMaxEth;
        uint64 epochMaxAge;
        uint256 minEpochEth;
        uint32 twapSeconds;
        uint64 conversionTimeout;
        uint64 dormancy;
        uint64 paramsDelay; // delay between proposing and applying new settings
        address owner; // address(0) = no owner from day one
        Params params; // initial settings
    }

    /// @notice Settings the owner can change (bounded, delayed, and frozen per round).
    struct Params {
        uint16 winnerCredBps; // wsNET to the winning square (paid in ETH value, converted)
        uint16 holdersBps; // wsNET to TEN holders (through the holders sink)
        uint16 payloadBps; // ETH into the Payload
        uint16 buybackBps; // ETH to the buyback wallet
        uint16 opsBps; // ETH to operations (the resolver is tipped first)
        uint16 payloadOdds; // a hit is 1 in this many rounds with a winner
        uint16 payloadCapMult; // a hit pays at most this many times the hitting round's wager
        uint16 claimFeeBps; // fee on unrefined wsNET when refined
        uint16 maxDeviationBps; // swap tolerance on top of pool fees
        uint96 minPerSquare;
        uint96 minDeployTotal;
        uint96 maxPerPlayerRound;
        uint96 maxPerRound;
        uint96 tipCap;
        address holdersSink; // must implement donateReward(asset, amount)
        address buybackWallet;
        address opsWallet;
        bool deploysOpen; // false: new rounds take no deposits (resolve, claim and refunds keep working)
    }

    address public immutable WSNET;
    address public immutable WETH;
    address public immutable USDG;
    address public immutable ROUTER;
    address public immutable POOL_ETH_USDG;
    uint24 public immutable FEE_ETH_USDG;
    address public immutable POOL_USDG_WSNET;
    uint24 public immutable FEE_USDG_WSNET;
    bool internal immutable ETH_IS_TOKEN0_A;
    bool internal immutable USDG_IS_TOKEN0_B;
    uint64 public immutable GENESIS_TIME;
    uint32 public immutable BEACON_BUFFER;
    uint64 public immutable REFUND_TIMEOUT;
    uint64 public immutable CARRY_TIMEOUT;
    uint256 public immutable EPOCH_MAX_ETH;
    uint64 public immutable EPOCH_MAX_AGE;
    uint256 public immutable MIN_EPOCH_ETH;
    uint32 public immutable TWAP_SECONDS;
    uint64 public immutable CONVERSION_TIMEOUT;
    uint64 public immutable DORMANCY;
    uint64 public immutable PARAMS_DELAY;
    uint16 public immutable CLAIM_FEE_MAX; // the claim fee can be lowered but never raised above its initial value

    // ------------------------------------------------------------------ storage
    struct Stake {
        uint32 mask;
        uint96 amount;
    }

    struct Round {
        uint96 totalWager;
        uint96 winnerTotal;
        uint96 potEth; // winners' ETH (incl. carry). For ST_EMPTY: the round's own 90% ETH
        uint96 credEth; // winners' wsNET credit in ETH value (incl. carry). For ST_EMPTY: own 5%
        uint96 payloadPaid; // Payload ETH that was added to this round's pot (0 if no hit)
        uint96 claimedStakeImm; // winning stake that has claimed the ETH part (ST_EMPTY: refunded stake)
        uint96 claimedStakePool;
        uint96 paidEth;
        uint128 paidPool; // wsNET (epoch converted) or ETH face (epoch released)
        uint32 prevPlus1; // previous round with deposits, plus one (0 = none)
        uint32 epoch;
        uint32 chainId;
        uint32 paramsId; // the settings version this round was played under (fixed at its first deposit)
        uint8 winningSquare;
        uint8 status;
    }

    struct Epoch {
        uint96 ethCred;
        uint96 ethHolders;
        uint64 firstAt;
        uint64 closedAt;
        uint8 state;
        uint128 rate; // wsNET per ETH, scaled 1e18 (set at conversion)
        uint256 index; // minerIndex stamped at conversion
    }

    struct Miner {
        uint128 bal; // credited, unrefined wsNET (principal)
        uint128 accrued; // attributed dividends
        uint256 snap; // minerIndex at last checkpoint
    }

    mapping(uint256 => Round) internal rounds;
    mapping(uint256 => uint96[25]) internal totalOnSquare;
    mapping(uint256 => mapping(address => Stake[])) internal stakes;
    mapping(uint256 => mapping(address => uint96)) public playerTotal;
    mapping(uint256 => mapping(address => uint8)) public flags;

    uint32 public lastDepositedPlus1;
    uint96 public carryEth;
    uint96 public carryCredit;
    uint32 public carryChain;
    uint64 public lastEmptyAt;
    uint64 public lastWinnerAt;
    mapping(uint32 => bool) public chainReleased;

    Epoch[] internal epochs;
    uint32 public openEpoch;
    uint32 public nextToConvert;

    uint96 public payloadEth; // ETH waiting for a hit
    uint96 public opsAccrued; // ETH owed to the operations wallet
    uint96 public buybackAccrued; // ETH owed to the buyback wallet
    uint96 public holdersEthPending; // holders' ETH waiting to enter an epoch, one epoch's worth per call

    Params[] internal paramsList; // settings versions; the last applied one is the current one
    Params internal pendingParams_;
    uint64 public pendingParamsAt; // 0 = nothing pending
    address public owner;
    address public pendingOwner;
    uint128 public holdersOwed; // wsNET parked after a failed donateReward

    mapping(address => Miner) internal miners;
    uint256 public minerIndex;
    uint256 public totalUnclaimed; // reservedWs + sum of miner principal
    uint256 public reservedWs; // converted wsNET not yet credited to a person
    uint256 public totalRefined; // dividends owed (collected fees)
    uint256 public totalAttributed; // dividends assigned to miners

    // ------------------------------------------------------------------ events
    event Deployed(uint256 indexed round, address indexed player, uint32 mask, uint96 amountPerSquare, uint96 total);
    event Resolved(
        uint256 indexed round,
        uint8 square,
        uint96 winnerTotal,
        uint96 potEth,
        uint96 credEth,
        uint96 payloadPaid,
        uint32 epoch,
        bool carried
    );
    event Claimed(uint256 indexed round, address indexed player, uint256 ethOut, uint256 wsCredited);
    event Withdrawn(address indexed miner, uint256 payout, uint256 fee);
    event EpochClosed(uint32 indexed epoch, uint96 ethTotal);
    event Converted(uint32 indexed epoch, uint256 ethIn, uint256 wsOut, uint256 wsHolders);
    event EpochReleased(uint32 indexed epoch);
    event HoldersDonated(uint256 amount, uint256 parked);
    event Refunded(uint256 indexed round, address indexed player, uint256 amount);
    event CarryReleased(uint32 indexed chainId, uint256 eth);
    event RoundSkipped(uint256 indexed round);
    event PayloadSwept(uint256 amount);
    event OpsSwept(uint256 amount);
    event BuybackSwept(uint256 amount);
    event ParamsProposed(uint64 effectiveAt, Params params);
    event ParamsApplied(uint32 indexed id, Params params);
    event ParamsCancelled();
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event TipPaid(address indexed to, uint256 amount);

    // ------------------------------------------------------------------ errors
    error BadConfig();
    error NotStarted();
    error Closed();
    error BadInput();
    error BadValue();
    error LimitPlayer();
    error LimitRound();
    error TooManyRecords();
    error NotResolvable();
    error IsRefundable();
    error PrevPending();
    error TooEarly();
    error BadBeacon();
    error NotWinnerRound();
    error NoStake();
    error NothingToClaim();
    error SendFailed();
    error NotRefundable();
    error Settled();
    error NothingToDo();
    error TooManyRounds();
    error CarryNotReleased();
    error LowGas();
    error NotOwner();
    error OutOfBounds();
    error NothingPending();
    error DeploysClosed();
    error Bad();

    // ------------------------------------------------------------------ constructor
    constructor(Config memory c) {
        if (
            c.wsnet == address(0) || c.weth == address(0) || c.usdg == address(0) || c.router == address(0)
                || c.poolEthUsdg == address(0) || c.poolUsdgWsnet == address(0)
        ) revert BadConfig();
        if (c.genesisTime < block.timestamp + c.twapSeconds) revert BadConfig(); // the TWAP window must fill before the first round
        if (c.twapSeconds > 1 days) revert BadConfig();
        if (c.beaconBuffer < 3 || c.beaconBuffer > 300) revert BadConfig();
        if (c.refundTimeout < 1 hours || c.carryTimeout == 0 || c.conversionTimeout == 0 || c.dormancy == 0) {
            revert BadConfig();
        }
        if (c.paramsDelay < 1 hours || c.paramsDelay > 30 days) revert BadConfig();
        if (c.epochMaxEth == 0 || c.epochMaxEth > type(uint96).max / 4 || c.minEpochEth > c.epochMaxEth) {
            revert BadConfig();
        }
        if (c.epochMaxAge == 0 || c.twapSeconds < 60) revert BadConfig();
        if (c.params.claimFeeBps > MAX_CLAIM_FEE_BPS) revert BadConfig();
        CLAIM_FEE_MAX = c.params.claimFeeBps;
        _validate(c.params, c.params.claimFeeBps);

        WSNET = c.wsnet;
        WETH = c.weth;
        USDG = c.usdg;
        ROUTER = c.router;
        POOL_ETH_USDG = c.poolEthUsdg;
        FEE_ETH_USDG = c.feeEthUsdg;
        POOL_USDG_WSNET = c.poolUsdgWsnet;
        FEE_USDG_WSNET = c.feeUsdgWsnet;
        GENESIS_TIME = c.genesisTime;
        BEACON_BUFFER = c.beaconBuffer;
        REFUND_TIMEOUT = c.refundTimeout;
        CARRY_TIMEOUT = c.carryTimeout;
        EPOCH_MAX_ETH = c.epochMaxEth;
        EPOCH_MAX_AGE = c.epochMaxAge;
        MIN_EPOCH_ETH = c.minEpochEth;
        TWAP_SECONDS = c.twapSeconds;
        CONVERSION_TIMEOUT = c.conversionTimeout;
        DORMANCY = c.dormancy;
        PARAMS_DELAY = c.paramsDelay;
        owner = c.owner;
        paramsList.push(c.params);
        emit OwnershipTransferred(address(0), c.owner);

        // pool A must be WETH/USDG, pool B must be USDG/wsNET (token order read from the pools)
        IUniswapV3PoolMin a = IUniswapV3PoolMin(c.poolEthUsdg);
        IUniswapV3PoolMin b = IUniswapV3PoolMin(c.poolUsdgWsnet);
        address a0 = a.token0();
        address a1 = a.token1();
        if (!((a0 == c.weth && a1 == c.usdg) || (a0 == c.usdg && a1 == c.weth))) revert BadConfig();
        address b0 = b.token0();
        address b1 = b.token1();
        if (!((b0 == c.usdg && b1 == c.wsnet) || (b0 == c.wsnet && b1 == c.usdg))) revert BadConfig();
        if (a.fee() != c.feeEthUsdg || b.fee() != c.feeUsdgWsnet) revert BadConfig();
        if (ISwapRouter02(c.router).WETH9() != c.weth) revert BadConfig();
        ETH_IS_TOKEN0_A = a0 == c.weth;
        USDG_IS_TOKEN0_B = b0 == c.usdg;
        // the thin pool has no price history until its observation buffer is grown
        b.increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);

        epochs.push(); // epoch 0, open
        lastWinnerAt = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------ settings (owner, bounded and delayed)
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Every adjustable setting is inside hard bounds the owner can never leave.
    function _validate(Params memory p, uint16 maxClaimFee) internal {
        uint256 nonEth = uint256(p.winnerCredBps) + p.holdersBps + p.payloadBps + p.buybackBps + p.opsBps;
        if (nonEth > MAX_NON_ETH_BPS) revert OutOfBounds(); // winners keep at least 85% in ETH
        if (p.payloadOdds < MIN_PAYLOAD_ODDS || p.payloadOdds > MAX_PAYLOAD_ODDS) revert OutOfBounds();
        if (p.payloadCapMult < MIN_CAP_MULT || p.payloadCapMult > MAX_CAP_MULT) revert OutOfBounds();
        if (p.claimFeeBps > maxClaimFee) revert OutOfBounds();
        // a Payload hunter's expectation stays negative: capMult/odds can never exceed the shares a hunter does not
        // get back (holders, buyback, Payload; the operations share can come back to a self-resolving hunter as the tip)
        if (uint256(p.payloadCapMult) * 10_000 > uint256(p.payloadOdds) * (uint256(p.holdersBps) + p.buybackBps + p.payloadBps)) {
            revert OutOfBounds();
        }
        if (p.maxDeviationBps < MIN_DEVIATION_BPS || p.maxDeviationBps > MAX_DEVIATION_BPS_LIMIT) revert OutOfBounds();
        if (p.minPerSquare < MIN_PER_SQUARE_FLOOR || p.minPerSquare > MAX_PER_SQUARE_CEIL) revert OutOfBounds();
        if (p.minDeployTotal < p.minPerSquare || p.minDeployTotal > MAX_DEPLOY_TOTAL_CEIL) revert OutOfBounds();
        if (p.maxPerPlayerRound < p.minDeployTotal || p.maxPerPlayerRound > MAX_PLAYER_CEIL) revert OutOfBounds();
        if (p.maxPerRound < p.maxPerPlayerRound || p.maxPerRound > MAX_ROUND_CEIL) revert OutOfBounds();
        if (p.tipCap > MAX_TIP_CEIL) revert OutOfBounds();
        if (p.holdersSink.code.length == 0) revert OutOfBounds(); // must be a contract
        if (p.buybackWallet == address(0) || p.opsWallet == address(0)) revert OutOfBounds();
        if (!_canReceive(p.buybackWallet) || !_canReceive(p.opsWallet)) revert OutOfBounds(); // a wallet that rejects ETH would strand its share
    }

    function _canReceive(address a) internal returns (bool ok) {
        (ok,) = a.call{value: 0}("");
    }

    /// @notice Propose new settings. They become visible at once and can be applied by anyone after
    ///         `PARAMS_DELAY`. A new proposal replaces a pending one. Rounds that already have a deposit
    ///         keep the settings they started with.
    function proposeParams(Params calldata p) external onlyOwner {
        _validate(p, CLAIM_FEE_MAX);
        pendingParams_ = p;
        uint64 at = uint64(block.timestamp) + PARAMS_DELAY;
        pendingParamsAt = at;
        emit ParamsProposed(at, p);
    }

    function cancelParams() external onlyOwner {
        if (pendingParamsAt == 0) revert NothingPending();
        delete pendingParams_;
        pendingParamsAt = 0;
        emit ParamsCancelled();
    }

    /// @notice Make the pending settings current. Permissionless once the delay has passed.
    function applyParams() external {
        uint64 at = pendingParamsAt;
        if (at == 0) revert NothingPending();
        if (block.timestamp < at) revert TooEarly();
        paramsList.push(pendingParams_);
        delete pendingParams_;
        pendingParamsAt = 0;
        uint32 id = uint32(paramsList.length - 1);
        emit ParamsApplied(id, paramsList[id]);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(msg.sender, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
        // a proposal made by the previous owner does not carry over: the new owner must propose again
        if (pendingParamsAt != 0) {
            delete pendingParams_;
            pendingParamsAt = 0;
            emit ParamsCancelled();
        }
    }

    /// @notice Give up the owner role for good. The settings are then frozen (a pending proposal is cancelled).
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
        if (pendingParamsAt != 0) {
            delete pendingParams_;
            pendingParamsAt = 0;
            emit ParamsCancelled();
        }
    }

    function _current() internal view returns (Params storage) {
        return paramsList[paramsList.length - 1];
    }

    // ------------------------------------------------------------------ time
    function currentRound() public view returns (uint256) {
        if (block.timestamp < GENESIS_TIME) revert NotStarted();
        return (block.timestamp - GENESIS_TIME) / ROUND_DURATION;
    }

    function roundStart(uint256 r) public view returns (uint256) {
        return uint256(GENESIS_TIME) + r * ROUND_DURATION;
    }

    function bettingEnd(uint256 r) public view returns (uint256) {
        return roundStart(r) + BETTING_DURATION;
    }

    function beaconUnlock(uint256 r) public view returns (uint256) {
        return bettingEnd(r) + BEACON_BUFFER;
    }

    /// @notice drand evmnet round that decides round `r`: the first one produced strictly after `beaconUnlock(r)`.
    function drandRound(uint256 r) public view returns (uint64) {
        return uint64((beaconUnlock(r) - DRAND_GENESIS) / DRAND_PERIOD + 2);
    }

    // ------------------------------------------------------------------ deploy
    function deploy(uint8[] calldata squares, uint96[] calldata amounts) external payable nonReentrant {
        _deploy(msg.sender, squares, amounts);
    }

    /// @notice Resolve the head round and deploy in one transaction.
    function resolveAndDeploy(uint256 resolveRoundId, uint256[2] calldata sig, uint8[] calldata squares, uint96[] calldata amounts)
        external
        payable
        nonReentrant
    {
        uint256 tip;
        if (rounds[resolveRoundId].status == ST_OPEN && block.timestamp < beaconUnlock(resolveRoundId) + REFUND_TIMEOUT) {
            tip = _resolve(resolveRoundId, sig); // skipped if someone else resolved it first, or it is already refundable
        }
        _deploy(msg.sender, squares, amounts);
        _payTip(msg.sender, tip);
    }

    function _deploy(address player, uint8[] calldata squares, uint96[] calldata amounts) internal {
        uint256 r = currentRound();
        if (block.timestamp >= bettingEnd(r)) revert Closed();
        uint256 n = squares.length;
        if (n == 0 || n != amounts.length) revert BadInput();
        Round storage R = rounds[r];
        // a round plays under the settings that were current at its first deposit
        uint32 pid = R.status == ST_NONE ? uint32(paramsList.length - 1) : R.paramsId;
        Params storage P = paramsList[pid];
        if (!P.deploysOpen) revert DeploysClosed();
        if (msg.value < P.minDeployTotal) revert BadValue();

        uint256 seen;
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            uint256 s = squares[i];
            if (s >= GRID) revert BadInput();
            uint256 bit = uint256(1) << s;
            if (seen & bit != 0) revert BadInput();
            seen |= bit;
            if (amounts[i] < P.minPerSquare) revert BadValue();
            sum += amounts[i];
        }
        if (sum != msg.value) revert BadValue();

        if (R.status == ST_NONE) {
            R.status = ST_OPEN;
            R.paramsId = pid;
            R.prevPlus1 = lastDepositedPlus1;
            lastDepositedPlus1 = _u32(r) + 1;
        }
        uint256 pt = uint256(playerTotal[r][player]) + sum;
        if (pt > P.maxPerPlayerRound) revert LimitPlayer();
        uint256 rt = uint256(R.totalWager) + sum;
        if (rt > P.maxPerRound) revert LimitRound();
        playerTotal[r][player] = uint96(pt);
        R.totalWager = uint96(rt);

        _recordStakes(r, player, squares, amounts);
    }

    /// @dev Squares that share an amount become one stake record (a "select all" is one record).
    function _recordStakes(uint256 r, address player, uint8[] calldata squares, uint96[] calldata amounts) internal {
        uint256 n = squares.length;
        bool[] memory grouped = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            if (grouped[i]) continue;
            uint96 amount = amounts[i];
            uint32 mask = uint32(1) << squares[i];
            for (uint256 j = i + 1; j < n; j++) {
                if (!grouped[j] && amounts[j] == amount) {
                    mask |= uint32(1) << squares[j];
                    grouped[j] = true;
                }
            }
            _addStake(r, player, mask, amount);
            _bump(r, player, mask, amount);
        }
    }

    function _bump(uint256 r, address player, uint32 mask, uint96 amount) internal {
        uint96 groupTotal;
        for (uint8 s = 0; s < 25; s++) {
            if (mask & (uint32(1) << s) != 0) {
                totalOnSquare[r][s] += amount;
                groupTotal += amount;
            }
        }
        emit Deployed(r, player, mask, amount, groupTotal);
    }

    function _addStake(uint256 r, address player, uint32 mask, uint96 amount) internal {
        Stake[] storage st = stakes[r][player];
        uint256 len = st.length;
        for (uint256 i = 0; i < len; i++) {
            if (st[i].mask == mask) {
                st[i].amount += amount;
                return;
            }
        }
        if (len >= MAX_RECORDS) revert TooManyRecords();
        st.push(Stake({mask: mask, amount: amount}));
    }

    function _stakeOn(uint256 r, address player, uint8 square) internal view returns (uint256 sum) {
        Stake[] storage st = stakes[r][player];
        uint32 bit = uint32(1) << square;
        uint256 len = st.length;
        for (uint256 i = 0; i < len; i++) {
            if (st[i].mask & bit != 0) sum += st[i].amount;
        }
    }

    // ------------------------------------------------------------------ resolve
    function resolve(uint256 r, uint256[2] calldata sig) external nonReentrant {
        uint256 tip = _resolve(r, sig);
        _payTip(msg.sender, tip);
    }

    function resolveMany(uint256[] calldata rs, uint256[2][] calldata sigs) external nonReentrant {
        if (rs.length != sigs.length) revert BadInput();
        if (rs.length > MAX_RESOLVE_BATCH) revert TooManyRounds();
        uint256 tips;
        for (uint256 i = 0; i < rs.length; i++) {
            if (rounds[rs[i]].status != ST_OPEN) continue; // already resolved by someone else
            tips += _resolve(rs[i], sigs[i]);
        }
        _payTip(msg.sender, tips);
    }

    function _resolve(uint256 r, uint256[2] calldata sig) internal returns (uint256 tip) {
        Round storage R = rounds[r];
        if (R.status != ST_OPEN) revert NotResolvable();
        if (block.timestamp < beaconUnlock(r)) revert TooEarly();
        if (block.timestamp >= beaconUnlock(r) + REFUND_TIMEOUT) revert IsRefundable();
        if (R.prevPlus1 != 0 && rounds[R.prevPlus1 - 1].status < ST_WINNER) revert PrevPending();
        uint256 rv = _beacon(r, sig);
        tip = _settle(r, R, rv);
    }

    /// @dev Overridden only by the test harness, which forces randomness.
    function _beacon(uint256 r, uint256[2] calldata sig) internal view virtual returns (uint256 rv) {
        uint64 round = drandRound(r);
        uint256[2] memory s = sig;
        if (!BLS.isValidSignature(s)) revert BadBeacon();
        uint256[4] memory pk = [PK0, PK1, PK2, PK3];
        uint256[2] memory message = BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(round))));
        (bool pairingOk, bool callOk) = BLS.verifySingle(s, pk, message);
        if (!pairingOk || !callOk) revert BadBeacon();
        rv = uint256(sha256(abi.encodePacked(sig[0], sig[1])));
    }

    function _settle(uint256 r, Round storage R, uint256 rv) internal returns (uint256 tip) {
        uint256 w = R.totalWager;
        Params storage P = paramsList[R.paramsId];
        uint256 winnerCredit = (w * P.winnerCredBps) / BPS;
        uint256 holders = (w * P.holdersBps) / BPS;
        uint256 payload = (w * P.payloadBps) / BPS;
        uint256 ops = (w * P.opsBps) / BPS;
        uint256 buyback = (w * P.buybackBps) / BPS;
        uint256 ethPot = w - winnerCredit - holders - payload - ops - buyback; // the rest, plus rounding remainder

        // operations: the resolver is tipped first, the rest accrues to the operations wallet
        tip = ops < P.tipCap ? ops : P.tipCap;
        opsAccrued += _u96(ops - tip);
        buybackAccrued += _u96(buyback);
        // this round's Payload share is in the Payload before the hit is rolled
        payloadEth += _u96(payload);

        uint8 square = uint8(uint256(keccak256(abi.encodePacked(rv, r, "sq"))) % GRID);
        uint96 winnerTotal = totalOnSquare[r][square];
        R.winningSquare = square;
        R.winnerTotal = winnerTotal;
        R.epoch = openEpoch;

        if (winnerTotal > 0) {
            uint256 cEth = carryEth;
            uint256 cCred = carryCredit;
            uint256 pot = ethPot + cEth;
            R.credEth = _u96(winnerCredit + cCred);
            if (cEth != 0 || cCred != 0) {
                carryEth = 0;
                carryCredit = 0;
                carryChain++;
            }
            if (uint256(keccak256(abi.encodePacked(rv, r, "pl"))) % P.payloadOdds == 0) {
                // a dust round cannot take a big Payload: the part above the cap stays for later hits
                uint256 cap = w * P.payloadCapMult;
                uint96 p = payloadEth > cap ? uint96(cap) : payloadEth;
                payloadEth -= p;
                R.payloadPaid = p;
                pot += p;
            }
            R.potEth = _u96(pot);
            R.status = ST_WINNER;
            lastWinnerAt = uint64(block.timestamp);
            _addToEpoch(R.credEth, _u96(holders));
            emit Resolved(r, square, winnerTotal, R.potEth, R.credEth, R.payloadPaid, R.epoch, false);
        } else {
            R.potEth = _u96(ethPot);
            R.credEth = _u96(winnerCredit);
            R.chainId = carryChain;
            R.status = ST_EMPTY;
            carryEth += _u96(ethPot);
            carryCredit += _u96(winnerCredit);
            lastEmptyAt = uint64(block.timestamp);
            _addToEpoch(0, _u96(holders));
            emit Resolved(r, square, 0, R.potEth, R.credEth, 0, R.epoch, true);
        }
    }

    // ------------------------------------------------------------------ epochs and conversion
    function _addToEpoch(uint96 cred, uint96 holders) internal {
        Epoch storage e = epochs[openEpoch];
        uint256 before = uint256(e.ethCred) + e.ethHolders;
        // a round's amounts stay together in one epoch; close the current one first so epochs stay near the cap
        if (before > 0 && before + cred + holders > EPOCH_MAX_ETH) {
            _closeOpen();
            e = epochs[openEpoch];
            before = 0;
        }
        e.ethCred += cred;
        e.ethHolders += holders;
        uint256 total = before + cred + holders;
        if (before == 0 && total > 0) e.firstAt = uint64(block.timestamp);
        if (total >= EPOCH_MAX_ETH) _closeOpen();
    }

    /// @dev Moves holders' ETH that is waiting (after a release or a Payload sweep) into the open epoch,
    ///      at most what fits under EPOCH_MAX_ETH, so no epoch made this way is bigger than the pool can take.
    function _feedHolders() internal {
        uint96 pend = holdersEthPending;
        if (pend == 0) return;
        Epoch storage e = epochs[openEpoch];
        uint256 total = uint256(e.ethCred) + e.ethHolders;
        if (total >= EPOCH_MAX_ETH) return;
        uint256 room = EPOCH_MAX_ETH - total;
        uint96 move = pend > room ? uint96(room) : pend;
        holdersEthPending = pend - move;
        _addToEpoch(0, move);
    }

    /// @notice Move waiting holders' ETH into the conversion queue, one epoch's worth per call.
    function feedHolders() external nonReentrant {
        if (holdersEthPending == 0) revert NothingToDo();
        _feedHolders();
    }

    function _closeOpen() internal {
        Epoch storage e = epochs[openEpoch];
        e.state = EP_CLOSED;
        e.closedAt = uint64(block.timestamp);
        emit EpochClosed(openEpoch, _u96(uint256(e.ethCred) + e.ethHolders));
        epochs.push();
        openEpoch = uint32(epochs.length - 1);
    }

    function _maybeCloseByAge() internal {
        Epoch storage e = epochs[openEpoch];
        uint256 total = uint256(e.ethCred) + e.ethHolders;
        if (total == 0 || block.timestamp < uint256(e.firstAt) + EPOCH_MAX_AGE) return;
        // a part-filled epoch below the minimum still closes once it has waited CONVERSION_TIMEOUT
        if (total >= MIN_EPOCH_ETH || block.timestamp >= uint256(e.firstAt) + CONVERSION_TIMEOUT) _closeOpen();
    }

    /// @notice Convert the oldest closed epoch to wsNET. Permissionless.
    function convert() external nonReentrant {
        _feedHolders();
        _maybeCloseByAge();
        uint32 idx = nextToConvert;
        uint256 len = epochs.length;
        while (idx < len && epochs[idx].state >= EP_CONVERTED) idx++;
        nextToConvert = idx;
        if (idx >= len || epochs[idx].state != EP_CLOSED) revert NothingToDo();
        _convertEpoch(idx);
    }

    /// @notice Convert a specific closed epoch. Epochs are independent (each has its own rate), so a
    ///         head epoch that cannot convert (for example an oversized one) does not block the others.
    function convertEpoch(uint32 idx) external nonReentrant {
        if (idx >= epochs.length || epochs[idx].state != EP_CLOSED) revert NothingToDo();
        _convertEpoch(idx);
        _advancePointer();
    }

    /// @notice Close the open epoch once it is old enough. Persists even when no conversion can run.
    function closeEpoch() external nonReentrant {
        uint32 before = openEpoch;
        _feedHolders();
        _maybeCloseByAge();
        if (openEpoch == before) revert NothingToDo();
    }

    function _advancePointer() internal {
        uint32 idx = nextToConvert;
        uint256 len = epochs.length;
        while (idx < len && epochs[idx].state >= EP_CONVERTED && epochs[idx].state != EP_CONVERTING) idx++;
        nextToConvert = idx;
    }

    function _convertEpoch(uint32 idx) internal {
        Epoch storage e = epochs[idx];
        uint256 ethIn = uint256(e.ethCred) + e.ethHolders;
        uint256 minOut = (_expectedOut(ethIn) * (BPS - _current().maxDeviationBps)) / BPS;

        e.state = EP_CONVERTING; // the epoch cannot be touched again until this call ends
        uint256 balBefore = IERC20(WSNET).balanceOf(address(this));
        ISwapRouter02(ROUTER).exactInput{value: ethIn}(
            ISwapRouter02.ExactInputParams({
                path: abi.encodePacked(WETH, FEE_ETH_USDG, USDG, FEE_USDG_WSNET, WSNET),
                recipient: address(this),
                amountIn: ethIn,
                amountOutMinimum: minOut
            })
        );
        uint256 out = IERC20(WSNET).balanceOf(address(this)) - balBefore;
        if (out < minOut || out == 0) revert BadValue();

        uint256 rate = (out * WAD) / ethIn;
        uint256 wsCred = (uint256(e.ethCred) * rate) / WAD;
        uint256 wsHolders = out - wsCred; // the holders' share takes the rounding remainder

        e.state = EP_CONVERTED;
        e.rate = uint128(rate);
        e.index = minerIndex;
        reservedWs += wsCred;
        totalUnclaimed += wsCred;
        emit Converted(idx, ethIn, out, wsHolders);

        _donate(wsHolders);
    }

    /// @notice A closed epoch that could not be converted for CONVERSION_TIMEOUT is released:
    ///         winners redeem their credit in ETH at face value; the holders' ETH rolls forward.
    function releaseEpoch(uint32 idx) external nonReentrant {
        if (idx >= epochs.length) revert Bad();
        Epoch storage e = epochs[idx];
        if (e.state != EP_CLOSED) revert NothingToDo(); // an open epoch is closed first with closeEpoch()
        if (block.timestamp < uint256(e.closedAt) + CONVERSION_TIMEOUT) revert TooEarly();
        e.state = EP_RELEASED;
        uint96 h = e.ethHolders;
        e.ethHolders = 0;
        emit EpochReleased(idx);
        holdersEthPending += h; // re-enters the queue in epoch-sized pieces (feedHolders / convert)
        _advancePointer();
    }

    function _donate(uint256 amount) internal {
        if (amount == 0) return;
        if (gasleft() < (DONATE_GAS * 64) / 63 + 300_000) revert LowGas(); // never starve the donation or the code after it
        IERC20 ws = IERC20(WSNET);
        uint256 balBefore = ws.balanceOf(address(this));
        address sink = _current().holdersSink;
        ws.forceApprove(sink, amount);
        // low-level on purpose: no extcodesize revert, no return-data bomb; the outcome is read from balances
        bytes memory data = abi.encodeCall(ITen.donateReward, (WSNET, amount));
        bool ok;
        assembly {
            // return data is not copied (a sink could return megabytes to burn gas)
            ok := call(DONATE_GAS, sink, 0, add(data, 32), mload(data), 0, 0)
        }
        ok;
        ws.forceApprove(sink, 0);
        uint256 balAfter = ws.balanceOf(address(this));
        uint256 pulled = balBefore > balAfter ? balBefore - balAfter : 0;
        uint256 parked = pulled >= amount ? 0 : amount - pulled;
        if (parked != 0) holdersOwed += uint128(parked);
        emit HoldersDonated(amount - parked, parked);
    }

    function flushHolders() external nonReentrant {
        uint256 amount = holdersOwed;
        if (amount == 0) revert NothingToDo();
        holdersOwed = 0;
        _donate(amount);
    }

    /// @notice After DORMANCY without a winning round, the Payload ETH joins the TEN holders' conversion bucket.
    function sweepPayload() external nonReentrant {
        if (block.timestamp < uint256(lastWinnerAt) + DORMANCY) revert TooEarly();
        uint96 amount = payloadEth;
        if (amount == 0) revert NothingToDo();
        payloadEth = 0;
        emit PayloadSwept(amount);
        holdersEthPending += amount; // enters the queue in epoch-sized pieces
    }

    /// @notice Send the accrued operations share to the operations wallet. Permissionless.
    function sweepOps() external nonReentrant {
        uint256 amount = opsAccrued;
        if (amount == 0) revert NothingToDo();
        opsAccrued = 0;
        (bool ok,) = _current().opsWallet.call{value: amount}("");
        if (!ok) revert SendFailed();
        emit OpsSwept(amount);
    }

    /// @notice Send the accrued buyback share to the buyback wallet. Permissionless.
    function sweepBuyback() external nonReentrant {
        uint256 amount = buybackAccrued;
        if (amount == 0) revert NothingToDo();
        buybackAccrued = 0;
        (bool ok,) = _current().buybackWallet.call{value: amount}("");
        if (!ok) revert SendFailed();
        emit BuybackSwept(amount);
    }

    function _payTip(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (ok) {
            emit TipPaid(to, amount);
        } else {
            opsAccrued += _u96(amount); // a resolver that cannot receive ETH forfeits the tip to operations
        }
    }

    // ------------------------------------------------------------------ price check (TWAP)
    function _twapTick(address pool) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_SECONDS;
        ago[1] = 0;
        (int56[] memory tc,) = IUniswapV3PoolMin(pool).observe(ago);
        int56 delta = tc[1] - tc[0];
        int56 secs = int56(uint56(TWAP_SECONDS));
        int56 t = delta / secs;
        if (delta < 0 && delta % secs != 0) t--;
        return int24(t);
    }

    function _quote(uint256 amountIn, int24 tick, bool inIsToken0) internal pure returns (uint256) {
        uint256 sq = TickMath.getSqrtPriceAtTick(tick);
        if (inIsToken0) {
            return FullMath.mulDiv(FullMath.mulDiv(amountIn, sq, 1 << 96), sq, 1 << 96);
        }
        return FullMath.mulDiv(FullMath.mulDiv(amountIn, 1 << 96, sq), 1 << 96, sq);
    }

    function _expectedOut(uint256 ethIn) internal view returns (uint256) {
        uint256 usdgOut = _quote(ethIn, _twapTick(POOL_ETH_USDG), ETH_IS_TOKEN0_A);
        usdgOut = (usdgOut * (1_000_000 - FEE_ETH_USDG)) / 1_000_000; // net of the pool fee
        uint256 wsOut = _quote(usdgOut, _twapTick(POOL_USDG_WSNET), USDG_IS_TOKEN0_B);
        return (wsOut * (1_000_000 - FEE_USDG_WSNET)) / 1_000_000;
    }

    /// @notice wsNET the TWAP implies for `ethIn`, net of the two pool fees (before the tolerance). For keepers and the site.
    function twapExpectedOut(uint256 ethIn) external view returns (uint256) {
        return _expectedOut(ethIn);
    }

    // ------------------------------------------------------------------ claim
    function claim(uint256[] calldata rs, bool takeWsnet) external nonReentrant {
        _claim(msg.sender, payable(msg.sender), rs, takeWsnet);
    }

    function claimTo(address payable to, uint256[] calldata rs, bool takeWsnet) external nonReentrant {
        if (to == address(0)) revert BadInput();
        _claim(msg.sender, to, rs, takeWsnet);
    }

    function _slice(uint256 total, uint256 paid, uint256 stake, uint256 claimedBefore, uint256 winnerTotal)
        internal
        pure
        returns (uint256)
    {
        if (claimedBefore + stake >= winnerTotal) return total - paid; // last claimer takes the exact remainder
        return (total * stake) / winnerTotal;
    }

    function _claim(address user, address payable to, uint256[] calldata rs, bool takeWs) internal {
        uint256 ethTotal;
        for (uint256 i = 0; i < rs.length; i++) {
            (uint256 e, uint256 ws) = _claimRound(user, rs[i]);
            ethTotal += e;
            emit Claimed(rs[i], user, e, ws);
        }
        uint256 wsOut;
        if (takeWs) {
            (wsOut,) = _refine(user);
        }
        if (ethTotal > 0) {
            (bool ok,) = to.call{value: ethTotal}("");
            if (!ok) revert SendFailed();
        }
        if (wsOut > 0) IERC20(WSNET).safeTransfer(to, wsOut);
    }

    function _claimRound(address user, uint256 r) internal returns (uint256 ethOut, uint256 wsCredited) {
        Round storage R = rounds[r];
        if (R.status != ST_WINNER) revert NotWinnerRound();
        uint256 stake = _stakeOn(r, user, R.winningSquare);
        if (stake == 0) revert NoStake();
        uint8 f = flags[r][user];
        uint8 nf = f;
        uint256 winnerTotal = R.winnerTotal;

        if (f & F_IMM == 0) {
            nf |= F_IMM;
            uint256 amt = _slice(R.potEth, R.paidEth, stake, R.claimedStakeImm, winnerTotal);
            R.paidEth += uint96(amt);
            ethOut += amt;
            R.claimedStakeImm += uint96(stake);
        }

        if (f & F_POOL == 0) {
            Epoch storage ep = epochs[R.epoch];
            if (ep.state == EP_CONVERTED) {
                nf |= F_POOL;
                uint256 total = (uint256(R.credEth) * ep.rate) / WAD;
                uint256 amt = _slice(total, R.paidPool, stake, R.claimedStakePool, winnerTotal);
                R.paidPool += uint128(amt);
                R.claimedStakePool += uint96(stake);
                if (amt > 0) {
                    _credit(user, amt, ep.index);
                    wsCredited += amt;
                }
            } else if (ep.state == EP_RELEASED) {
                nf |= F_POOL;
                uint256 amt = _slice(R.credEth, R.paidPool, stake, R.claimedStakePool, winnerTotal);
                R.paidPool += uint128(amt);
                R.claimedStakePool += uint96(stake);
                ethOut += amt;
            }
        }
        if (nf == f) revert NothingToClaim();
        flags[r][user] = nf;
    }

    /// @notice Refine the caller's whole wsNET balance: 10% fee on principal, dividends free.
    function withdraw() external nonReentrant {
        _withdrawTo(msg.sender, msg.sender);
    }

    function withdrawTo(address to) external nonReentrant {
        if (to == address(0)) revert BadInput();
        _withdrawTo(msg.sender, to);
    }

    function _withdrawTo(address user, address to) internal {
        (uint256 payout, uint256 fee) = _refine(user);
        if (payout == 0 && fee == 0) revert NothingToDo();
        if (payout > 0) IERC20(WSNET).safeTransfer(to, payout);
    }

    /// @notice Bring an account's dividends up to date. Permissionless and idempotent.
    function checkpoint(address account) external {
        _checkpoint(account);
    }

    // ------------------------------------------------------------------ miner accounting (dividend index)
    function _checkpoint(address u) internal {
        Miner storage m = miners[u];
        uint256 idx = minerIndex;
        uint256 bal = m.bal;
        if (bal > 0 && idx > m.snap) _attribute(m, (bal * (idx - m.snap)) / WAD);
        m.snap = idx;
    }

    function _attribute(Miner storage m, uint256 delta) internal {
        if (delta == 0) return;
        uint256 headroom = totalRefined - totalAttributed;
        if (delta > headroom) delta = headroom;
        if (delta == 0) return;
        m.accrued += uint128(delta);
        totalAttributed += delta;
    }

    /// @dev Credit already-reserved wsNET to a person, backdated to the index stamped when it was reserved.
    function _credit(address u, uint256 amount, uint256 stampIndex) internal {
        _checkpoint(u);
        Miner storage m = miners[u];
        m.bal += uint128(amount);
        reservedWs -= amount;
        uint256 idx = minerIndex;
        if (idx > stampIndex) _attribute(m, (amount * (idx - stampIndex)) / WAD);
    }

    /// @dev Pays principal minus fee plus dividends. The claimer leaves the denominator first; with
    ///      nobody left behind no fee is charged.
    function _refine(address u) internal returns (uint256 payout, uint256 fee) {
        _checkpoint(u);
        Miner storage m = miners[u];
        uint256 bal = m.bal;
        uint256 acc = m.accrued;
        if (bal == 0 && acc == 0) return (0, 0);
        uint256 remaining = totalUnclaimed - bal;
        uint256 inc;
        if (bal > 0 && remaining >= DUST_FLOOR) {
            fee = (bal * _current().claimFeeBps) / BPS;
            inc = (fee * WAD) / remaining;
            if (inc == 0) fee = 0; // too small to share: do not charge, so nothing is stranded
        }
        payout = bal + acc - fee;
        totalUnclaimed = remaining;
        totalRefined = totalRefined - acc + fee;
        totalAttributed -= acc;
        m.bal = 0;
        m.accrued = 0;
        if (inc > 0) minerIndex += inc;
        m.snap = minerIndex;
        emit Withdrawn(u, payout, fee);
    }

    // ------------------------------------------------------------------ escape paths
    function _refundable(uint256 r, Round storage R) internal view returns (bool) {
        return R.status == ST_OPEN && block.timestamp >= beaconUnlock(r) + REFUND_TIMEOUT;
    }

    /// @notice Mark an unresolvable round as skipped so later rounds can resolve.
    function skipRefundable(uint256 r) external {
        Round storage R = rounds[r];
        if (!_refundable(r, R)) revert NotRefundable();
        R.status = ST_SKIPPED;
        emit RoundSkipped(r);
    }

    /// @notice Take back your own stake of a round that could not be resolved in time.
    function refund(uint256 r) external nonReentrant {
        _refund(msg.sender, payable(msg.sender), r);
    }

    /// @notice Same, paid to another address (for wallets that cannot receive ETH).
    function refundTo(address payable to, uint256 r) external nonReentrant {
        if (to == address(0)) revert BadInput();
        _refund(msg.sender, to, r);
    }

    function _refund(address player, address payable to, uint256 r) internal {
        Round storage R = rounds[r];
        if (_refundable(r, R)) {
            R.status = ST_SKIPPED;
            emit RoundSkipped(r);
        } else if (R.status != ST_SKIPPED) {
            revert NotRefundable();
        }
        uint8 f = flags[r][player];
        if (f & F_REFUND != 0) revert Settled();
        uint256 amt = playerTotal[r][player];
        if (amt == 0) revert NoStake();
        flags[r][player] = f | F_REFUND;
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert SendFailed();
        emit Refunded(r, player, amt);
    }

    /// @notice Carry that found no winning round for CARRY_TIMEOUT is released to the rounds that fed it.
    function releaseCarry() external nonReentrant {
        uint256 eth = uint256(carryEth) + carryCredit;
        if (eth == 0) revert NothingToDo();
        if (block.timestamp < uint256(lastEmptyAt) + CARRY_TIMEOUT) revert TooEarly();
        uint32 lp = lastDepositedPlus1;
        if (lp != 0 && rounds[lp - 1].status < ST_WINNER) revert PrevPending();
        chainReleased[carryChain] = true;
        emit CarryReleased(carryChain, eth);
        carryChain++;
        carryEth = 0;
        carryCredit = 0;
    }

    /// @notice Refund your share of an empty round whose carry chain was released.
    function refundEmpty(uint256 r) external nonReentrant {
        _refundEmpty(msg.sender, payable(msg.sender), r);
    }

    function refundEmptyTo(address payable to, uint256 r) external nonReentrant {
        if (to == address(0)) revert BadInput();
        _refundEmpty(msg.sender, to, r);
    }

    function _refundEmpty(address player, address payable to, uint256 r) internal {
        Round storage R = rounds[r];
        if (R.status != ST_EMPTY) revert NotRefundable();
        if (!chainReleased[R.chainId]) revert CarryNotReleased();
        uint8 f = flags[r][player];
        if (f & F_REFUND != 0) revert Settled();
        uint256 pt = playerTotal[r][player];
        if (pt == 0) revert NoStake();
        uint256 total = uint256(R.potEth) + R.credEth;
        uint256 amt;
        if (uint256(R.claimedStakeImm) + pt >= R.totalWager) amt = total - R.paidEth;
        else amt = (total * pt) / R.totalWager;
        R.claimedStakeImm += uint96(pt);
        R.paidEth += uint96(amt);
        flags[r][player] = f | F_REFUND;
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert SendFailed();
        emit Refunded(r, player, amt);
    }

    // ------------------------------------------------------------------ views
    function getRound(uint256 r) external view returns (Round memory) {
        return rounds[r];
    }

    function squareTotals(uint256 r) external view returns (uint96[25] memory) {
        return totalOnSquare[r];
    }

    function playerSquares(uint256 r, address player) external view returns (uint256[25] memory out) {
        Stake[] storage st = stakes[r][player];
        for (uint256 i = 0; i < st.length; i++) {
            for (uint8 s = 0; s < 25; s++) {
                if (st[i].mask & (uint32(1) << s) != 0) out[s] += st[i].amount;
            }
        }
    }

    function stakeOnSquare(uint256 r, address player, uint8 square) external view returns (uint256) {
        return _stakeOn(r, player, square);
    }

    function recordCount(uint256 r, address player) external view returns (uint256) {
        return stakes[r][player].length;
    }

    function minerState(address u) external view returns (uint256 bal, uint256 accrued, uint256 pending) {
        Miner storage m = miners[u];
        uint256 idx = minerIndex;
        uint256 d = (m.bal > 0 && idx > m.snap) ? (uint256(m.bal) * (idx - m.snap)) / WAD : 0;
        uint256 headroom = totalRefined - totalAttributed;
        if (d > headroom) d = headroom;
        return (m.bal, m.accrued, d);
    }

    function currentParams() external view returns (Params memory) {
        return _current();
    }

    function paramsOf(uint256 r) external view returns (Params memory) {
        return paramsList[rounds[r].paramsId];
    }

    function pendingParams() external view returns (Params memory p, uint64 effectiveAt) {
        return (pendingParams_, pendingParamsAt);
    }

    function paramsCount() external view returns (uint256) {
        return paramsList.length;
    }

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    function getEpoch(uint32 idx) external view returns (Epoch memory) {
        return epochs[idx];
    }

    function lastDepositedRound() external view returns (bool exists, uint256 round) {
        uint32 lp = lastDepositedPlus1;
        return (lp != 0, lp == 0 ? 0 : uint256(lp) - 1);
    }

    // ------------------------------------------------------------------ helpers
    function _u96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) revert Bad();
        return uint96(x);
    }

    function _u32(uint256 x) internal pure returns (uint32) {
        if (x >= type(uint32).max) revert Bad();
        return uint32(x);
    }
}
