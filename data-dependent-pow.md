# Data-dependent proof of work: mining requires an archival node

Purpose: make holding the whole chain a condition of mining. Every hash
candidate reads chunks from arbitrary positions in the chain since genesis,
so a hashing site without an archival copy cannot complete its work.

## 1. Principle

Any value a node computes once per block (template, state, a proof) relays
to a hasher for a few bytes per block, so no per-block value ties a hasher
to a node. Data consumed per hash does not relay: its volume scales with
hashrate. The rule makes every candidate read the chain.

Limit: the rule forces possession of the chain, not validation. Validation
outputs relay like any other per-block value.

## 2. Prior art

| year | work | mechanism | lesson |
| --- | --- | --- | --- |
| 2014 | Hashimoto (Dryja) | per nonce, 64 reads from chain transaction data | the direct ancestor; I/O-bound mining over the chain |
| 2014 | Ethash (Ethereum) | the same access pattern over a DAG derived from headers | a header-derived dataset loses "must hold the chain"; memory-bound mining at scale works |
| 2014 | Permacoin | proofs of retrievability; Merkle proofs of accessed data | light clients verify reads by Merkle path |
| 2014 | Two-phase PoW (Eyal, Sirer) | the payout key signs each candidate | binds a key, not a node (section 3) |
| 2015 | Nonoutsourceable puzzles (Miller et al.) | the finder can re-bind the payout | ends all open pooling; needs no node |
| 2016 | Popescu | every block hashes the nonce-th byte of every prior block | whole-chain possession; the bandwidth arithmetic |
| 2018 | Chia | proof of space over generated plots | storage alone does not tie a miner to the chain |

## 3. Key locality, set aside

Signing per candidate binds hashing to a key. A pool hands a hasher a key
and the hasher mines blind as today; no node is needed anywhere. The
nonoutsourceable form ends every open pool and still needs no node.

## 4. The rule

### 4.1 Dataset

Every block from genesis, in height order, serialized, split into 64-byte
chunks (the last zero-padded): about 700 GB, almost all inherited from
Bitcoin at the fork. A recent window (the first prototype used 4 GiB) forces
only a pruned node's data, and a copy of it one month stale keeps 5% of
candidates, so it was replaced.

### 4.2 Stage 4

For a block at height `h` on parent `P`:

```
chunks(b)  block b's serialized bytes in 64-byte pieces, the last zero-padded
T          Merkle mountain range over the chunks of blocks 0..P in height order
           leaf = BLAKE2b-256(0x00 || chunk); node = BLAKE2b-256(0x01 || left || right)
N          chunk count of blocks 0..P
S          chunk count of blocks 0..P-1 (P's first chunk)
commit     BLAKE2b-256(0x02 || N u64 LE || S u64 LE || bag(peaks(T)))
           bag folds the peaks, highest first, from the right with the node hash
c          the header's stage-3 digest (what the chip produces)
pass       c has p leading zero bits
idx(i, n)  (u64le(c[8(i mod 4) ..]) + i x 0x9E3779B97F4A7C15) mod n
a_0        S + idx(0, N - S)            (in P's own chunks)
a_i        idx(i, N)                    i = 1..k-1 (anywhere in the chain)
final      BLAKE2b-256(c || chunk(a_0) || ... || chunk(a_{k-1}))
valid      pass and m_mm_rhs = commit and (final XOR mask), byte reversed, <= target
proof      N, S, peaks(T), and per read the chunk with its path to its peak
```

`m_mm_rhs` (32 bytes, null on this chain today) is inside the header hash, so
the chunks are fixed before `c` exists. The block hash is unchanged. k = 8.

Read 0 forces the parent's bytes before hashing on it (no header-only
mining). Reads 1..7 force the archive: a site holding a fraction f of the
chain keeps f^7 of its candidates.

### 4.3 Headers, proofs, validators

A header alone proves only the pre-filter (2^p hashes), which would remove
headers-first sync's DoS bound. The commitment restores it: a header's proof
(about 10 KB at 700 GB: 8 reads x (64 B + 33 x 32 B) plus peaks) shows full
work against the committed tree, checkable with no chain data.

- **Header checks.** Full check from the node's own tree when the parent is
  within 8 blocks of it; else from a proof; else, below the last checkpoint,
  pre-filter only. Above the last checkpoint a header without a proof is
  refused, not stored, not punished.
- **Transport.** `sendddpow` after the handshake; headers at active heights
  go to such peers as `hdrproofs` (header, proof) from a per-block proof
  store. Proofs are verified on arrival and held through the presync
  redownload.
- **Validators.** Appending a block needs only the peaks (at most 64
  hashes); checking a block needs its 8 chunks, from the block files or
  from its proof. A pruned node therefore validates from peaks and proofs;
  the dataset's size burdens miners, not validators.
