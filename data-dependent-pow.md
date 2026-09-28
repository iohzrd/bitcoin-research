# Data-dependent proof of work: check candidates next to the hashers

Purpose: make checking mining candidates cost more the farther it runs from
the hashers. Local template building (DATUM: a gateway and node beside the
miners) then costs no more than pooled template building (SV1), and less at
scale. Every hash candidate reads chunks from arbitrary positions in the
chain since genesis, so each candidate must reach a copy of the chain.

Not achievable with this mechanism: forcing every hashing site to hold the
chain while open pools exist (section 6).

## 1. Principle

Any value a node computes once per block (template, state, a proof) relays
to a hasher for a few bytes per block, so no per-block value ties a hasher
to a node. Per-candidate work does not relay that way: each candidate either
reads a local copy of the chain (7 random reads) or travels to a remote copy
(about 16 bytes). Both costs scale with hashrate; the second also scales
with distance and falls on whoever centralizes the check.

Limit: the rule forces a copy of the chain within reach of each place
candidates are checked. It does not force validation, and it does not force
a copy at each hashing site.

## 2. Prior art

Full survey with sources: [ddpow-prior-art.md](ddpow-prior-art.md).

| year | work | mechanism | lesson |
| --- | --- | --- | --- |
| undated, cited 2014 | Hashimoto (Dryja) | header hash selects 64 txids from the whole chain; no proofs | the direct ancestor; its bandwidth argument counts data moved to the hasher, not the hash moved to the data |
| 2014 | Permacoin | hash-chosen reads of an archive, Merkle-proven; payout key signs each step | our read-and-prove template; key binding |
| 2014 | Two-phase PoW (Eyal, Sirer) | ASIC phase 1, then a payout-key signature per candidate | our pre-filter's structure; binds a key, not a node (section 3) |
| 2015 | Ethash | Hashimoto's loop over a generated DAG | a generated dataset loses "must hold the chain" |
| 2015 | Nonoutsourceable puzzles (Miller et al.) | a worker able to mine can steal the win | ends all open pooling, DATUM pools included |
| 2016 | Popescu | digest of the nonce-th byte of every prior block, hashed into the header | nonce-only selection lets one digest table serve every miner |
| 2016 | MTP (Biryukov, Khovratovich) | hash-chosen reads of a generated dataset, each opened by a Merkle path | position-binding bugs in deployment (section 4.4) |
| 2017 | EWoK (Armknecht et al.) | coinbase nonce hashes a stored partition block | rejected reading the chain after the PoW as binding only the pool operator |
| 2019 | Chia | proof of space over generated plots | storage alone does not tie a miner to the chain |
| 2020 | Arweave SPoRA | per-attempt chunk read of the chain's data with Merkle proofs | its predecessor was outsourced in production over a Gbit link; the fix was per-address packing |

## 3. Key and encoding bindings, set aside

Signing per candidate binds hashing to a key. A pool hands a hasher a key
and the hasher mines blind as today; no node is needed anywhere. The
nonoutsourceable form ends every open pool, DATUM pools included.

Per-key masking of chunks (Arweave 2.6, Filecoin, Lerner) was considered
and rejected. Chunks XORed with an expensive mask of (key, position) force a
replica per key. A pool puts one key in every member's coinbase and
amortizes one replica; a DATUM miner using its own key holds its own. The
binding penalizes independent template building, the opposite of the
purpose.

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
mining). Reads 1..7 force the archive: a data stage holding a fraction f of
the chain keeps f^7 of its candidates.

### 4.3 Headers, proofs, validators

A header alone proves only the pre-filter (2^p hashes), which would remove
headers-first sync's DoS bound. The commitment restores it: a header's proof
(about 10 KB at 700 GB: 8 reads x (64 B + 33 x 32 B) plus peaks) shows full
work against the committed tree, checkable with no chain data.

- **Header checks.** Full check from the node's own tree when the parent is
  within 8 blocks of it; else from a proof; else, below the last checkpoint
  or while importing blocks, pre-filter only. Above the last checkpoint a
  header without a proof is refused, not stored, not punished.
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
- **Remote data stage.** A site without the chain sends each candidate's
  nonce and extranonce (about 16 bytes) to a remote copy, which rebuilds the
  header, reads, and replies only on a share or block: `H / 2^p x 16 B`.
  Shipping the reads to the hasher instead (`H / 2^p x 7 x 64 B`) costs 28
  times more and is never the cheaper option. Section 5.
