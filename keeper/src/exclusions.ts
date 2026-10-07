// Addresses that never receive holder rewards (docs/HOLDER_RULES.md). The first block is the verified list used by
// tenten-reward-indexer-v2; the rest are PAR contracts, the pot and the game. Team decision: everyone else is included.
export const EXCLUSIONS: { address: string; label: string }[] = [
  { address: "0xC05ddFbd4f9a46ae297b286D4D6998a0c0Ea27FE", label: "Reward Reserve V2 (mainnet)" },
  { address: "0x313dfCB9E091D33482e75EEFa00E0156b42119b5", label: "Reward Reserve V1 (abandoned)" },
  { address: "0x4fC94FD08Ff44abde7452BB109f1C5ab937ED4e3", label: "TEN Permanent Reserve (accepts TEN only)" },
  { address: "0xC4F021c73A5b6fFae6C43515f0a4BbF615B31c7b", label: "TEN token contract" },
  { address: "0x8366a39CC670B4001A1121B8F6A443A643e40951", label: "Uniswap v4 PoolManager (holds the TEN/NET pool)" },
  { address: "0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231", label: "PairPadLaunchLocker" },
  { address: "0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386", label: "PairPadFeeEscrow" },
  { address: "0x28a5f3F898E99753E322fdce6EFa8b294C215B9b", label: "PairPadDisperseV2" },
  { address: "0xB1a7a3A37F41e4dC9507F9B0F946B7F786c4AFb4", label: "PAR reward distributor" },
  { address: "0x4B79B8298cd890A82dC9De1dE5dBb745Cf04353C", label: "PairPadHolderVault" },
  { address: "0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F", label: "PairPadLaunchFactory" },
  { address: "0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120", label: "PairPadRouter" },
  { address: "0x9D464361766aF710a497f8CFf91c87b56bD17f20", label: "TEN/wsNET Uniswap v2 pair" },
  { address: "0x000000000000000000000000000000000000dEaD", label: "dead address" },
  { address: "0x0000000000000000000000000000000000000000", label: "zero address" },
];

export function exclusionSet(extra: string[] = []): Set<string> {
  return new Set([...EXCLUSIONS.map((e) => e.address), ...extra].map((a) => a.toLowerCase()));
}
