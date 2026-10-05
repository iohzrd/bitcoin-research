# ddpow-strong: read-per-hash proof of work, software prototype

Tests whether the strong data-dependent rule (a chain read on every hash, not only on the
rare reported candidate) is implementable and what bounds it, without an FPGA. It is.

## The rule

Per attempt on header `hdr`, nonce `n`, over `N` chunks whose last `N - S` are the parent's:

```
x_0   = h0 = BLAKE2b-256(hdr || n)
a_0   = S + idx(x_0, N - S)                      parent block
x_i   = BLAKE2b-256(x_{i-1} || chunk(a_{i-1}))   i = 1..k-1
a_i   = idx(x_i, N)                              whole chain
final = BLAKE2b-256(x_{k-1} || chunk(a_{k-1}))
idx(x, n) = u64le(x[0..8]) mod n
solution if final meets target
```

(In the consensus rule `h0` is the version 2 header's stage-3 BLAKE2b digest, the chip's
output; the prototype uses a single BLAKE2b over an 80-byte header to measure the read path.)

The reads are inside the per-nonce loop, so every hash requires reads. Each position after the
first is derived from the previous chunk, so whether a miner holds an attempt's chunks is known
only after the reads are performed. A solution carries a Merkle mountain range proof of its
reads (leaf = BLAKE2b(0x00||chunk), node = BLAKE2b(0x01||l||r), commitment
BLAKE2b(0x02||N||S||bag(peaks))), checkable without the dataset. `prove` builds it and verifies:
8 reads over a 256 KiB dataset = a 3.6 KB proof, VALID with no dataset held.

## Why the reads are chained

The superseded rule derived every position from `h0` alone. A miner holding a fraction `f` of
the chain then computes `h0`, checks all positions, and reads only if every chunk is held. Its
extra cost is `1/f^(k-1)` `h0` hashes per completed attempt; its reads per completed attempt
equal a full holder's. Reads bound mining, so with a fast hasher a partial holder mines at a
full holder's rate: at 4.5 TH/s and k = 8, holding 7% of the chain gives the rate of a full copy
on NVMe, 15% the rate of a full copy in DRAM.

With chained reads, a miner that finds a missing chunk at read `i` has already performed the
reads before it. Only
`a_1` (from `h0` and a cached parent chunk) is known before any storage read, so storage reads
per completed attempt are `(1 + f + ... + f^(k-2)) / f^(k-2)` against `k - 1` for a full holder.

`partial` measures both rules (1 GiB dataset, k = 8, pseudo-random held subset, 5 s per row;
storage reads exclude the parent, which is cached):

| held | independent: h0 / completed | independent: reads / completed | chained: reads / completed | chained vs full holder |
| --- | --- | --- | --- | --- |
| 1.00 | 1.0 | 7.0 | 7.0 | 1.00x |
| 0.99 | 1.07 | 7.0 | 7.2 | 1.03x |
| 0.90 | 2.09 | 7.0 | 9.8 | 1.40x |
| 0.75 | 7.48 | 7.0 | 19.4 | 2.77x |
| 0.50 | 128 | 6.9 | 126 | 18x |
| 0.146 | 7.4e5 | 6.8 | 1.24e5 | 17,700x |

Under the independent rule the partial holder's extra cost is only `h0` hashes. Under the
chained rule its extra cost is reads, the resource that bounds mining.

`--layout prefix` (hold a prefix of the chain) shows a second defect of the independent rule:
reads `i` and `i + 4` shared a word of `h0`, so their positions differ by one of two fixed
offsets. At `f = 0.5` a prefix holder needed 38 `h0` per completed attempt instead of 128.
Chained positions each come from a distinct digest; both layouts give the same chained rows.

## Measured (desktop: Ryzen 9 5950X, 32 threads, 62 GiB RAM, Samsung 980 PRO 2 TB; transparent huge pages `always`; rustc 1.96.0; 2026-09-30; chained rule, k = 8)

