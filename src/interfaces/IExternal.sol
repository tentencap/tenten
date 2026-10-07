// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice TEN v2 reward engine entry point (permissionless, pulls tokens from the caller).
interface ITen {
    function donateReward(address asset, uint256 amount) external;
}

/// @notice Uniswap SwapRouter02 (no deadline field).
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    function WETH9() external view returns (address);
}

/// @notice The slice of a Uniswap v3 pool the game uses.
interface IUniswapV3PoolMin {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
