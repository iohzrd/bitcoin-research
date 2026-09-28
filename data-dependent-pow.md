# Data-dependent proof of work: mining requires a node

Purpose: make mining require a node, as far as deployed hardware allows.
Every hash candidate reads chunks from arbitrary positions in the chain
since genesis, so whoever checks candidates needs the whole chain, and every
parent block before mining on it. Constraint: the rule must never favor
pooled template building (Stratum version 1) over miner-built templates (DATUM: a gateway
and node beside the miners); if anything the reverse.

Limits: with open pools, a pool or a data service can check candidates for
hashers that hold nothing (section 6), and deployed miners report candidates
slowly enough (section 5.1) that this costs a hashing site a few KB/s. The
requirement therefore lands on whoever checks candidates; reaching hashing
sites needs faster result paths in miner firmware.

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
| 2014 | Two-phase proof of work (Eyal, Sirer) | ASIC phase 1, then a payout-key signature per candidate | our pre-filter's structure; binds a key, not a node (section 3) |
| 2015 | Ethash | Hashimoto's loop over a generated DAG | a generated dataset loses "must hold the chain" |
| 2015 | Nonoutsourceable puzzles (Miller et al.) | a worker able to mine can steal the win | ends all open pooling, DATUM pools included |
| 2016 | Popescu | digest of the nonce-th byte of every prior block, hashed into the header | nonce-only selection lets one digest table serve every miner |
| 2016 | MTP (Biryukov, Khovratovich) | hash-chosen reads of a generated dataset, each opened by a Merkle path | position-binding bugs in deployment (section 4.5) |
| 2017 | EWoK (Armknecht et al.) | coinbase nonce hashes a stored partition block | rejected reading the chain after the proof of work as binding only the pool operator |
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
z          leading zero bits of the block target (from nBits)
p          max(p_min, z - K)            (the pre-filter follows difficulty, 4.3)
pass       c has p leading zero bits
idx(i, n)  (u64le(c[8(i mod 4) ..]) + i x 0x9E3779B97F4A7C15) mod n
a_0        S + idx(0, N - S)            (in P's own chunks)
a_i        idx(i, N)                    i = 1..k-1 (anywhere in the chain)
final      BLAKE2b-256(c || chunk(a_0) || ... || chunk(a_{k-1}))
valid      pass and m_mm_rhs = commit and
           (final XOR mask), byte reversed, <= target << p (saturating at 2^256 - 1)
proof      N, S, peaks(T), and per read the chunk with its path to its peak
```

`m_mm_rhs` (32 bytes, null on this chain today) is inside the header hash, so
the chunks are fixed before `c` exists. The block hash is unchanged. k = 8,
K = 36, p_min = 34 (5.1).

The final target is the block target shifted left by p, so a block's
expected work is 2^256 / target, what `nBits` states. Comparing the final
digest with the target itself, as the first prototype did, needs 2^p times
that work: at activation on a live chain blocks would slow by 2^p (2^28)
with no retarget to recover.

Read 0 forces the parent's bytes before hashing on it (no header-only
mining). Reads 1..7 force the archive: a data stage holding a fraction f of
the chain keeps f^7 of its candidates.

### 4.3 The pre-filter follows difficulty

With a fixed p, network candidates per second (`H / 2^p`) grow with
hashrate while block revenue does not; chips gain efficiency faster than
drives gain random-read rate or links gain bandwidth, so the data stage's
share of revenue would grow with each chip generation, and device candidate
rates would approach their result-path limit. With `p = z - K` a block
takes about 2^K candidates at any difficulty: the network's data-stage work
per block stays constant, as difficulty holds the block rate constant, and
per-device candidate rates fall as the network grows. K = 36 keeps 2^36
candidates per block; at today's difficulty (network about 34 PH/s) z - K
is below the measured floor, so p = 34 today (the floor binds, 5.1). K
matters only later, if difficulty grows far enough that z - K exceeds the
floor.

The floor `p_min` bounds a device's candidate rate if hashrate falls. The
local-versus-remote balance (section 6) does not depend on p: local reads
and remote transport both scale as 2^-p; p sets their size relative to
revenue.

K is a consensus parameter, and changing it later is a hard fork either
way: a lower K raises p but loosens the final target, so neither rule's
valid blocks contain the other's. Options:

| K | effect | manipulation |
| --- | --- | --- |
| constant (prototype) | data-stage work per block fixed | none |
| height schedule, e.g. K - 1 per halving | data-stage work tracks the subsidy | none |
| from on-chain revenue (coinbase values) | tracks fees too | rejected: a miner raises fees in its own blocks for free |

Not by vote or miner choice: whoever pays for the data stage prefers a
higher p, and the largest pools pay the most.

### 4.4 Headers, proofs, validators

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

### 4.5 Attacks

- **Partial archive.** Holding a fraction f keeps f^7 of candidates: 90%
  held keeps 48%.
- **Stale archive.** Old data never changes; a copy one month stale keeps
  99.3% (measured, at about 8 GB per year growth). Read 0 forces receiving every parent; keeping blocks after use is
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
plus central CPU). With p following difficulty (4.3) the choice is K and the
floor p_min; at today's difficulty the floor binds, so p = p_min = 34.
Network: 33 to 40 PH/s (measured 2026-09 at height 974,588: 174 blocks per day, about
130 KB per block; 33 at the 600 s target block time, 40 at the observed spacing). Absolute costs below
scale with network hashrate; the per-PH/s table and the local-versus-remote
ratio do not.

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
| 34 | 17.5 | 5.8e4 | 7.5 Mbit/s | 0.15 cores | 4.1e5 | 1.5 | 1,055 PH/s |
| 36 | 4.4 | 1.5e4 | 1.9 Mbit/s | 0.04 cores | 1.0e5 | 0.4 | 4,221 PH/s |

At 0.1 to 1 USD per Mbit/s per month, remote transport at p = 28 costs 48
to 480 USD per PH/s per month. Stratum version 1 JSON carries about 200 bytes per
candidate, 12 times the binary figure.

Two limits bound `p` from below:

- **Device result path** (5.1). A device must report `H / 2^p` candidates
  per second. The measured Goldshell SC-LITE reports at most 283/s, so at
  4.5 TH/s it needs p >= 34; at p = 33 it would lose about half its
  hashrate.
- **One drive per small local miner.** A 4 TH/s miner checking its own
  candidates needs 1,630 random reads/s at p = 34, 104,000 at p = 28 and
  417,000 at p = 26, against 270,000 for the measured laptop NVMe.

Recommendation: p_min = 34 for deployed SC-class stock firmware, K = 36;
p = max(34, z - K) holds at the floor until difficulty grows far above
today's. At p = 34 the whole network (about 40 PH/s at the observed block spacing) is about 2.3
million candidates/s: 0.30 Gbit/s at 16 bytes (3.7 Gbit/s as stratum version 1 JSON), about
6 cores, and 16 million archive reads/s (one chain-in-RAM server, idle) if one actor
checked it all. A hashing site without the chain sends a few KB/s per TH/s
to whoever checks for it. Each 2 bits lower multiplies all of these by 4;
p = 28 (about 149 million candidates/s network-wide, 19 Gbit/s, about 370 cores,
about two to three chain-in-RAM servers) needs result paths about 60 times faster
than the SC-LITE reports at, which its driver could allow (5.1). At 40 PH/s
even p = 28 is small in absolute terms: one archive could serve the whole
network, so the rule forces whoever checks to hold a copy and pay per-
candidate bandwidth, not many copies into existence. Possession spreads
only as far as checking is decentralized (section 6).

### 5.1 Measured device result path

A Goldshell SC-LITE (firmware 2.2.0, four boards, about 4.5 TH/s) mined a
regtest chain through ratum-gateway over Wi-Fi (ping 1.5 ms), with the
pre-filter set by `-ddpowprefilter` and each block needing 2^50 hashes
(measured 2026-09-28):

| p | candidates/s | at 4.5 TH/s | implied hashrate |
| --- | --- | --- | --- |
| 24 to 32 | 283 | 268,000 to 1,048 | 0.005 to 1.2 TH/s |
| 34 | 259 | 262 | 4.44 TH/s |
| 36 | 66 | 65 | 4.53 TH/s |

- **Difficulty.** The device accepts any stratum difficulty down to p = 24:
  submissions start at p and the histogram halves per bit, with no rejects.
- **Not the network or the gateway.** Holding each reply 0, 2, 5, 10 or 20
  ms left the rate at 283/s (a miner waiting for replies would drop to
  42/s at 20 ms); the gateway checks 390,000 candidates/s per connection.
- **One result per board visit.** extranonce2 identifies the board. The
  controller visits the four boards in turn, one about every 3.48 ms (13.92
  ms per round), and takes at most one result per visit. Below the cap, the
  gaps between a board's submissions fall on whole rounds, their counts
  falling by the factor a Poisson source sampled once per round predicts
  (0.80 at 16 results/s), with an excess at one round from results queued
  on the board.

The limit is the controller's collection loop in firmware, not the chips:
the boards hold queued results, so reading more per visit, or visiting more
often, would raise it. The miner's displayed hashrate is computed from
accepted results and collapses below p = 34.

Disassembly of the `intminer` engine (same driver family, SCBox II 2.2.2;
`~/src/goldshell/RESULT_PATH_ANALYSIS.md`) confirms the mechanism: the scan
loop round-robins the boards, and per board it does one fixed 2048-byte SPI
read (about 3.48 ms at a roughly 4.7 MHz clock) and extracts exactly one
nonce, though the ASIC status word reports a queued-nonce count in bits
[15:12] that it ignores past the first. No sleep throttle. Two firmware-only
levers: drain the per-poll nonce queue (up to about 15x, to p_min about 30,
if the queue is real; unconfirmed without the ICT580 register map or a live
read) and faster or shorter SPI reads. Best case with both is p_min about
28. A firmware change is the only route below p = 34 on this hardware.

## 6. Who pays, and what it forces

For a 4 TH/s miner at p = 34 (p = 28 in parentheses):

| | Stratum version 1 pool member | DATUM miner, own data stage |
| --- | --- | --- |
| archive at the miner | none | an unpruned node: about 700 GB plus 11 GB of tree |
| reads at the miner | none | 1,630 random reads/s (104,000) |
| candidate traffic | 233/s (15,000/s) over its WAN link to the pool | 233/s (15,000/s) on its LAN to its gateway |
| checking | the pool, centrally: intake, CPU and archive reads for all members | its own gateway, well under 0.01 cores |

A DATUM miner is never worse off than a Stratum version 1 miner: every remote option open
to a Stratum version 1 miner (sending candidates to a pool or a data service) is open to
it too. A Stratum version 1 pool can cut its intake by placing a proxy with the chain at
each farm, which gives the farm the same archive a DATUM miner holds,
without control of templates. At worst the two are even; at scale the pool
pays per candidate for centralizing.

Forced: a copy of the chain within reach of each data stage, and every
parent block before hashing on it (no header-only mining); the
per-candidate cost of distance falls on whoever centralizes the check. At
p = 34 that cost is small, so in practice the requirement lands on pools
and DATUM gateways, not on hashing sites.

Not forced:

- **An archive at every hashing site.** A pool, or a data service at
  `H / 2^p x 16 B`, checks candidates for hashers that hold nothing.
- **Validation.** A replica fed by a pool satisfies the rule without
  checking a signature. The default software at the data stage decides the
  rest: if the reference data stage is Knots behind a DATUM gateway, the
  miners who check their own candidates run archival validating nodes.

## 7. Prototype

- **Knots** `ddpow-regtest`: `src/ddpow.{h,cpp}`, `-testactivationheight=ddpow@h`,
  `-ddpowprefilter` (p_min), `-ddpowcandidates` (K), `-ddpowreads`,
  `-ddpowblockbits` (a fixed block target from activation, for hardware
  tests). The final target is shifted by p; `getblocktemplate` reports the
  template's p with p_min and K. Tree levels 6 and up in
  `blocks/ddpow/` (one file per level, fsynced before a per-height record
  of block hash and chunk count), levels 0 to 5 recomputed from the 64
  chunks under a level-6 node; chunks from block files; loaded at restart.
  RPCs `getddpowproof`, `verifyddpowproof`, `submitheader` with a proof;
  `getblocktemplate` rule `!ddpow`. Tests: `ddpow_tests`,
  `feature_ddpow.py`, `feature_ddpow_prefilter.py` (K = 2, p above its
  floor), `p2p_ddpow_headers.py`, all against an independent Python
  implementation.
- **ratum** `ddpow`: pool and gateway follow their archival nodes' chains,
  judge shares in hashes (share target shifted by `p`) and blocks against
  the target shifted by `p`, with p computed per job from its bits. The
  gateway
  acknowledges every in-date candidate, forwards only shares, and reports
  per connection candidates, candidate hashrate, rejects by reason and
  digests by leading zero bits (miner lookup). e2e scenarios `ddpow`
  (`--block-bits`, `--candidates`: p above its floor, checked against the
  node's template) and `ddpow-load` (the gateway's candidate ceiling);
  `candidate-load` drives it. `stratum.debug_reply_delay_ms` and
  `stratum.debug_submit_log` measure a miner's result path.

Open:

- faster result paths: the SC-LITE's firmware takes one result per board
  visit (5.1); other models and firmware not measured, and a firmware
  change is the only route below p = 34;
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
