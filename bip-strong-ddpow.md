    BIP: XXXX
    Title: Strong data-dependent proof of work
    Author: iohzrd
    Status: Draft V01
    Type: Standards Track
    Layer: Consensus (hard fork)
    Created: 2026-09-28

## Abstract

This consensus rule requires reads of block chain bytes for every mining hash and hashes those
bytes into the value checked against the difficulty target. The first read position comes from
the hash; each later position comes from the chunk read before it, spanning the whole chain from
the genesis block. Because every hash requires reads, and each position of an attempt after the
first is known only after the previous read is performed, a miner holding part of the chain
spends reads on attempts it cannot complete. Each block carries a proof of its reads, so a node
verifies it from its own Merkle mountain range peaks without chain data; the chain's size is a
cost to miners, not to validators.

## Motivation

Today a miner needs no block chain data and runs no node. A pool assembles the candidate block,
reduces it to an 80-byte header, and sends that header to hashing hardware. The hardware
iterates over nonces and returns any whose hash meets the target. It stores no block chain and
validates nothing. This lets hashing concentrate at parties that hold no chain, and lets miners
extend blocks they have not checked, which has produced chains built on invalid blocks in the
past.

To make holding the chain a condition of mining, the work that bounds mining must be reads of
chain data. Reading the chain on only a small share of hashes does not achieve this: the reads
are few, a miner without the chain buys them from a holder at a few bytes per candidate, and the
hash work that bounds mining needs no chain. This rule requires chain reads for every hash, so
reads, not hashes, bound mining: every unit of mining work is a read performed by a party that
holds the chain. A party without a copy can still buy reads from a holder, as a party without
hardware can rent hash rate today, but the holder performs the reads.

## Specification

Chunks. Every block from genesis, in height order, serialized without its proof section,
split into 64-byte pieces, the last zero-padded.

Tree. `T` is a Merkle mountain range over the chunks of blocks `0..P` (parent `P`):
leaf `= BLAKE2b-256(0x00 || chunk)`, node `= BLAKE2b-256(0x01 || left || right)`.
`N` = chunk count of `0..P`; `S` = chunk count of `0..P-1`.

Commitment. The header field `mm_rhs` MUST equal
`BLAKE2b-256(0x02 || N as u64le || S as u64le || bag(peaks(T)))`, where `bag` folds the
peaks highest first from the right with the node hash. `mm_rhs` is inside the header, so the
reads are fixed before hashing.

