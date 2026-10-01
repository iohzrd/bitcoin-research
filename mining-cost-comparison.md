# Mining cost and concentration: SHA256 versus the strong data-dependent rule

2026-09-30

Compares hashrate per dollar and its concentration across three cases: SHA256 mining as it
is today, and the strong data-dependent rule (a chain read on every hash) run on a disk-bound
home node versus a memory-resident server. All prices are approximate and market-dependent.
Strong-rule rates are measured with `ddpow-strong` (read-per-hash, k = 8) on a desktop
(Ryzen 9 5950X, 32 threads, Samsung 980 PRO); server rates are extrapolated from it by core
count and clock. The RAM measurements use datasets of 4 and 24 GiB, not the full chain.

Summary. SHA256 hashrate per dollar is nearly constant across hardware sizes: an industrial
miner is about 2 times a home device per dollar across a 242 times hashrate span. Under the
strong rule a 1 TB DDR4 server is about 160 times a home node's rate for about 6 to 8 times its
price: about 20 to 25 times better per dollar. The advantage falls as the chain grows, because
memory costs about 62 times more per GB than NVMe: to about 10 times at 3 TB and toward about
2.6 times as storage dominates both machines' cost. How fast depends on the growth rate: 3 TB is
about 26 years away at the SHA256 chain's historical 84 GB per year, and about 150 to 450 years
at this chain's post-fork 5 to 15 GB per year.

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

## 2. Strong-rule mining (measured and extrapolated)

The strong rule reads a chunk of the chain on every hash, so mining rate is bounded by
read throughput over a stored copy of the chain, not by hash rate.

| regime | k = 8 attempts/s | bound by |
| --- | --- | --- |
| pure hash, no reads (desktop) | 1.20e8 | the hasher (ceiling) |
| chain in memory (desktop, 24 GiB) | 9.8e6 | hashing (9 per attempt) and read latency |
| chain in memory (56-core DDR4 server) | ~2.4e7 (extrapolated) | hashing |
| chain on NVMe (980 PRO, O_DIRECT) | 5.7e4 at queue depth 24, 1.5e5 at 384 | the disk |

A desktop cannot hold the chain in its memory, so a home node mines from NVMe.

| miner | rate | power | price |
| --- | --- | --- | --- |
| home node (chain on NVMe) | 1.5e5 /s | ~100 W | ~$1,000 |
| server, 1 TB DDR4 (chain in RAM) | ~2.4e7 /s | ~500 W | ~$7,800 |

The server does about 160 times the rate (about 420 times against the drive at queue depth 24)
for about 7.8 times the cost: about 20 times better per dollar, and about 32 times per watt.

## 3. Memory and storage prices (September 2026)

Memory prices rose because manufacturers moved production capacity from server memory to
high-bandwidth memory, driven by demand from artificial intelligence accelerators.

| part | price | per GB |
| --- | --- | --- |
| DDR4 registered error-correcting, 128 GB, refurbished | ~$789 | ~$6.2 |
| DDR5 registered error-correcting | ~$3,800 per 128 GB (used) to $37.31/GB (median) | ~$30 to $37 |
| NVMe, 1 TB Gen4 | ~$157 | ~$0.10 to $0.16 |

DDR4 costs about 40 to 62 times more per GB than NVMe.

Server to hold the chain in memory (1 TB): DDR4 about $7,800 (EPYC 7663 and board $1,450, 8 x
128 GB); DDR5 about $33,000 to $40,000 (EPYC 9654 and board about $2,300).

## 4. Concentration per dollar

| comparison | rate ratio | cost ratio | per-dollar advantage |
| --- | --- | --- | --- |
| SHA256: industrial over home | 242x | 120x | ~2x |
| strong rule: DDR4 server over disk home | ~160x (420x at queue depth 24) | ~7.8x | ~20x (50x) |
| strong rule: DDR5 server over disk home | ~290x | ~33 to 40x | ~7 to 9x |

The strong rule's per-dollar advantage for the larger miner is about 10 times that of SHA256
(about 20 times versus 2 times).

## 5. The advantage does not increase above server grade

The advantage increases once, at the memory threshold, then stays constant:

- A single CPU server is limited by BLAKE2b throughput, about 2e7 to 1e8 attempts per second
  depending on core count and whether several attempts are hashed per vector instruction.
- Scaling past one server means buying more servers, each holding its own full copy. Cost
  grows linearly, as with buying more SHA256 miners.
- An 8-GPU H200 node (8 x 141 GB of high-bandwidth memory) holds the chain. Its estimated rate,
  1.5e9 to 5e9 attempts per second, is limited by GPU hashing and NVLink; at $240,000 to
  $320,000 in GPUs alone it is about equal to DDR4 servers per dollar. It matters for renting
  (a majority attack for hours), not for buying.

So below the threshold (disk) a miner has a lower rate per dollar; at or above it (chain in
memory) miners are roughly equal per dollar, and scaling further is linear.

## 6. Chain growth reduces the advantage

As the chain grows, the cost of both machines becomes storage-dominated, and because memory
costs about 62 times more per GB than NVMe, the per-dollar advantage falls toward the rate
ratio divided by that price ratio. Model: server $1,450 + $6.2/GB, home $900 + $0.10/GB, rates
unchanged.

| chain and tree size | server | home | per-dollar advantage | years at 84 GB/yr | years at 5 to 15 GB/yr |
| --- | --- | --- | --- | --- | --- |
| 773 GB (now) | $6,243 | $977 | ~25x | 0 | 0 |
| 1.5 TB | $10,750 | $1,050 | ~16x | ~9 | ~48 to 145 |
| 3 TB | $20,050 | $1,200 | ~10x | ~26 | ~150 to 450 |
| 10 TB | $63,450 | $1,900 | ~5x | ~110 | ~615 to 1,850 |
| asymptote | storage-dominated | | ~2.6x | | |

Growth rates, sampled on the node: 84 GB per year on the SHA256 chain in the year before the
fork (every 200th block); 96,273 bytes per block since the fork (every 20th block), which is
5.1 GB per year at 600-second spacing and 15.1 GB per year at the measured 429 blocks per day.
The earlier figure of 8 GB per year matched neither. NVMe random-read rates improving faster
than memory latency would also reduce the advantage.

## Comparison across the three designs

| property | SHA256 | weak data-dependent rule | strong data-dependent rule |
| --- | --- | --- | --- |
| cost depends on chain size | no | disk only (cheap) | memory (expensive) or disk |
| per-dollar concentration | ~2x (constant) | binds the checker, not hashers | ~20x, falling as the chain grows |
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
- 1 TB DDR4 server parts: https://www.ebay.com/itm/128018989540 ;
  https://www.ebay.com/b/PC4-25600-DDR4-3200-Bus-Speed-DDR4-SDRAM-Memory-RAM/170083/bn_7113648873
- DDR5 server parts: https://www.ebay.com/itm/186576183619 ; https://datacenterdisk.com/server-ram/ddr5
- NVMe prices: https://cheapestssd.com/1tb-nvme-ssd/
- Strong-rule rates: `ddpow-strong/` in this repository (desktop measurements, 2026-09-30).
