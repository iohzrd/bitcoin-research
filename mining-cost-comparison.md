# Mining cost and concentration: SHA256 versus the strong data-dependent rule

2026-09-28

Compares hashrate per dollar and its concentration across three cases: SHA256 mining as it
is today, and the strong data-dependent rule (a chain read on every hash) run on a disk-bound
home node versus a memory-resident server. All prices are approximate and market-dependent.
Strong-rule rates are measured with `ddpow-strong` (read-per-hash, k = 8) on a 24-thread
processor and one NVMe drive; the server rate is scaled by core count.

Summary. SHA256 is nearly flat per dollar: an industrial miner is about 2 times a home device
per dollar across a 242 times hashrate span. The strong rule concentrates far more steeply
today, about 280 to 400 times per dollar at a memory-price threshold near $6,000, but that
advantage is self-limiting: it decays toward about 13 times as the chain grows, and mining
converges on cheap disk hardware.

## 1. SHA256 world (real hardware)

| miner | hashrate | power | price | efficiency | price per TH/s |
| --- | --- | --- | --- | --- | --- |
| NerdQAxe++ (home solo) | 4.8 TH/s | 72 W | $239 | 15 J/TH | $49.8 |
| Antminer S23 Hydro 3U (industrial) | 1,160 TH/s | 11,020 W | $28,599 | 9.5 J/TH | $24.7 |

The industrial machine is 242 times the hashrate for 120 times the price, so about 2 times
better per dollar and 1.6 times more power-efficient. That is the whole advantage of
industrial scale in SHA256. Scaling is close to linear per dollar.

Network scale (approximate, about 800 EH/s):

| | rate | hardware cost | power |
| --- | --- | --- | --- |
| whole network | ~800 EH/s | ~$16B, ~4 million miners | ~14 GW |
| one large pool (~25%) | ~200 EH/s | ~$4B in members' hardware | ~3.5 GW |

A pool does not own the hashrate; it coordinates hardware other people bought. A large pool
is about 1 to 2 million times a single average rig, but that is aggregation, not a single
machine.

## 2. Strong-rule world (measured)

The strong rule reads a chunk of the chain on every hash, so mining rate is bounded by
read throughput over a held copy of the chain, not by hash rate.

| regime | k = 8 attempts/s | bound by |
| --- | --- | --- |
| pure hash, no reads | 1.0e8 | the hasher (ceiling) |
| chain in memory | 1.6e7 (24-thread), ~4e7 (server) | the hasher |
| chain on NVMe (O_DIRECT) | 2.0e4 | the disk |

| miner | rate | power | price |
| --- | --- | --- | --- |
| home node (chain on NVMe) | 2e4 /s | ~100 W | ~$1,000 |
| server, 1 TB memory (chain in RAM) | 4e7 /s | ~500 W | ~$6,000 (DDR4, current) |

The server does 2,000 times the rate for about 6 times the cost: about 330 to 400 times
better per dollar, and about 400 times per watt.

## 3. Memory prices (early 2026)

Memory prices surged as demand for high-bandwidth memory in AI accelerators pulled capacity
away from server memory.

| module | price each | per GB |
| --- | --- | --- |
| DDR4 ECC registered, 64 GB | ~$295 to $499 | ~$5 to $8 |
| DDR5 ECC registered, 64 GB | ~$1,200 to $2,300 | ~$19 to $36 |

DDR4 rose roughly 60 to 80 percent and DDR5 roughly 100 to 400 percent between early 2025 and
early 2026. NVMe solid-state disk is about $0.03 to $0.05 per GB, roughly 150 times cheaper
per GB than DDR4.

Server to hold the chain in memory:

| memory | 1 TB | 2 TB |
| --- | --- | --- |
| DDR4 (value path) | ~$6,000 to $9,000 | ~$10,000 to $17,000 |
| DDR5 (current-gen) | ~$22,000 to $42,000 | ~$40,000 to $75,000 |

## 4. Concentration per dollar

| comparison | rate ratio | cost ratio | per-dollar advantage |
| --- | --- | --- | --- |
| SHA256: industrial over home | 242x | 120x | ~2x |
| strong rule: memory server over disk home (DDR4) | 2,000x | ~6x | ~330x |
| strong rule: memory server over disk home (DDR5) | 2,000x | ~30x | ~65x |

