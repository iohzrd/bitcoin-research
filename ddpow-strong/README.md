# ddpow-strong: read-per-hash proof of work, software prototype

Tests whether the strong data-dependent rule (a chain read on every hash, not only on the
rare reported candidate) is implementable and what bounds it, without an FPGA. It is.

## The rule

Per attempt on header `hdr`, nonce `n`:

```
h0    = BLAKE2b-256(hdr || n)
a_i   = word_i(h0) mod N          i = 0..k-1        (positions over N chunks)
final = BLAKE2b-256(h0 || chunk(a_0) || ... || chunk(a_{k-1}))
solution if final meets target
```

The read is inside the per-nonce loop, so every hash reads. A solution carries a Merkle mountain range proof
of its reads (leaf = BLAKE2b(0x00||chunk), node = BLAKE2b(0x01||l||r), committed peaks),
checkable without the dataset. `prove` builds it and verifies: 8 reads over a 256 KiB dataset
= a 3.6 KB proof, VALID with no dataset held.

## Measured (this machine: 24-thread CPU, one NVMe; 2026-09-28)

| regime | k | effective attempts/s | bound by | note |
| --- | --- | --- | --- | --- |
| pure hash, no reads | - | 1.0e8 (100 MH/s) | the hasher | the ceiling |
| RAM-resident chain | 1 | 3.6e7 | the hasher | RAM feeds reads faster than the CPU hashes |
| RAM-resident chain | 8 | 1.7e7 | the hasher | 8 reads + 2 hashes per attempt |
| NVMe, O_DIRECT | 1 | 4.4e5 | the disk | a hasher 231x faster mines at the same rate |
| NVMe, O_DIRECT | 8 | 4.6e4 | the disk | a hasher 2166x faster mines at the same rate |

## What it shows

1. **Software-only, no FPGA.** A commodity CPU mines the strong rule at its full effective
   rate; the rule needs no new hardware to prototype or run.
2. **The read is the work; the hasher stops mattering.** From disk, mining is read-bound: a
   231x (k=1) or 2166x (k=8) faster hasher mines at the same rate. A 4.5 TH/s BLAKE2b ASIC
   and this CPU both mine at the NVMe's read rate. The ASIC's 43,000x hash advantage is
   neutralized.
3. **Mining power = read throughput over a held copy of the chain.** To mine you must hold
   the chunks (RAM or disk); there is nothing to hash without them. This is the strong goal:
   mining requires a node, on the hashing hardware itself, not just on whoever checks.
4. **Where an FPGA would help, and by how little.** Only in the RAM regime, and only up to
   RAM bandwidth: this CPU does 1.7e7/s (k=8) against a DRAM read ceiling near 5e7/s, so a
   faster hasher buys about 3x (about 12x at k=1) before DRAM-bandwidth-bound. From disk it
   buys nothing. So the FPGA is an efficiency play in the DRAM regime, not a prerequisite.

## The tradeoff this does not escape

Forcing the full ~700 GB chain means reads span data too big to cache, so:
- on disk, mining is slow (about 4e5/k per drive) and ASIC-flat: a storage-I/O contest that
  requires holding the chain;
- in DRAM (a ~700 GB RAM box), mining is faster (about 5e7/k) but needs the capital of that
  box per unit of rate.

Either way possession is mandatory and hash-optimized ASICs lose their edge. That is the
strong version of the rule fully achieved, at the cost of obsoleting today's BLAKE2b miners
(they run at their storage read rate, not their hash rate).

## Usage

```
ddpow-strong bench [--gib G] [--reads k] [--threads N] [--seconds S]     # RAM regime
ddpow-strong bench --disk FILE [--gib G] [--reads k] [--threads N] ...   # disk regime
ddpow-strong prove [--kib K] [--reads k] [--bits B]                      # Merkle mountain range proof roundtrip
```
