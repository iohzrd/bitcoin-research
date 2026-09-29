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

## Measured (this machine: 24-thread CPU, one NVMe; 2026-09-28; chained rule)

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
ddpow-strong bench [--gib G] [--reads k] [--threads N] [--seconds S]     # RAM regime
ddpow-strong bench --disk FILE [--gib G] [--reads k] [--threads N] ...   # disk regime
ddpow-strong partial [--gib G] [--reads k] [--layout random|prefix]      # partial holder, both rules
ddpow-strong prove [--kib K] [--reads k] [--bits B]                      # Merkle mountain range proof roundtrip
ddpow-strong chain [--blocks B] [--activation A] [--body-kib K] [--nbits HEX] # proof sections, pruned and light followers
```