| regime | dataset | threads | effective attempts/s | reads/s | bound by |
| --- | --- | --- | --- | --- | --- |
| pure hash, no reads | - | 32 | 1.20e8 | - | the hasher |
| RAM-resident chain | 4 GiB, 10 s | 32 | 1.070e7 | 8.56e7 | hashing (9 per attempt; cap 1.33e7) and one read in flight per thread |
| RAM-resident chain | 24 GiB, 20 s | 32 | 9.815e6 | 7.85e7 | as above; 8% below 4 GiB (page-table walks) |
| NVMe, O_DIRECT | 64 GiB file | 24 | 5.68e4 | 3.98e5 | the disk, queue depth 24 |
| NVMe, O_DIRECT | 64 GiB file | 96 | 1.21e5 | 8.49e5 | the disk, queue depth 96 |
| NVMe, O_DIRECT | 64 GiB file | 192 | 1.43e5 | 9.99e5 | the disk, queue depth 192 |
| NVMe, O_DIRECT | 64 GiB file | 384 | 1.50e5 | 1.05e6 | the disk (rated about 1e6 random 4 KiB reads/s) |

The RAM rate is 74% of the hashing cap and 65 times the drive's rate at full queue depth. The
RAM rows are for datasets far below the chain's size; a 1 TB dataset adds more page-table walks.
The rows above ran with the memory at its default timings (XMP off).

With XMP on (2026-10-01, same machine, 64-byte reads, 32 threads):

| run | before | XMP on | change |
| --- | --- | --- | --- |
| pure hash, no reads | 1.20e8 | 1.23e8 | +3% |
| RAM, 4 GiB, 10 s | 1.070e7 | 1.211e7 (9.69e7 reads/s) | +13% |
| RAM, 24 GiB, 20 s | 9.815e6 | 1.170e7 (9.36e7 reads/s) | +19% |
| RAM, 24 GiB, 20 s, 8 lanes | - | 1.270e7 (1.016e8 reads/s) | - |
| RAM, 24 GiB, 20 s, 8 lanes, `--nohash 1` | - | 4.157e7 (3.33e8 reads/s, 21.3 GB/s) | - |

Hashing limits these runs: the 8-lane rate is 93% of the hashing cap (1.23e8 / 9), and memory
alone serves 3.3 times it. The 4 GiB to 24 GiB gap fell from 8% to 3.4%. RAM is 78 times the
drive's rate at 24 GiB, 85 times with 8 lanes.

## Measured at 4 KiB, CPU and GPU (desktop as above, rustc 1.99.0; GPU: AMD Radeon RX 9070 XT, 64 compute units, 15.92 GiB GDDR6 rated 640 GB/s, PCIe Gen4 x16 at the CPU root port, ROCm/HIP 7.2.4; 2026-10-01; chained rule, k = 8)

