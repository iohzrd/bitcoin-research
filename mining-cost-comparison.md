# Mining cost and concentration: SHA256 versus the strong data-dependent rule

2026-10-01

Compares hashrate per dollar and its concentration across three cases: SHA256 mining as it
is today, and the strong data-dependent rule (a chain read on every hash) run on a disk-bound
home node versus a memory-resident server. All prices are approximate and market-dependent.
Strong-rule rates are for the specification's 4,096-byte chunks, each hashed whole (265
BLAKE2b compressions per attempt at k = 8), measured with `ddpow-strong` on a desktop (Ryzen 9
5950X, 32 threads, Samsung 980 PRO) and an AMD Radeon RX 9070 XT (`ddpow-strong/README.md`).
Server rates are extrapolated from the desktop by core count and clock. The RAM measurements
use 12 GiB datasets, not the full chain.

Summary. SHA256 hashrate per dollar is nearly constant across hardware sizes: an industrial
miner is about 2 times a home device per dollar across a 242 times hashrate span. Under the
strong rule with 4,096-byte chunks, hashing limits a memory-resident miner, so holding the
chain in memory buys little: a 1 TB DDR4 server is about 9 times a home node's rate for about
7.8 times its price, about 1.2 times per dollar (about 20 times with 64-byte chunks). A DDR5
server is worse per dollar than a home node. As the chain grows, memory's cost per GB (about 62
times NVMe's) makes the server worse per dollar than a disk node from about 1.4 TB on.

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

The strong rule reads a 4,096-byte chunk of the chain on every step and hashes it whole, so a
miner is limited by the slower of read throughput over its copy and BLAKE2b throughput.

| regime | k = 8 attempts/s | bound by |
| --- | --- | --- |
| chain on NVMe (980 PRO, O_DIRECT, 384 threads) | 1.5e5 (measured at 64 bytes; a drive reads one 4 KiB page per read at either size) | the drive |
| chain in RAM (desktop, 12 GiB) | 5.6e5 | hashing |
| chain in RAM (56-core DDR4 server) | ~1.4e6 (extrapolated; memory allows ~3.7e6) | hashing |
| GPU reading host RAM over PCIe Gen4 x16 (RX 9070 XT) | 9.5e5 | PCIe |
| GPU, data in its own memory (12 GiB; cannot hold the chain) | 1.16e7 | hashing |

A desktop cannot hold the chain in its memory, so a home node mines from NVMe.

| miner | rate | power | price |
| --- | --- | --- | --- |
| home node (chain on NVMe) | 1.5e5 /s | ~100 W | ~$1,000 |
| server, 1 TB DDR4 (chain in RAM) | ~1.4e6 /s | ~500 W | ~$7,800 |

The server does about 9.2 times the rate for about 7.8 times the cost: about 1.2 times better
per dollar, and about 1.8 times per watt.

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
| strong rule: DDR4 server over disk home | ~9.2x | ~7.8x | ~1.2x |
| strong rule: DDR5 server (96 cores, ~2.5e6 /s) over disk home | ~17x | ~33 to 40x | ~0.4 to 0.5x |

With 4,096-byte chunks the strong rule's per-dollar advantage for the larger miner is below
SHA256's.

## 5. The advantage does not increase above server grade

- A CPU server is limited by BLAKE2b throughput: about 1.5e8 compressions per second per 16
  desktop cores, 265 per attempt.
- Scaling past one server means buying more servers, each holding its own full copy. Cost
  grows linearly, as with buying more SHA256 miners.
- A GPU adds hashing, but a consumer card's memory cannot hold the chain, and reading host
  memory over PCIe Gen4 x16 caps it at about 9.5e5 attempts per second per card.
- An 8-GPU H200 node (8 x 141 GB) holds the chain. Assuming it compresses BLAKE2b at the RX 9070
  XT's measured 3.99e9 per second per GPU at the same 77% efficiency (not measured on an H200),
  it is limited by hashing at about 9.3e7 attempts per second, about 67 times a DDR4 server. At
  $240,000 to $320,000 in GPUs alone that is about 290 to 390 attempts per second per dollar,
  against about 180 for the DDR4 server and 150 for the home node. It is 3.2 times the reset
  rate of 2.86e7, which matters for renting (a majority attack for hours).

## 6. Chain growth reduces the server's advantage

As the chain grows, the cost of both machines becomes storage-dominated, and because memory
costs about 62 times more per GB than NVMe, the per-dollar advantage falls toward the rate
ratio divided by that price ratio. Model: server $1,450 + $6.2/GB, home $900 + $0.10/GB, rates
unchanged.

| chain and tree size | server | home | server per-dollar advantage | years at 84 GB/yr | years at 5 to 15 GB/yr |
| --- | --- | --- | --- | --- | --- |
| 773 GB (now) | $6,243 | $977 | ~1.45x | 0 | 0 |
| 1.5 TB | $10,750 | $1,050 | ~0.9x | ~9 | ~48 to 145 |
| 3 TB | $20,050 | $1,200 | ~0.55x | ~26 | ~150 to 450 |
| 10 TB | $63,450 | $1,900 | ~0.28x | ~110 | ~615 to 1,850 |
| asymptote | storage-dominated | | ~0.15x | | |

Growth rates, sampled on the node: 84 GB per year on the SHA256 chain in the year before the
fork (every 200th block); 96,273 bytes per block since the fork (every 20th block), which is
5.1 GB per year at 600-second spacing and 15.1 GB per year at the measured 429 blocks per day.

## Comparison across the three designs

| property | SHA256 | weak data-dependent rule | strong data-dependent rule (4,096-byte chunks) |
| --- | --- | --- | --- |
| cost depends on chain size | no | disk only (cheap) | yes, disk or memory |
| per-dollar concentration | ~2x (constant) | binds the checker, not hashers | ~1.2x now; memory falls behind disk as the chain grows |
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