- **Forged headers.** A forger committing to a fake tree pays full hashing;
  the block fails `bad-ddpow-commitment` at connection.
- **Grinding chunks.** Fixed by the commitment before `c` exists.
- **Proof checks.** Each opening is folded at the position derived from `c`,
  with path length and peak index checked against it (MTP deployments
  failed on unchecked positions). Positions and `final` use all 256 bits of
  `c` (ProgPoW's 64-bit seed let the memory stage be fixed and skipped).

## 5. Choosing p

`p` sets how much each unit of hashrate costs to check, locally (7 random
reads per candidate) or remotely (about 16 bytes of transport per candidate
plus central CPU). Network: about 100 PH/s at height 974443
(`nBits 0x1900edba`, 446 blocks per day).

Measured rates:

| what | rate | note |
| --- | --- | --- |
| DDR5 laptop, 24 threads | 4.3e8 random 64-byte reads/s | the chain in RAM needs about 700 GB (`ddpow-sim`) |
| laptop NVMe (Micron MTFDKBA1T0QFM), 256 threads | 2.7e5 random 4 KiB reads/s | O_DIRECT; datacenter drives go higher, not measured (`ddpow-sim`) |
| ratum-gateway, one connection | 3.9e5 candidates/s at 0.96 cores | reply writes batched per read (ratum e2e `ddpow-load`) |
| ratum-gateway, 4 or more connections | 9.7e5 candidates/s | limited by a global lock, not CPU |

Per PH/s:

| p | candidates/s per 300 GH/s die | candidates/s | remote transport at 16 B | central CPU | archive reads/s | NVMe drives | DRAM box covers |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 24 | 17,900 | 6.0e7 | 7.6 Gbit/s | 149 cores | 4.2e8 | 1,545 | 1 PH/s |
| 26 | 4,500 | 1.5e7 | 1.9 Gbit/s | 37 cores | 1.0e8 | 386 | 4 PH/s |
| 28 | 1,100 | 3.7e6 | 0.48 Gbit/s | 9.3 cores | 2.6e7 | 97 | 16 PH/s |
| 30 | 280 | 9.3e5 | 0.12 Gbit/s | 2.3 cores | 6.5e6 | 24 | 66 PH/s |
| 32 | 70 | 2.3e5 | 0.03 Gbit/s | 0.6 cores | 1.6e6 | 6 | 264 PH/s |

At 0.1 to 1 USD per Mbit/s per month, remote transport at p = 28 costs 48
to 480 USD per PH/s per month. Stratum v1 JSON carries about 200 bytes per
candidate, 12 times the binary figure.

Two limits bound `p` from below:

- **Device result path.** A device must report `H / 2^p` candidates per
  second; a 4 TH/s device sends 15,000/s at p = 28 and 238,000/s at p = 24.
  Not measured; the hardware test through ratum-gateway measures it.
- **One drive per small local miner.** A 4 TH/s miner checking its own
  candidates needs 104,000 random reads/s at p = 28, 209,000 at p = 27 and
  417,000 at p = 26, against 270,000 for the measured laptop NVMe.

Recommendation: p = 28; 26 or 27 if the device result path allows and
datacenter-class drives are assumed for small miners. At p = 28 a 4 TH/s
local miner needs one drive and 0.04 cores, while a 100 PH/s SV1 pool takes
in 370 million candidates/s (47 Gbit/s at 16 bytes, about 930 cores). Each
2 bits lower multiplies the pool's costs by 4 and the small miner's reads by
4.

## 6. Who pays, and what it forces

For a 4 TH/s miner at p = 28:

| | SV1 pool member | DATUM miner, own data stage |
| --- | --- | --- |
| archive at the miner | none | an unpruned node: about 700 GB plus 11 GB of tree |
| reads at the miner | none | 104,000 random reads/s, one NVMe |
| candidate traffic | 15,000/s over its WAN link to the pool | 15,000/s on its LAN to its gateway |
| checking | the pool, centrally: intake, CPU and archive reads for all members | 0.04 cores on its own gateway |

A DATUM miner is never worse off than an SV1 miner: every remote option open
to an SV1 miner (sending candidates to a pool or a data service) is open to
it too. An SV1 pool can cut its intake by placing a proxy with the chain at
each farm, which gives the farm the same archive a DATUM miner holds,
without control of templates. At worst the two are even; at scale the pool
pays per candidate for centralizing.

Forced: a copy of the chain within reach of each data stage, and every
parent block before hashing on it; the per-candidate cost of distance falls
on whoever centralizes the check.

Not forced:

- **An archive at every hashing site.** A pool, or a data service at
  `H / 2^p x 16 B`, checks candidates for hashers that hold nothing.
- **Validation.** A replica fed by a pool satisfies the rule without
  checking a signature. The default software at the data stage decides the
  rest: if the reference data stage is Knots behind a DATUM gateway, the
  miners who check their own candidates run archival validating nodes.

## 7. Prototype

- **Knots** `ddpow-regtest`: `src/ddpow.{h,cpp}`, `-testactivationheight=ddpow@h`,
  `-ddpowprefilter`, `-ddpowreads`, `-ddpowblockbits` (a fixed block target
  from activation, for hardware tests). Tree levels 6 and up in
  `blocks/ddpow/` (one file per level, fsynced before a per-height record
  of block hash and chunk count), levels 0 to 5 recomputed from the 64
  chunks under a level-6 node; chunks from block files; loaded at restart.
  RPCs `getddpowproof`, `verifyddpowproof`, `submitheader` with a proof;
  `getblocktemplate` rule `!ddpow`. Tests: `ddpow_tests`,
  `feature_ddpow.py`, `p2p_ddpow_headers.py`, all against an independent
  Python implementation.
- **ratum** `ddpow`: pool and gateway follow their archival nodes' chains,
  judge shares in hashes (share target shifted by `p`). The gateway
  acknowledges every in-date candidate, forwards only shares, and reports
  per connection candidates, candidate hashrate, rejects by reason and
  digests by leading zero bits (miner lookup). e2e scenarios `ddpow` and
  `ddpow-load` (the gateway's candidate ceiling); `candidate-load` drives it.

Open:

- deployed miners' result-path bandwidth, which bounds `p` (hardware test
  through ratum-gateway);
- page-level chunk reads with a height-to-file-offset index: Knots reads a
  whole raw block per chunk, and ratum's follower holds the chain in memory;
  a prerequisite for mainnet;
- validation by pruned nodes from proofs (the proof check exists; blocks do
  not yet carry proofs);
- the tree over about 700 GB built once at activation, and its peaks
  hard-coded for pruned nodes;
- NEC patent US10397328B2 (EWoK): scope relative to this rule not analyzed.

## Sources

- Prior art survey: [ddpow-prior-art.md](ddpow-prior-art.md)
- Popescu, "The necessary prerequisite for any change to the Bitcoin protocol" (2016): http://web.archive.org/web/20251114113328/http://trilema.com/2016/the-necessary-prerequisite-for-any-change-to-the-bitcoin-protocol/
- Dryja, Hashimoto: http://diyhpl.us/~bryan/papers2/bitcoin/meh/hashimoto.pdf
- Arweave ANS-103 (SPoRA, and the Proof of Access outsourcing account): https://github.com/ArweaveTeam/arweave-standards/blob/master/ans/ANS-103.md
- Armknecht, Bohli, Karame, Li, EWoK: https://eprint.iacr.org/2017/1067
- Miller, Juels, Shi, Parno, Katz, "Permacoin", IEEE S&P 2014: https://www.ieee-security.org/TC/SP2014/papers/Permacoin_c_RepurposingBitcoinWorkforDataPreservation.pdf
- Eyal, Sirer, two-phase proof of work (2014): https://web.archive.org/web/2015id_/http://hackingdistributed.com/2014/06/18/how-to-disincentivize-large-bitcoin-mining-pools/
- Miller, Kosba, Katz, Shi, "Nonoutsourceable Scratch-Off Puzzles", CCS 2015: https://www.cs.umd.edu/~jkatz/papers/nonoutsourceable.pdf