4,096-byte reads, each hashed whole: 33 compressions per step, 265 per attempt. GPU code:
`gpu/` (HIP; every run's sampled attempts, 128 of 128, match Python `hashlib.blake2b`). 12 GiB
datasets, 12 s GPU runs.

| miner | attempts/s | reads/s | GB/s | power | bound by |
| --- | --- | --- | --- | --- | --- |
| GPU hashing ceiling (4,128-byte step, 3.99e9 compressions/s) | 1.51e7 | - | - | 303 W | compute, at the 304 W power cap |
| GPU, data in GPU memory | 1.157e7 | 9.25e7 | 379 | 298 W | hashing (77% of the ceiling) |
| GPU, data in pinned host memory, over PCIe | 9.49e5 | 7.60e6 | 31.1 | 130 W | PCIe (about 27.2 GB/s crosses the link, 96%; parent reads hit GPU cache) |
| CPU, RAM, hashed (32 threads, 8 lanes) | 5.646e5 | 4.516e6 | 18.5 | - | hashing (1.50e8 compressions/s) |
| CPU, RAM, folded (`--nohash 1`) | 9.181e5 | 7.345e6 | 30.1 | - | memory |

- With XMP on (24 GiB, 8 lanes, 20 s): hashed 5.573e5 attempts/s (18.3 GB/s), unchanged
  within noise (1.48e8 compressions/s); folded 1.244e6 attempts/s (9.95e6 reads/s, 40.8 GB/s),
  36% above the row above, which by that gain probably ran with XMP off (not recorded). Memory
  alone serves 2.2 times the hashed rate.
- The GPU with data in its own memory is 20.5 times the CPU in RAM (35 times at 64 bytes); its
  15.92 GiB cannot hold the chain. Reading host memory it is 1.68 times the CPU in RAM (1.45
  times at 64 bytes).
- NVMe at 4 KiB was not measured on the desktop. A drive reads one 4 KiB page per read at any
  read size (laptop rows below), so its 1.5e5 attempts/s is expected to hold; the CPU in RAM
  would then be 3.8 times the drive (65 times at 64 bytes).
- Full 128-byte blocks compress at 3.99e9/s on the GPU, against 4.90e9/s for the mostly-zero
  80-byte header. The CPU's 1.50e8 compressions/s on long inputs exceeds its 1.237e8/s header
  rate.
- One thread streaming its chunk beat a workgroup loading it into local data share (1.157e7
  against 1.108e7 in GPU memory, 9.49e5 against 9.34e5 over PCIe): 9 waves per SIMD against 3.

At 64 bytes on the same GPU (12 GiB): 3.42e8 attempts/s in GPU memory, limited by its random
64-byte access rate (2.47e9 reads/s); 1.42e7 over PCIe, limited by about 116 reads in flight at
about 1 µs each (1.16e8 reads/s). The desktop CPU at 64 bytes with 8 lanes: 1.280e7 attempts/s.

## BLAKE2b implementation (laptop: Ryzen AI 9 HX 370, 24 threads; 2026-10-01; k = 8, 4 KiB, 8 GiB)

`--hasher` picks the CPU's BLAKE2b: `blake2` (the RustCrypto crate, portable code; the default,
used by every CPU figure above), `simd` (`blake2b_simd`, AVX2 or SSE4.1 chosen at run time, one
input at a time) or `many` (`blake2b_simd`, the lanes' inputs hashed four per AVX2 pass). The
bench checks that all three give the same digests before it runs.

| hasher | attempts/s (8 lanes) | relative to `blake2` |
| --- | --- | --- |
| blake2 | 4.51e5 | 1x |
| simd | 4.64e5 | 1.03x |
| many | 7.94e5 (7.85e5 to 7.99e5 at 4 to 32 lanes) | 1.76x |
| read limit (`--nohash 1`) | 1.69e6 | - |

`many` is still limited by hashing. The CPU figures elsewhere in this file used `blake2`, so a
CPU miner using a multi-input BLAKE2b is about 1.76 times faster than they show (measured on this
laptop only).

## Measured on rented NVIDIA hardware (lium.io, 2026-10-01; chained rule, k = 8)

`cuda/` (CUDA; data generated on each GPU, word j of chunk a = splitmix64(a * W + j); every run
checked by `cuda/verify.py` against Python's `hashlib.blake2b`, 128 of 128 samples in each run).
Machine: 8 x NVIDIA H200 SXM (141 GB HBM3e each, 700 W limit), every pair joined by NVLink
through NVSwitch (NV18); host 2 x Intel Xeon Platinum 8468 (DDR5-4800, 8 channels per socket),
128 threads visible to the container. Driver 580.173.02, CUDA 13.0. Raw results:
`cuda/results/h200x8-swift-wolf-47-20261001/` (4 KiB) and `cuda/results/h200x8-chunks-20261001/`.

Modes: one GPU with the dataset in its memory (135 GiB); the dataset split across all 8 GPUs
(104 GiB each, 832 GiB in all, about the chain and tree's 773 GB), each read at a position on
another GPU loaded through a peer pointer over NVLink (77% of reads). Steps: `blake2b` (the
rule) and `fold` (XOR of the chunk's words, one compression: the read limit).

4 KiB chunks, blake2b:

| configuration | attempts/s | read GB/s | GPU power |
| --- | --- | --- | --- |
| one H200, dataset in cache (hashing ceiling) | 2.96e7 | 970 | 348 W |
| one H200, 135 GiB, stream kernel | 2.78e7 | 910 | 484 W |
| 8 x H200, 832 GiB split, staged kernel | 1.02e8 | 3,333 | 2.2 to 2.5 kW total |
| 8 x H200, 832 GiB split, stream kernel | 6.56e7 | 2,150 | 2.3 kW total |
| host CPU (DDR5), 128 GiB, 128 threads, 8 lanes, hashed | 1.36e6 | 44.5 | - |
| host CPU (DDR5), 128 GiB, fold (`--nohash 1`) | 5.39e6 | 177 | - |

The host CPU's hashed rate is its hashing limit (3.6e8 compressions/s, the `blake2` crate
without vector instructions); its memory limit is 4 times that. Filling 832 GiB took 1.25 s.

By chunk size, the split across 8 GPUs (attempts/s; the staged kernel from 256 bytes, the
stream kernel at 64 bytes; GPU power total):

| chunk | blake2b | fold | NVLink read GB/s | one H200, own memory, blake2b | GPU power, blake2b |
| --- | --- | --- | --- | --- | --- |
| 64 B | 3.30e9 | 4.25e9 | 1,691 to 2,176 | 6.93e8 | 2.3 kW |
| 256 B | 1.55e9 | 1.71e9 | 3,169 to 3,494 | 2.40e8 | 2.6 kW |
| 1 KiB | 4.04e8 | 4.28e8 | 3,313 to 3,503 | 8.47e7 | 2.3 kW |
| 4 KiB | 1.02e8 | 1.07e8 | 3,334 to 3,501 | 2.23e7 | 2.2 kW |
| 8 KiB | 5.09e7 | 5.34e7 | 3,334 to 3,497 | 1.13e7 | 2.3 kW |

- From 256 bytes up the split is limited by NVLink: its read traffic stays at 3.3 to 3.5 TB/s
  (8 x 450 GB/s per direction is the link rate), so its rate falls in proportion to chunk size.
  At 4 KiB, blake2b is 5% below fold: hashing does not limit it.
- Against one NVMe drive (1.5e5 attempts/s at full queue depth, any read size up to 4 KiB), the
  node is 22,000x at 64 B, 10,300x at 256 B, 2,700x at 1 KiB and 680x at 4 KiB. Past 4 KiB a
  drive reads more than one page per chunk (estimated: about half the rate at 8 KiB), so the
  ratio stays near 680x while proof sections grow: 4 KiB is where the node's lead over a drive
  stops falling.
- Against the DDR5 host at 4 KiB: 75x (both measured).
- Synthetic data costs the same per read as block data (positions come from hashes, reads are
  fixed-size, the step functions take the same time on any input). Not modeled: block data is
  partly compressible, so a miner could hold the chain compressed in fewer GPUs and decompress
  per read.
- Rented at $30 per hour for the 8 GPUs (lium.io, 2026-10-01).

On the laptop's RTX 4070 Laptop GPU (8 GB, 2026-10-01; `cuda/README.md`): 4 KiB, 2 GiB, staged
kernel, blake2b 3.9e6 to 4.5e6 and fold 6.7e6 attempts/s (220 GB/s).

## Measured (laptop: 24-thread CPU, one NVMe; 2026-09-28; chained rule)

A laptop; its NVMe rates are 4.4 times below the desktop drive's at full queue depth.

| regime | k | threads | effective attempts/s | storage reads/s | bound by |
| --- | --- | --- | --- | --- | --- |
| pure hash, no reads | - | 24 | 1.0e8 | - | the hasher |
| RAM-resident chain | 2 | 24 | 2.6e7 | - | the hasher |
| RAM-resident chain | 8 | 24 | 7.0e6 | - | hashing (9 per attempt) and serial reads |
| NVMe, O_DIRECT | 2 | 24 to 96 | 2.5e5 to 2.8e5 | 2.5e5 to 2.8e5 | the disk |
| NVMe, O_DIRECT | 8 | 24 | 1.2e4 to 1.4e4 | 8.5e4 to 9.5e4 | the disk, queue depth 24 |
| NVMe, O_DIRECT | 8 | 96 | 3.4e4 | 2.4e5 | the disk |

Read 0 is served from the parent in RAM; reads 1..k-1 are served from disk. Chained reads within
one attempt are serial, so queue depth comes only from parallel attempts: k = 8 at 24 threads
reached a third of the drive's rate, at 96 threads its full rate. Earlier measurements with the
independent rule (all k reads from disk) gave 4.4e5/s at k = 1 and 1e4 to 7e4/s at k = 8;
consumer NVMe random-read rate varies with queue depth and drive state.

## Read size (laptop: Ryzen AI 9 HX 370, 24 threads, 30 GiB LPDDR5X, Micron MTFDKBA1T0QFM; 2026-09-30; chained rule, k = 8)

`--read-bytes B` reads `B` bytes per position and hashes all of them into the next digest
(64 is the rule as specified). On disk the units are packed into 4 KiB pages, so every size
costs one page read. `--nohash 1` folds each read into the digest with XOR and a 64-bit mix
instead of hashing it, which gives the memory or disk limit with hashing removed. `--lanes 8`
interleaves 8 attempts per thread and prefetches each read as soon as its position is known
(1, 4, 8 and 16 lanes at 64 bytes: 8 lanes is at the plateau). RAM rows: 8 GiB dataset, 8 s;
cache-resident rows: 4 MiB, 5 s; disk rows: 16 GiB file, O_DIRECT, 192 threads, 15 s.

| read size | RAM, hashed (attempts/s) | RAM, memory limit (attempts/s; GB/s) | hashing limit, cache-resident (attempts/s) | NVMe, hashed (attempts/s) | RAM over NVMe, hashed | RAM over NVMe, memory limit |
| --- | --- | --- | --- | --- | --- | --- |
| 64 B | 7.03e6 | 1.83e7; 9.4 | 1.05e7 | 2.18e4 | 322x | 838x |
| 256 B | 3.19e6 | 1.24e7; 25.5 | 4.26e6 | 2.21e4 | 144x | 562x |
| 512 B | 2.08e6 | 7.59e6; 31.1 | 2.82e6 | 2.22e4 | 94x | 342x |
| 1 KiB | 1.30e6 | 5.50e6; 45.1 | 1.58e6 | 2.22e4 | 58x | 248x |
| 4 KiB | 4.05e5 | 1.84e6; 60.2 | 4.59e5 | 2.23e4 | 18x | 82x |

- **Disk does not depend on read size.** The drive delivered 1.55e5 page reads/s at every size,
  hashed or folded, at 192, 384 and 768 threads: the drive is the limit. This is below the
  2.4e5 to 2.8e5/s measured on 2026-09-28 on the same laptop (power profile `balanced`, I/O
  scheduler `kyber`); the cause was not investigated.
- **RAM moves from row-open-bound to bandwidth-bound.** With hashing removed, memory served
  1.46e8 reads/s at 64 bytes and 1.47e7 at 4 KiB (60 GB/s): 10 times fewer reads for 64 times
  the bytes.
- **RAM's advantage over disk per copy falls about 10 times at 4 KiB** (838x to 82x at the
  memory limit; 322x to 18x hashed on this CPU).
- **Hashing per attempt rises with read size**: 9 BLAKE2b-256 compressions at 64 bytes, 265 at
  4 KiB (8 steps of 33 compressions over 32 + 4,096 bytes, plus `h0`). The CPU's hashing limit is below its memory
  limit at every size (1.7 times at 64 bytes, 4 times at 4 KiB), so a RAM miner with faster
  hashing gains up to that factor, and more at larger sizes.
- **Proof sections grow with read size**: each read carries its unit, so at 4 KiB the 8 units
  are 32 KiB, against 512 bytes at 64 bytes, with paths shorter by 6 levels.

The RAM rows use an 8 GiB dataset on one laptop memory system; a chain-sized dataset adds
page-table walks, and server memory has more channels and more bandwidth. The ratio that
carries over is the one the table shows: at large read sizes RAM is limited by bandwidth, disk
by page reads per second.

## What it shows

1. **Software-only, no FPGA.** A commodity CPU mines the strong rule at its full effective
   rate.
2. **The read is the work.** From disk, a hasher 3,000 to 8,000x faster (k = 8) mines at the
   same rate. A 4.5 TH/s BLAKE2b ASIC computing `h0` for this CPU's drive does not raise the
   rate, and with chained reads surplus `h0` values cannot be used to skip attempts whose chunks
   are not held.
3. **Mining rate = read throughput over a held copy of the chain.** A partial copy costs
   reads that grow faster than the missing share: 18 times a full holder's at half the chain
   held (table above).
4. **Where faster hashing raises the rate.** Only in the RAM regime: this CPU performs 7.0e6/s
   at k = 8 against 5.6e7 chunk reads/s from DRAM.

## What chaining does not prevent

- A partial holder can fetch missing chunks from a remote holder instead of abandoning the
  attempt: 64 bytes and one round trip per missing chunk, with the round-trip latency overlapped
  by running more attempts in parallel. The cost is bandwidth, `64 x (k - 1) x (1 - f)` bytes
  per attempt, against the cost of storing the rest of the chain locally.
- `a_1` is still known before any storage read; the read penalty applies to `k - 2` reads.

## The tradeoff this rule does not remove

Requiring the full ~700 GB chain means reads range over data too large to cache, so:
- on disk, mining is slow (about 2.5e5/(k-1) per drive at high queue depth) and an ASIC gives
  no rate advantage: mining is a competition in storage read throughput that requires holding
  the chain;
- in DRAM (a machine with ~700 GB RAM), mining is faster but needs the capital cost of that
  machine per unit of rate.

Either way hash-optimized ASICs lose their advantage, and current BLAKE2b mining devices cannot
be used under this rule (they report only digests that meet an on-chip target, so they cannot
supply every `h0`).

## Block proof section (`chain`)

Implements the Bitcoin Improvement Proposal's proof section and both verification paths over the
chain's actual version 2 header (`header.rs`, ported from ~/src/bitcoin src/primitives/block.cpp
and checked stage by stage against the node's src/test/data/block_header_v2.json, copied to
`testdata/`): `h0` is the stage-3 digest `hash2`, and the exclusive-or of `final` and the
header's mask, read as a block hash, must meet `nBits`. Blocks cycle through hardware profiles 0
to 3 with a non-null exclusive-or key; a random body is used in place of the transactions. An
archival miner mines a chain of random-size blocks (bodies up to 64 KiB, `C_max` = 1,027 chunks)
and attaches each block's section: `S`, `N`, the aligned cover roots of the parent's chunks
(`ext`), and per read the chunk and its path. A pruned validator holding only peaks, and a light
client holding only headers and sections from the anchor (peaks over blocks `0..A-2`), process
each block in height order; both must match the miner's peaks at every height.

`chain` (3,000 blocks, activation 1,000, 1.5e6 chunks, `nBits` 0x1f400000 = 1,024 attempts
per block, 2026-09-28):

| check | result |
| --- | --- |
| 2,000 proved blocks | accepted by the validator and the light client; peaks match at every height |
| section size | 5,290 bytes mean, 5,876 max (block mean 32,381) |
| light client header check (all hash stages) | 22 us |
| 10,987 mutated copies of one section (each byte, bits 0 and 7; absent; truncated; trailing byte) | all rejected by both; none recorded the block hash invalid; the original then accepted |
| fabricated tree, 1,000 zero chunks (1,126 attempts, 2 ms) | accepted unanchored; rejected from the anchor (`Counts`) |
| fabricated history, zero chunks with correct `S` and `N` | accepted unanchored; rejected from the anchor (`Commitment`) |
| parent claiming `C_max + 1` chunks | rejected (`Oversize`); accepted with the bound removed |

A fork attacker without the chain, holding only its `m` fabricated blocks at the end, completes
an attempt only if reads 1..7 all have positions in them (1,000,000 attempts):

| m | fabricated share | completed | expected (share^7 x attempts) |
| --- | --- | --- | --- |
| 1 | 0.0007 | 0 | 6.2e-17 |
| 16 | 0.0108 | 0 | 1.7e-8 |
| 744 | 0.4999 | 7,827 | 7,802 |

Section size at 700 GiB (1.17e10 chunks, 62,500-chunk parents, 200,000 samples): `ext` 15.9
roots mean, 22 max; 8,762 bytes mean, 9,492 max; 0.46 GB per year.

Unit tests (`cargo test --release`): all five node header vectors (serialization, `h1`, `h2`,
both BLAKE2b stages, hardware input, mask, block hash); compact targets; cover roots are nodes
of the full tree and appending them gives the full tree's peaks; cover alignment and count
bound; decode then encode returns the same bytes; header faults (`mm_rhs`, `nBits`, a nonce
whose `final` misses the target) record the hash invalid, proof faults do not; fabricated trees
and the oversize parent rejected from the anchor.

## Usage

```
ddpow-strong bench [--gib G] [--reads k] [--threads N] [--seconds S] [--lanes L]  # RAM regime
ddpow-strong bench --disk FILE [--gib G] [--reads k] [--threads N] ...   # disk regime
    both: [--read-bytes B] (bytes per read, hashed whole) [--nohash 1] (fold instead of hash)
ddpow-strong partial [--gib G] [--reads k] [--layout random|prefix]      # partial holder, both rules
ddpow-strong prove [--kib K] [--reads k] [--bits B]                      # Merkle mountain range proof roundtrip
ddpow-strong chain [--blocks B] [--activation A] [--body-kib K] [--nbits HEX] # proof sections, pruned and light followers
```
