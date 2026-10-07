// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HolderPot
/// @notice Receives the wsNET share meant for holders of TEN v1 (through `donateReward`, the same entry
///         point TEN v2 has) and lets an operator push it to holders once a day, pro rata, off-chain
///         computed. TEN v1 has no on-chain reward engine, so this pot is the one component of the v1
///         setup that is NOT trustless: the operator picks the recipients and the amounts.
/// @dev Only wsNET can be pushed, nothing else can leave, and the operator can be changed (two steps).
///      The rule the operator follows (snapshot of v1 balances, system wallets excluded, minimum payout
///      per holder, amounts below it carried to the next round) is published off-chain; every push
///      carries a `ref` (for example the hash of the published snapshot) so it can be audited.
contract HolderPot is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable WSNET;
    uint256 public constant MAX_PUSH = 250; // recipients per call (about 6.7M gas)

    address public owner; // the Safe: can replace the operator at once (for example if the keeper key is compromised)
    address public pendingOwner;
    address public operator; // the automatic keeper: pushes the daily payments

    event Donated(address indexed from, uint256 amount);
    event Pushed(bytes32 indexed ref, uint256 recipients, uint256 paid, uint256 skipped);
    event OperatorChanged(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOperator();
    error NotOwner();
    error WrongAsset();
    error BadInput();
    error TooMany();

    constructor(address wsnet, address owner_, address operator_) {
        if (wsnet == address(0) || owner_ == address(0) || operator_ == address(0)) revert BadInput();
        if (wsnet.code.length == 0) revert BadInput(); // pushing a token that does not exist would 'pay' nothing
        WSNET = IERC20(wsnet);
        owner = owner_;
        operator = operator_;
        emit OwnershipTransferred(address(0), owner_);
        emit OperatorChanged(address(0), operator_);
    }

    /// @notice Same signature as TEN v2's reward entry point: pulls `amount` of wsNET from the caller.
    function donateReward(address asset, uint256 amount) external nonReentrant {
        if (asset != address(WSNET)) revert WrongAsset();
        uint256 before = WSNET.balanceOf(address(this));
        WSNET.safeTransferFrom(msg.sender, address(this), amount);
        emit Donated(msg.sender, WSNET.balanceOf(address(this)) - before);
    }

    /// @notice Pay holders. A recipient that cannot receive (or a zero amount) is skipped and its amount
    ///         stays in the pot for the next push; the batch never reverts because of one recipient.
    function push(address[] calldata to, uint256[] calldata amounts, bytes32 ref) external nonReentrant {
        if (msg.sender != operator) revert NotOperator();
        uint256 n = to.length;
        if (n != amounts.length) revert BadInput();
        if (n > MAX_PUSH) revert TooMany();
        uint256 paid;
        uint256 skipped;
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] == 0 || to[i] == address(0)) {
                skipped++;
                continue;
            }
            (bool ok, bytes memory ret) =
                address(WSNET).call(abi.encodeCall(IERC20.transfer, (to[i], amounts[i])));
            if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) paid += amounts[i];
            else skipped++;
        }
        emit Pushed(ref, n, paid, skipped);
    }

    /// @notice Replace the operator immediately. Only the owner (the operator cannot replace itself, so a
    ///         compromised keeper key cannot lock the owner out). Setting a new operator does not move funds.
    function setOperator(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert BadInput();
        emit OperatorChanged(operator, next);
        operator = next;
    }

    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = to;
        emit OwnershipTransferStarted(msg.sender, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function balance() external view returns (uint256) {
        return WSNET.balanceOf(address(this));
    }
}