- **Archival nodes.** Read chunks from their block files. Serving proofs
  needs interior tree nodes: 2 x N x 32 B (about the chain's size) if all
  levels are kept, about 11 GB if levels 0 to 5 are recomputed from a 4 KiB
  page per read.

### 4.4 Attacks

- **Partial archive.** Holding a fraction f keeps f^7 of candidates: 90%
  held keeps 48%.
- **Stale archive.** Old data never changes; a copy one month stale keeps
  98.7%. Read 0 forces receiving every parent; keeping blocks after use is
  forced only weakly.
- **Compression, regeneration.** Chain bytes compress by tens of percent at
  most and cannot be regenerated from less.
- **Remote reads.** Bandwidth `H / 2^p x 7 x 64 B`; section 5.
- **Forged headers.** A forger committing to a fake tree pays full hashing;
  the block fails `bad-ddpow-commitment` at connection.
- **Grinding chunks.** Fixed by the commitment before `c` exists.

## 5. Choosing p

`p` sets the ratio between remote serving (bandwidth, per month) and local
serving (the archive with enough random-read rate, once). Network: about
100 PH/s at height 974443 (`nBits 0x1900edba`, 446 blocks per day).

Measured random-read rates (`ddpow-sim`, this repository):

| medium | reads/s | note |
| --- | --- | --- |
| DDR5 laptop, 24 threads | 4.3e8 | 64-byte reads; the chain in RAM needs about 700 GB |
| laptop NVMe (Micron MTFDKBA1T0QFM), 64 threads | 1.7e5 | 4 KiB O_DIRECT, one chunk per page |
| same, 256 threads | 2.7e5 | synchronous reads; io_uring and datacenter drives go higher, not measured |

Per PH/s, with 7 reads per candidate from the archive:

| p | candidates/s per 300 GH/s die | remote bandwidth | NVMe drives (2.7e5 reads/s) | archive in DRAM (4.3e8 reads/s) |
| --- | --- | --- | --- | --- |
| 24 | 18,000 | 214 Gbit/s | 1,550 | 1 box per 1 PH/s |
| 28 | 1,100 | 13 Gbit/s | 97 | 1 box per 16 PH/s |
| 30 | 280 | 3.3 Gbit/s | 24 | 1 box per 66 PH/s |
| 32 | 70 | 0.8 Gbit/s | 6 | 1 box per 260 PH/s |

An ordinary archival node's disk serves 10 TH/s at p = 28 and 165 TH/s at
p = 32. At 0.1 to 1 USD per Mbit/s per month, remote serving at p = 28 costs
1.3 to 13 thousand USD per PH/s per month, against one DRAM box or tens of
drives once.

`p` decides where the archive must sit:

- **p = 32:** one archival node's disk per site up to about 165 TH/s; a
  hosting facility can serve its customers' reads over its LAN (0.8 Gbit/s
  per PH/s), so the archive sits per facility, not per owner.
- **p = 28:** an archival node's disk serves a 10 TH/s owner; remote
  serving costs more than local for every site above about 10 TH/s; LAN
  serving costs 13 Gbit/s per PH/s, so facilities place archives per rack.
- **p = 24:** 214 Gbit/s per PH/s rules out LAN serving; each PH/s needs
  the archive in DRAM; a die reports 18,000 candidates per second, which
  deployed result paths may not carry.

Recommendation: p = 28 (range 26 to 30). It binds owners down to about
10 TH/s with an ordinary archival node, pushes facility-level serving to
per-rack archives, and needs about 1,100 candidates per second from a
300 GH/s die (about 18 KB/s at 16 bytes each). Deployed miners' result-path
bandwidth is not verified; it bounds `p` from below.

## 6. What it forces, and what it does not

Forced at every hashing site above the bound: the whole chain, read at
hashrate, and every parent block before hashing on it. That is an archival
node's data and bandwidth.

Not forced: validation. A replica fed by a pool, or a facility's shared
archive at high `p`, satisfies the rule without checking a signature. With
the archive on site, validating and building one's own template costs a CPU
and software, so the default software at the data stage decides the outcome:
if the reference data stage is Knots, farms run archival validating nodes.

Farms and hash renters run no node today because nothing requires one; they
are the case this rule binds hardest. The dataset depends only on the chain,
so a renter's one archive serves whichever pool a buyer chooses.

## 7. Prototype

- **Knots** `ddpow-regtest`: `src/ddpow.{h,cpp}`, `-testactivationheight=ddpow@h`,
  `-ddpowprefilter`, `-ddpowreads`. Tree levels 6 and up in
  `blocks/ddpow/` (one file per level, fsynced before a per-height record
  of block hash and chunk count), levels 0 to 5 recomputed from the 64
  chunks under a level-6 node; chunks from block files; loaded at restart.
  RPCs `getddpowproof`,
  `verifyddpowproof`, `submitheader` with a proof; `getblocktemplate` rule
  `!ddpow`. Tests: `ddpow_tests`, `feature_ddpow.py`,
  `p2p_ddpow_headers.py`, all against an independent Python implementation.
- **ratum** `ddpow`: pool and gateway follow their archival nodes' chains,
  judge shares in hashes (share target shifted by `p`); e2e scenario `ddpow`.

Open:

- validation by pruned nodes from proofs (the proof check exists; blocks do
  not yet carry proofs);
- the tree over about 700 GB built once at activation, and its peaks
  hard-coded for pruned nodes;
- deployed miners' result-path bandwidth, which bounds `p`.

## Sources

- Popescu, "The necessary prerequisite for any change to the Bitcoin protocol" (2016): http://web.archive.org/web/20251114113328/http://trilema.com/2016/the-necessary-prerequisite-for-any-change-to-the-bitcoin-protocol/
- Dryja, Hashimoto (2014); Dagger-Hashimoto notes: https://github.com/BlockChainCaffe/EthereumWiki/blob/master/Dagger-Hashimoto.md
- Miller, Juels, Shi, Parno, Katz, "Permacoin", IEEE S&P 2014: https://www.semanticscholar.org/paper/ecef1d55851c0632da88b07e6b0dd2f775d74e4d
- Eyal, Sirer, two-phase proof of work (2014), summarized in https://arxiv.org/pdf/2207.05454
- Miller, Kosba, Katz, Shi, "Nonoutsourceable Scratch-Off Puzzles", CCS 2015: https://www.cs.umd.edu/~jkatz/papers/nonoutsourceable.pdf
