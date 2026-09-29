# Mining cost and concentration: SHA256 versus the strong data-dependent rule

2026-09-28

Compares hashrate per dollar and its concentration across three cases: SHA256 mining as it
is today, and the strong data-dependent rule (a chain read on every hash) run on a disk-bound
home node versus a memory-resident server. All prices are approximate and market-dependent.
Strong-rule rates are measured with `ddpow-strong` (read-per-hash, k = 8) on a 24-thread
processor and one NVMe drive; the server rate is scaled by core count. Consumer NVMe
random-read rate varies widely with queue depth and drive state (about 1e4 to 7e4 attempts
per second at k = 8 measured here), so disk figures are ranges.

Summary. SHA256 hashrate per dollar is nearly constant across hardware sizes: an industrial
miner is about 2 times a home device per dollar across a 242 times hashrate span. Under the
strong rule the per-dollar advantage of the larger miner is far higher, about 250 times per
dollar (roughly 100 to 700 times, disk rate varies) at a memory-price threshold near $6,000.
This advantage persists: at the measured chain growth of about 8 GB per year the chain would
take about a century to reach 1.5 TB, so the memory advantage stays near 250 times for
decades. It decreases only over centuries, or sooner if the block size increases greatly.

## 1. SHA256 mining (real hardware)

| miner | hashrate | power | price | efficiency | price per TH/s |
| --- | --- | --- | --- | --- | --- |
| NerdQAxe++ (home solo) | 4.8 TH/s | 72 W | $239 | 15 J/TH | $49.8 |
| Antminer S23 Hydro 3U (industrial) | 1,160 TH/s | 11,020 W | $28,599 | 9.5 J/TH | $24.7 |

The industrial machine is 242 times the hashrate for 120 times the price, so about 2 times
better per dollar and 1.6 times more power-efficient. That is the whole advantage of
industrial scale in SHA256. Hashrate scales close to linearly with cost.

Network scale (approximate, about 800 EH/s):

| | rate | hardware cost | power |
| --- | --- | --- | --- |
| whole network | ~800 EH/s | ~$16B, ~4 million miners | ~14 GW |
| one large pool (~25%) | ~200 EH/s | ~$4B in members' hardware | ~3.5 GW |

A pool does not own the hashrate; it coordinates hardware other people bought. A large pool is
about 1 to 2 million times a single average mining device, but that is aggregation, not a
single machine.

## 2. Strong-rule mining (measured)

The strong rule reads a chunk of the chain on every hash, so mining rate is bounded by
read throughput over a stored copy of the chain, not by hash rate.

| regime | k = 8 attempts/s | bound by |
| --- | --- | --- |
| pure hash, no reads | 1.0e8 | the hasher (ceiling) |
| chain in memory | 1.6e7 (24-thread), ~4e7 (server) | the hasher |
| chain on NVMe (O_DIRECT) | ~3e4 (1e4 to 7e4) | the disk |

| miner | rate | power | price |
| --- | --- | --- | --- |
| home node (chain on NVMe) | ~3e4 /s | ~100 W | ~$1,000 |
| server, 1 TB memory (chain in RAM) | 4e7 /s | ~500 W | ~$6,000 (DDR4, current) |

The server does about 1,300 times the rate (disk rate varies, so 600 to 4,000 times) for
about 6 times the cost: about 250 times better per dollar (roughly 100 to 700 times), and
about 270 times per watt.

## 3. Memory prices (early 2026)

Memory prices rose because manufacturers moved production capacity from server memory to
high-bandwidth memory, driven by demand from artificial intelligence accelerators.

| module | price each | per GB |
| --- | --- | --- |
| DDR4 registered error-correcting, 64 GB | ~$295 to $499 | ~$5 to $8 |
| DDR5 registered error-correcting, 64 GB | ~$1,200 to $2,300 | ~$19 to $36 |

DDR4 rose roughly 60 to 80 percent and DDR5 roughly 100 to 400 percent between early 2025 and
early 2026. NVMe solid-state disk is about $0.03 to $0.05 per GB, roughly 150 times cheaper
per GB than DDR4.

Server to hold the chain in memory:

| memory | 1 TB | 2 TB |
| --- | --- | --- |
| DDR4 (lower-cost option) | ~$6,000 to $9,000 | ~$10,000 to $17,000 |
| DDR5 (current generation) | ~$22,000 to $42,000 | ~$40,000 to $75,000 |

