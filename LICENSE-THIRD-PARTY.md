# Third-party code and notices

This project adapts code that is published under the MIT licence. The MIT notice is kept here and in the SPDX headers of the adapted files.

1. **SLVR** (https://slvr.fun, contracts on Robinhood Chain: grid lottery `0xa1e5213505772B195FD7AE3b4a6b27B58Cf72A3D`, randomness provider `0x1F3B0992FaBCF77d4df7Baa416b9185e464d58f3`, miner vault `0x2070b4B0c57EaF070CF86cD8321a6054f3D25260`). The verified sources carry `SPDX-License-Identifier: MIT`. Adapted ideas and code: the drand BLS verification flow (`DrandRandomnessProvider`), the packed stake-record ledger (`BettorLib`), the dividend index and checkpoint pattern (`SlvrMinerVault`, `ClaimLib`, `MathLib`). The sources do not name a copyright holder in the files I read (UNVERIFIED), so no holder name is given here.
2. **kevincharm/bls-bn254** (MIT), vendored through SLVR's provider: `src/lib/BLS.sol`, `src/lib/ModExp.sol`. Source: https://github.com/kevincharm/bls-bn254.
3. **OpenZeppelin Contracts** 5.x (MIT), `ReentrancyGuard`.
4. **Uniswap v4-core** (`TickMath`, `FullMath`, MIT) used as a library import.

MIT licence text (applies to the files above):

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