The strong rule concentrates roughly 150 to 200 times more steeply per dollar than SHA256,
even measuring SHA256 across its full range from a $239 device to a $28,599 unit. The memory
price surge reduced this advantage (from about 800 times at old memory prices to about 330
times now), because holding the chain in memory now costs real money.

## 5. The advantage does not increase above server grade

The advantage is a single step at the memory threshold, then flat:

- A single server is hash-bound or memory-bandwidth-bound near 1e8 attempts per second, no
  matter how much is spent on that one box.
- Scaling past one server means buying more servers, each holding its own full copy at
  ~$6,000 to $9,000. That is linear, the same shape as buying more SHA256 miners.
- The fastest memory (high-bandwidth memory on accelerators) holds about 80 GB per unit, so
  holding the 700 GB chain in it needs about nine units at over $250,000 for maybe 10 times
  the bandwidth. Nobody does this.

So below the threshold (disk) a miner is far behind; at or above it (chain in memory) miners
are roughly equal per dollar, and scaling further is linear.

## 6. The chain grows, so the memory advantage decays

The chain runs about 446 blocks per day, roughly 150 to 325 GB per year. As it grows, the
cost of both machines becomes dominated by storage, and memory costs about 150 times more per
GB than NVMe. So the cost ratio climbs and the per-dollar advantage of memory falls (rate
ratio held at 2,000, memory at $6 per GB, NVMe at $0.04 per GB, $1,000 base):

| chain size | memory server | NVMe home node | cost ratio | memory per-dollar advantage |
| --- | --- | --- | --- | --- |
| 0.7 TB (now) | ~$5,200 | ~$1,030 | 5x | 395x |
| 1.5 TB | ~$10,000 | ~$1,060 | 9x | 212x |
| 3 TB | ~$19,000 | ~$1,120 | 17x | 118x |
| 5 TB | ~$31,000 | ~$1,200 | 26x | 77x |
| 10 TB | ~$61,000 | ~$1,400 | 44x | 46x |
| 30 TB | ~$181,000 | ~$2,200 | 82x | 24x |
| asymptote | storage-dominated | | ~150x | ~13x |

Two opposing trends: the absolute cost to hold the chain in memory rises steeply, and the
per-dollar edge of memory over disk falls just as steeply. The net is that over time the
rational miner increasingly picks NVMe, the memory premium stops being worth it, and the NVMe
home node stays cheap and accessible the whole way (about $2,200 even at 30 TB). So the
long-run equilibrium drifts toward most miners on disk, roughly equal per dollar, with memory
giving a shrinking edge worthwhile only for the well-capitalized. The strong rule's
concentration is therefore self-limiting.

NVMe random-read performance has also improved faster than memory random-access latency
(newer PCIe generations, higher input-output operations per second, io_uring). If that
continues the 2,000 times rate ratio shrinks too, favoring disk further.

## Comparison across the three designs

| property | SHA256 | weak data-dependent rule | strong data-dependent rule |
| --- | --- | --- | --- |
| cost depends on chain size | no | disk only (cheap) | memory (expensive, then decays) |
| per-dollar concentration | ~2x (flat) | binds the checker, not hashers | ~330x now, ~13x asymptote |
| forces every miner to hold a node | no | no (binds the checker) | yes |
| obsoletes current ASICs | no | no | yes (throttled to read rate) |

## Sources

- Antminer S23 Hydro 3U: https://www.cryptominerbros.com/product/bitmain-antminer-s23-hydro-3u-bitcoin-miner/
- NerdQAxe++: https://www.cryptominerbros.com/product/nerdminer-nerdqaxe-plus-plus-bitcoin-miner/
- DDR4 server memory prices: https://datacenterdisk.com/server-ram/ddr4 ; https://www.aventissystems.com/64gb-1-x-64gb-ddr4-ecc-rdimm-server-memory/
- DDR5 server memory prices and the supply crunch: https://memory.net/memory-prices/ ; https://electronics.alibaba.com/buyingguides/server-ram-price-guide-what-you-actually-pay-in-2026
- Refurbished DDR4 price trend: https://pcserverandparts.com/news/refurbished-ddr4-server-memory-2026-server-ram-price-crisis/
- Strong-rule rates: `ddpow-strong/` in this repository.