## 4. Concentration per dollar

| comparison | rate ratio | cost ratio | per-dollar advantage |
| --- | --- | --- | --- |
| SHA256: industrial over home | 242x | 120x | ~2x |
| strong rule: memory server over disk home (DDR4) | ~1,300x (600 to 4,000) | ~6x | ~250x (100 to 700) |
| strong rule: memory server over disk home (DDR5) | ~1,300x | ~30x | ~45x |

The strong rule's per-dollar advantage for the larger miner is roughly 100 times that of
SHA256 (about 250 times versus 2 times), even measuring SHA256 across its full range from a
$239 device to a $28,599 unit. The memory price increase reduced this advantage (from about
800 times at old memory prices to about 250 times now), because holding the chain in memory
now has a substantial cost.

## 5. The advantage does not increase above server grade

The advantage increases once, at the memory threshold, then stays constant:

- A single server is hash-bound or memory-bandwidth-bound near 1e8 attempts per second,
  regardless of how much is spent on that one server.
- Scaling past one server means buying more servers, each holding its own full copy at
  ~$6,000 to $9,000. Cost grows linearly, as with buying more SHA256 miners.
- The fastest memory (high-bandwidth memory on accelerators) holds about 80 GB per unit, so
  holding the 700 GB chain in it needs about nine units at over $250,000 for an estimated 10
  times the bandwidth. Nobody does this.

So below the threshold (disk) a miner has a far lower rate per dollar; at or above it (chain
in memory) miners are roughly equal per dollar, and scaling further is linear.

## 6. The chain grows too slowly to reduce the advantage

Measured at height 974,588: about 174 blocks per day at about 130 KB per block, so the chain
grows about 8 GB per year, not the 150 to 325 GB per year assumed in an earlier draft. As the
chain grows the cost of both machines becomes storage-dominated, and because memory costs
about 150 times more per GB than NVMe, the per-dollar advantage of memory falls toward
rate-ratio over 150. But at 8 GB per year that decrease takes centuries:

| chain size | years to reach at 8 GB/yr | memory per-dollar advantage |
| --- | --- | --- |
| 0.7 TB (now) | 0 | ~250x |
| 1.5 TB | ~100 | ~140x |
| 3 TB | ~290 | ~80x |
| 10 TB | ~1,160 | ~30x |
| asymptote | storage-dominated | ~9x |

The earlier conclusion that this advantage is self-limiting was wrong at the real growth rate.
For any planning period of decades the chain stays near 0.7 to 1 TB, so the memory advantage
stays near 250 times. It decreases substantially only over centuries, or sooner if the block
size increases greatly, since larger blocks are the only way the chain grows fast enough to
reduce it substantially. NVMe random-read performance improving faster than memory
random-access latency would also reduce the advantage over time, but that is a slow, uncertain
trend, not a near-term effect.

## Comparison across the three designs

| property | SHA256 | weak data-dependent rule | strong data-dependent rule |
| --- | --- | --- | --- |
| cost depends on chain size | no | disk only (cheap) | memory (expensive; stable at 8 GB/yr growth) |
| per-dollar concentration | ~2x (constant) | binds the checker, not hashers | ~250x, persists at measured growth |
| forces every miner to hold a node | no | no (binds the checker) | yes |
| obsoletes current ASICs | no | no | yes (throttled to read rate) |

## Sources

- Antminer S23 Hydro 3U:
  https://www.cryptominerbros.com/product/bitmain-antminer-s23-hydro-3u-bitcoin-miner/
- NerdQAxe++:
  https://www.cryptominerbros.com/product/nerdminer-nerdqaxe-plus-plus-bitcoin-miner/
- DDR4 server memory prices: https://datacenterdisk.com/server-ram/ddr4 ;
  https://www.aventissystems.com/64gb-1-x-64gb-ddr4-ecc-rdimm-server-memory/
- DDR5 server memory prices and the supply shortage: https://memory.net/memory-prices/ ;
  https://electronics.alibaba.com/buyingguides/server-ram-price-guide-what-you-actually-pay-in-2026
- Refurbished DDR4 price trend:
  https://pcserverandparts.com/news/refurbished-ddr4-server-memory-2026-server-ram-price-crisis/
- Strong-rule rates: `ddpow-strong/` in this repository.