Per attempt (header `H` with nonce `n`, `k = 8`). `h0` is the version 2 header's stage-3
BLAKE2b-256 digest: the value a BLAKE2b mining chip outputs, and the value the per-candidate
rule and the block-hash computation compare against the target. The rule differs from the
per-candidate rule in two ways: no pre-filter, so the reads are performed for every `h0`; and
chained positions, so each read position after the first depends on the previous chunk.

    x_0   = h0 = stage-3 BLAKE2b-256 digest of H     (the mining chip's output)
    a_0   = S + idx(x_0, N - S)                        parent block
    x_i   = BLAKE2b-256( x_{i-1} || chunk(a_{i-1}) )   i = 1..k
    a_i   = idx(x_i, N)                                i = 1..k-1, whole chain
    final = x_k

`idx(x, n)` is `u64le(x[0..8]) mod n`. The block is valid if `final`, masked and
byte-reversed as a block hash, is `<= target(nBits)`. The reads are performed for every
nonce value, and position `a_i` for `i >= 2` is unknown until chunk `a_{i-1}` has been read.

Append. Adding a subtree root of height `b` to a list of peaks: push it; while the last two
peaks have equal height, replace them with `node(left, right)` one level higher. Appending a
leaf is appending a root of height 0.

Aligned cover. The aligned cover of leaves `[S, N)` is the list of subtrees taken left to right
from `p = S`: at each `p`, the subtree of the largest height `b` with `p mod 2^b = 0` and
`p + 2^b <= N`.

Block proof. A block at height `P + 1 >= A` MUST carry a proof section after its transactions.
The block hash is not computed over it. Every field is determined by the header and the chain,
so the section has one valid encoding:

    len     u32le            byte length of the fields below
    S, N    u64le each
    ext     32 bytes each    roots of the aligned cover of [S, N) (the parent's chunks)
    per read i = 0..k-1:
      chunk(a_i)             64 bytes
      path_i                 32 bytes per level, siblings from leaf a_i to its peak, lowest first

The count of `ext` is fixed by `S` and `N`; the length of `path_i` is the height of the peak
holding `a_i`. Size at 700 GiB: 8.8 KB mean, 9.5 KB max; `ext` holds at most 32 roots for a
62,500-chunk parent, 22 measured (`ddpow-strong chain`). A block whose proof section is absent
or fails verification is invalid in that form. A node MUST NOT record the block hash as invalid
on a proof section failure: the same header and transactions with the correct section may be
valid.

Verification. A node keeps `N` and `peaks(T)` for its tip and appends each validated block's
chunks as leaves, keeping the aligned cover roots of each appended block. To check block `P + 1`
it requires `S` and `N` equal to its own counts and `ext` equal to the roots it kept for block
`P`; recomputes `h0`; then for `i = 0..k-1` computes `a_i`, checks that `chunk(a_i)` at position
`a_i`, hashed with the siblings in `path_i`, equals the node's own peak, and computes `x_{i+1}`
from the proof's chunk; and compares `final` with the target. No chain data is read: archival
and pruned nodes verify the same way.

Header verification without the chain. For headers-first synchronization and light clients. The
node starts from an anchor: the `mm_rhs` block `A` must carry, the commitment to the tree over
blocks `0..A-1`, computed from those blocks or distributed with the software as minimum chain
work is; a wrong anchor is detected when blocks are received. Header `A` is accepted from its
proof section only if its `mm_rhs` equals the anchor; the section's `N` and peaks then identify
the anchored tree. Holding a count `N'` and peaks for header `P`, it checks header `P + 1` with
that block's proof section:

1. `S = N'` and `0 < N - S <= C_max`, where `C_max = 62,500` chunks (a 4,000,000-byte block).
2. Appending the `ext` roots to the held peaks gives `peaks(T)`.
3. `mm_rhs` equals the commitment of `N`, `S`, `peaks(T)`.
4. The reads verify against `peaks(T)` as in Verification and `final` meets the target.

It then holds `N` and `peaks(T)` for header `P + 1`. Headers before `A` are checked by `h0` as
before.

Difficulty. `final` is the proof-of-work value. `nBits` is reset at activation and retargets
on a shortened period during a transition window (Deployment), then as before.

## Rationale

Reading on every hash, rather than on a selected few, is what makes every hash depend on the
chain and makes reads, performed on a held copy, the work that bounds mining (Motivation).
Read 0 in the parent requires holding the parent block before mining on it. Reads 1 to k-1 over
the whole chain require holding all of it.

Positions are chained because reads, not hashes, bound mining. If every position came from `h0`
alone, a miner holding a fraction `f` of the chain would compute `h0`, check the positions, and
read only when every chunk is held: `1/f^(k-1)` extra `h0` hashes per completed attempt and no
extra reads. With a 4.5 TH/s hasher, a holder of 7% of the chain would mine at the rate of a
full copy on disk. With chained positions, a miner that finds a missing chunk at read `i` has
already performed the reads before it. Only `a_1` (from `h0` and a parent chunk) is known before
a storage read, so a fraction-`f` holder spends `(1 + f + ... + f^(k-2)) / f^(k-2)` storage
reads per completed attempt against `k - 1` for a full holder: 1.4x at `f = 0.9`, 18x at `0.5`,
1.8e4x at `0.146` (measured, `ddpow-strong partial`). Each position also comes from a distinct
digest; deriving several positions from words of one digest makes them differ by fixed offsets,
which a holder of regions separated by those offsets exploits.

The commitment fixes which chunks are read before `h0` exists, so a miner cannot search for
chunks that produce a low `final`.

The proof section cannot be included in the block hash input: committing it in the header or the
transaction Merkle root changes `h0`, which changes the read positions it proves. It needs no
hash commitment because it has one valid value for a given header and chain; changing any byte
fails verification. Requiring it in every block, rather than relaying it separately, means no
valid block lacks one, so pruned nodes and light clients never depend on a party that holds the
tree's interior nodes to build it. `ext` lets a node without the parent block extend the
parent's peaks.

A proof alone shows only that its chunks match `mm_rhs`, not that `mm_rhs` commits to the real
chain. The anchor and the per-block bound `C_max` require every header's tree to extend the
anchored tree: a fork can fabricate at most `C_max` chunks per block it adds.

## Backwards compatibility

Hard fork. Hash-optimized ASICs lose their advantage: a miner cannot hash faster than it can
read the chain, so effective rate is bounded by random-read throughput over the held copy, not
by hash rate. The parent is cached, so an attempt costs `k - 1` storage reads: measured 1.2e4 to
3.4e4 attempts per second from one NVMe drive at `k = 8` (2.4e5 reads per second at queue depth
96), 7.0e6 from DRAM on a 24-thread CPU. Chained reads within an attempt are serial, so queue
depth comes from parallel attempts. Mining becomes a competition in storage read throughput that
requires possession of the chain. The header format is unchanged; its `mm_rhs` field, null
before `A`, carries the commitment.

Blocks gain the proof section, about 9 KB each (0.46 GB per year at 144 blocks per day).
Building its paths requires the tree's interior nodes: about 11 GB if levels 0 to 5 are
recomputed from a 4 KiB page per read (`data-dependent-pow.md`). Pruned nodes validate from the
peaks and the proof section. Light clients store about 9 KB per header instead of 80 bytes.
Node software must handle a failing proof section as a mutated copy of the block, as Bitcoin
Core handles mutated witness data.

## Deployment

Activation at height `A`, a multiple of 2016, so a retarget period starts at `A`.

- Block `A` MUST have `nBits = 0x1d479531`: 6.0e7 expected attempts per block, a 600-second
  spacing at 1.0e5 attempts per second. It is not computed from earlier blocks.
- Transition window, blocks `A` to `A + 2015`: the target retargets every 144 blocks, at
  heights `A + 144j` for `j = 1..14`, by the existing calculation and factor-4 clamp over the
  preceding 144 blocks, with a 144 x 600-second expected timespan. Blocks before `A` are never
  in the calculation.
- The next retarget is at `A + 4032`, then every 2016 blocks as before.

The reset is required. Before activation a block needs 2^256 / target attempts: 1.99e19 at
`nBits = 0x1900edba` (height 974606, network 3.1e16 hashes per second). With mining limited by
reads, the network performs far fewer: 1,000 NVMe drives at 3.4e4 attempts per second would take
about 18,000 years per block, and the 2016-block retarget would never be reached.

The reset value is set at the low end of the post-activation estimate (3 NVMe drives at queue
depth 96; per-machine rates span 1.2e4 to 7.0e6), because the two errors are not symmetric. A
network faster than the estimate mines blocks at intervals shorter than 600 seconds, and each
144-block retarget raises the work by up to 4x: 1e4 times the estimate is corrected after 7
retargets (1,008 blocks). A network slower than the estimate mines blocks at intervals longer
than 600 seconds: 0.1 times the estimate takes about 10 days to reach the first retarget. The
window's 14 retargets span a factor of 4^14 = 2.7e8. Blocks mined faster than 600 seconds during
the window issue their subsidy earlier; the window limits this to its 2016 blocks.

## Security

Outsourcing: a miner without the chain can send each `h0` to a holder (32 bytes in each
direction per attempt) or fetch chunks (64 bytes and one serial round trip per read). At rates
limited by reads, this traffic is feasible over a network connection: 3.4e4 attempts per second
from one NVMe drive is 15 MB/s of chunks. In both cases the reads are performed on the holder's
copy. The rule requires one copy per unit of read throughput, not one per hashing device,
bounded by the random-read rate one copy's storage serves: measured 2.4e5 reads per second from
one NVMe drive, 5.6e7 from DRAM on a 24-thread CPU; a multi-channel DRAM server serves more.
Partial holding: costs storage reads per completed attempt as given in Rationale. A partial
holder may instead fetch missing chunks from a remote holder, at `64 x (k - 1) x (1 - f)` bytes
and up to `k - 1` serial round trips per attempt; chaining does not prevent this; its cost is
that bandwidth, compared with the cost of storing the missing part locally. Grinding (searching
over chunks for a low `final`): prevented by the commitment. Forged reads: every node checks
each chunk's path to its own peaks, so a block whose reads do not match the chain is rejected.
Fabricated trees: a proof checked against peaks taken from the header alone passes with
fabricated chunks at the cost of hash attempts alone, about 6.0e7 attempts per block after the
reset. Checked from the anchor (Header verification without the chain), a fork of `m` blocks
holds at most `m x C_max` fabricated chunks, 0.6% of about 1.1e10 at `m = 1,000`; reads 1 to `k
- 1` have positions in blocks shared with the honest chain with at least the remaining
probability each, so fabricated headers require the real chain and real reads. Proof
withholding: a block without its proof section is invalid. Mutated proofs: a peer can relay a
block with a corrupted section; nodes reject that copy without marking the block hash invalid
(Specification). The proof-of-work security model changes from aggregate hash rate to aggregate
read throughput over held chains; its concentration properties (disk versus DRAM cost per unit
rate) require analysis before deployment.

## Reference

Software prototype and measurements: `ddpow-strong/` (chained read-per-hash miner, memory and
disk regimes, partial-holder comparison of chained and independent positions, Merkle mountain
range proof roundtrip; `chain`: proof sections, a pruned validator and a light client from the
anchor, mutated sections, fabricated trees, the `C_max` bound). A related design that reads the
chain on only a selected share of hashes, and the shared structures (chunking, the Merkle
mountain range, the commitment, the proofs), is described in `data-dependent-pow.md`.

Node implementation (regtest): branch `ddpow-strong` of the Knots fork (`~/src/bitcoin`),
`-ddpowstrong=1` and `-ddpowanchor=<mm_rhs of block A>`. It implements the rule (chained
reads, no pre-filter, unshifted target), the node's miner, the proof section in `block` and
`cmpctblock` messages and `submitblock` (required under the rule, refused as a mutated copy if
missing or failing; stored per block, not in the block files), header verification from the
anchor for headers-first synchronization, and pruned validation from the node's own peaks.
Its section is the serialized header proof (`N`, `S`, peaks, `ext`, and per read the chunk
and path, with compact-size lengths), which carries the peaks this specification omits.
Checked against this prototype's vectors and an independent Python implementation
(`feature_ddpow.py`, `p2p_ddpow_headers.py`, `feature_ddpow_pruned.py`, each with `--strong`).
