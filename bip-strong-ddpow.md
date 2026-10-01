    BIP: XXXX
    Title: Strong data-dependent proof of work
    Author: iohzrd
    Status: Draft
    Type: Standards Track
    Layer: Consensus (hard fork)
    Created: 2026-09-28
    License: BSD-2-Clause

## Abstract

This consensus rule requires reads of block chain bytes for every mining hash and hashes those
bytes into the value checked against the difficulty target. The first read position comes from
the header hash; each later position comes from a digest over the chunk read before it, and
positions span the whole chain from the genesis block. Because every hash requires reads, and
each position of an attempt after the first is known only after the previous read is performed,
a miner holding only part of the chain spends reads on attempts it cannot complete. Each block
carries a proof of its reads, so a node verifies it from its own Merkle mountain range peaks
without chain data; the chain's size is a cost to miners, not to validators. At activation the
difficulty is reset, the proof-of-work limit is raised, and each retarget's timespan includes
the interval before its period.

## Motivation

Today a miner needs no block chain data and runs no node. A pool assembles the candidate block,
reduces it to a header (164 bytes in the version 2 form required from height 961,640), and sends
that header to hashing hardware. The hardware iterates over nonces and returns any whose hash
meets a target it is given. It stores no block chain and validates nothing. This lets hashing
concentrate at parties that hold no chain, and lets miners extend blocks they have not checked.

To make holding the chain a condition of mining, the work that bounds mining must be reads of
chain data. Reading the chain on only a small share of hashes does not achieve this: the reads
are few, a miner without the chain obtains them from a holder per candidate, and the hash work
that bounds mining needs no chain. This rule requires chain reads for every hash, so reads, not
hashes, bound mining. A party without a copy adds no read throughput: every chunk it fetches is
read from a holder's disk or memory and then crosses a network link, so its rate is at most the
rate at which the holder mines with the same copy, and its hashes save the holder only the
header's last BLAKE2b stage, one or two of the BLAKE2b compression function evaluations of an
attempt, against 264 for its eight steps over chunks (Security).

## Specification

Chunks. Every block from genesis, in height order, in its network serialization with witness
data (header, transaction count and transactions), without its proof section, split into
4,096-byte pieces, the last zero-padded.

Tree. `BLAKE2b-256` is unkeyed BLAKE2b with a 32-byte digest. `T` is a Merkle mountain range
over the chunks of blocks `0..P` (parent `P`): leaf `= BLAKE2b-256(0x00 || chunk)`, node
`= BLAKE2b-256(0x01 || left || right)`. `chunk(a)` is the chunk of leaf `a`. `N` = chunk count
of `0..P`; `S` = chunk count of `0..P-1`.

Commitment. The header field `mm_rhs` of a block at height `P + 1 >= A` MUST equal
`BLAKE2b-256(0x02 || N as u64le || S as u64le || bag(peaks(T)))`. With the peaks `p_0 .. p_m`
listed highest (leftmost) first, `bag = node(p_0, node(p_1, ... node(p_{m-1}, p_m)))`; a single
peak bags to itself. `mm_rhs` is inside the header, so the chunk at every position is fixed
before hashing. Before `A` this rule does not check `mm_rhs`.

Per attempt (header `H`, `k = 8`). `h0` is the output of the last BLAKE2b-256 stage of the
version 2 header hash (`hash` after the second `blake2b_nokey` call in `CBlockHeader::GetHash`,
Bitcoin Knots
[`src/primitives/block.cpp`](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/primitives/block.cpp#L13-L105);
every stage for test headers in
[`src/test/data/block_header_v2.json`](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/test/data/block_header_v2.json)),
before the XOR mask and byte reversal that produce the block hash: the value a BLAKE2b mining
chip outputs. `mask` is that XOR mask: the tagged SHA-256 (tag `Bitcoin block hash PoW XOR mask`)
of the header's `m_xor_key` with its first `m_xor_key_mask_clear_bits` bits cleared (in byte
order, high bit first), or zero if `m_xor_key` is zero. `mr(d)` is `d XOR mask` with its bytes
reversed; the block hash is `mr(h0)`.

    x_0   = h0                                         (the mining chip's output)
    a_0   = S + idx(x_0, N - S)                        parent block
    x_i   = BLAKE2b-256( x_{i-1} || chunk(a_{i-1}) )   i = 1..k
    a_i   = idx(x_i, N)                                i = 1..k-1, whole chain
    final = x_k

`idx(x, n)` is `u64le(x[0..8]) mod n`. The proof of work is valid if `mr(final)`, read as a
256-bit number as a block hash is, is `<= target(nBits)`. The block hash remains `mr(h0)` and is
not compared with the target.

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
    N, S    u64le each
    ext     32 bytes each    roots of the aligned cover of [S, N) (the parent's chunks)
    per read i = 0..k-1:
      chunk(a_i)             4,096 bytes
      path_i                 32 bytes per level, siblings from leaf a_i to its peak, lowest first

The count of `ext` is fixed by `S` and `N`; the length of `path_i` is the height of the peak
holding `a_i`. For a parent of at most `C_max` chunks (below), `ext` holds at most 17 roots.
A peak's height is below 64, so a section is at most 49,460 bytes (17 `ext` roots, 8 paths of
63 levels); while `N < 2^28` (a chain below 1 TiB), at most 40,244 bytes (paths of 27 levels).
The section is not part of the block's weight or of its serialized size under the
4,000,000-byte limit. A block whose proof section is absent or fails verification is invalid in
that form (Fault attribution).

Verification. A node keeps, for each validated block `P` from `A - 1` on, the state of the tree
over blocks `0..P`: `N`, `peaks(T)` (one per set bit of `N`), and the `c` aligned cover roots of
block `P`'s chunks, `8 + 32 x (popcount(N) + c)` bytes, at most 1,448 while `N < 2^28`. It
computes a block's state from its parent's state by appending the block's chunks as leaves, and
the state for `A - 1` while connecting blocks from genesis, or from the anchor (Header
verification) and block `A - 1`. The state at an earlier height cannot be computed from the
state at a later one, so the node keeps it per block to validate blocks on other branches and to
reorganize. To check block `P + 1` against the state kept for `P`, it requires `mm_rhs` equal to
the commitment of that state, and `S`, `N` and `ext` equal to its counts and roots; recomputes
`h0`; then for `i = 0..k-1` computes `a_i`, checks that `chunk(a_i)` hashed with the siblings in
`path_i` equals the peak holding `a_i` (at level `j` the sibling is the left input if bit `j` of
`a_i` is 1), and computes `x_{i+1}` from the proof's chunk; and compares `final` with the target.
No chain data is read: archival and pruned nodes verify the same way.

Header verification without the chain. For headers-first synchronization and light clients. The
node starts from an anchor: the count `N'` and peaks of the tree over blocks `0..A-2`, which
header `A - 1` would commit to (8 bytes and 32 bytes per peak), computed from those blocks or
distributed with the software. A node that receives blocks `0..A-2` detects a wrong anchor; a
node that receives only headers does not. Holding the count `N'` and peaks of the tree over
blocks `0..P-1` for header `P`, starting with the anchor for header `A - 1`, it checks header
`P + 1` with that block's proof section:

1. `S = N'` and `0 < N - S <= C_max`, where `C_max = 977` chunks (a 4,000,000-byte block,
   4,000,000 / 4,096 rounded up).
2. Appending the `ext` roots to the held peaks gives `peaks(T)`.
3. `mm_rhs` equals the commitment of `N`, `S`, `peaks(T)`.
4. The reads verify against `peaks(T)` as in Verification and `final` meets the target.

It then holds `N` and `peaks(T)`, the tree over blocks `0..P`, for header `P + 1`, per header as
in Verification. Headers before `A` are checked by their block hash as before.

Fault attribution. Of the checks in this specification, a failure is a fault of the header, and
the node records the block hash as invalid, only if no proof section can make the header valid:
`nBits` differs from the required value; `mm_rhs` differs from the commitment of the state held
for the parent; or `final` misses the target after the reads verify against held peaks, or
against peaks derived in steps 1 and 2 with step 3 passing. Every other failure is a fault of
the section: the section is absent or malformed; `S`, `N` or `ext` differ from the node's
values; step 1 or 3 fails, since a wrong `ext` or `N` produces a commitment mismatch there; a
chunk hashed with its path does not equal its peak. The node rejects that copy without recording
the block hash. A node relays a block or header only after its proof section verifies, so a
failing section is a fault of the peer that sent it: the node disconnects that peer, as for a
mutated block.

Relay. `block` messages carry the proof section after the transactions, and `cmpctblock`
messages after the prefilled transactions. The protocol message size limit is raised from
4,000,000 to 4,049,460 bytes, so a block at the 4,000,000-byte serialized size limit fits with
the largest section. For headers-first synchronization a node sends `sendddpow` (no payload) to
ask a peer for `hdrproofs` messages in place of `headers`. A `hdrproofs` message is a
compact-size count and, per entry, a header and its proof section (a zero `len` for headers
before `A`). It holds at most 81 entries: 81 entries of at most 164 + 49,460 bytes and the
1-byte count are 4,019,545 bytes, below the message limit at any chain size; a message with
fewer than 81 entries ends the sender's chain, as a `headers` message with fewer than 2,000
does.

Difficulty. `final` is the proof-of-work value. From `A`, `powLimit` is `2^240 - 1` (compact
`0x1f00ffff`, 65,537 expected attempts per block) in place of `2^224 - 1`; it bounds `nBits`
and every retarget as before. `nBits` is reset at activation and retargets on a shortened period
during a transition window, then every 2016 blocks (Deployment).

## Rationale

Read 0 in the parent requires holding the parent block before mining on it. Reads 1 to k-1 over
the whole chain require holding all of it.

Chunks are 4,096 bytes, one page, so that memory holding the chain has as little advantage over
disks holding it as the chunk size allows. A storage device reads whole pages, so up to one
page its reads per second do not depend on the chunk size. Memory transfers a chunk in units
smaller than a page, so a smaller chunk costs memory fewer bytes per read and raises its reads
per second relative to a disk's; with 4,096-byte chunks, memory's reads per second per copy are
at most its bandwidth divided by 4,096 bytes. A copy split across devices, such as accelerator
memory joined by an interconnect, moves 4,096 bytes across the interconnect for each read held
on another device. A chunk larger than a page would cost a disk more than one page per read.
Each step hashes the whole chunk: a step depending on a digest of the chunk would let a miner
store digests instead of chunks, and a step depending on part of the chunk would let memory
transfer only that part. The costs are 33 BLAKE2b compression function evaluations per step
and 4,096 bytes per read in the proof section (Costs, Open questions).

Measurement (informative; no requirement of this specification depends on it). One laptop (AMD
Ryzen AI 9 HX 370, 24 threads, 30 GiB LPDDR5X, one Micron MTFDKBA1T0QFM NVMe drive), 2026-09-30,
`k = 8`, chained reads, with the `ddpow-strong` prototype (`bench --read-bytes`; method in its
README). RAM: an 8 GiB dataset, 8 interleaved attempts per thread. NVMe: a 16 GiB file read with
O_DIRECT, 192 threads; read 0 from the parent in RAM. In the RAM runs each read is folded into
the digest with XOR and a 64-bit mix instead of hashed, so memory, not this processor's hashing,
sets the rate. In the NVMe runs each read is hashed whole; folding instead gave the same rate at
4 KiB (2.24e4 attempts/s), so the drive sets it. The proof section column is not measured: it is
the largest section the Block proof encoding allows at that chunk size while the chain is below
1 TiB (`C_max` of 62,500, 15,625, 7,813, 3,907 and 977 chunks; at most 29, 25, 23, 21 and 17
`ext` roots; paths of at most 33, 31, 30, 29 and 27 levels).

| read size | RAM (attempts/s) | NVMe (attempts/s) | RAM over NVMe | proof section, at most (bytes) |
| --------- | ---------------- | ----------------- | ------------- | ------------------------------ |
| 64 B      | 1.83e7           | 2.18e4            | 838x          | 9,908                          |
| 256 B     | 1.24e7           | 2.21e4            | 562x          | 10,804                         |
| 512 B     | 7.59e6           | 2.22e4            | 342x          | 12,532                         |
| 1 KiB     | 5.50e6           | 2.22e4            | 248x          | 16,308                         |
| 4 KiB     | 1.84e6           | 2.23e4            | 82x           | 40,244                         |

The drive's rate did not change with read size; the memory rate fell with it, from 1.46e8 reads
per second at 64 bytes to 1.47e7 at 4 KiB (60 GB/s). At 4 KiB, RAM's advantage over the drive
per copy is 10 times smaller than at 64 bytes.

Positions are chained because reads, not hashes, bound mining. If every position came from `h0`
alone, a miner holding a fraction `f` of the chain would compute `h0`, check the positions, and
read only when every chunk is held: `1/f^(k-1)` `h0` hashes and `k - 1` reads per completed
attempt. A hasher computing `H` values of `h0` per second then completes `H x f^(k-1)` attempts
per second, a rate set by `H`, not by its reads. With chained positions, a miner that finds a
missing chunk at read `i` has already performed the reads before it. Only `a_1` (from `h0` and a
parent chunk) is known before a storage read, so a fraction-`f` holder spends
`(1 + f + ... + f^(k-2)) / f^(k-2)` storage reads per completed attempt against `k - 1` for a
full holder: 1.4x at `f = 0.9`, 18x at `0.5`, 1.7e4x at `0.146`.

The read count `k` sets two costs against each other. A proof section carries `k` chunks with
their paths, so its size grows linearly with `k`; the storage reads a holder of a fraction `f`
of the chain spends per completed attempt, relative to a full holder, grow exponentially with
`k` (the formula above). `k` does not change the ratio between miners whose rates are bounded by
their random reads, whatever their storage: each performs `k - 1` storage reads per attempt, so
`k` divides every such rate alike. In the table, sizes are while `N < 2^28` (52,560 blocks per
year carry 52,560 times the section), and the `f` columns give that relative read count to two
decimal places:

| `k` | section (bytes) | % of a full block | `f = 0.9` | `f = 0.75` | `f = 0.5` |
| --- | --------------- | ----------------- | --------- | ---------- | --------- |
| 4   | 20,404          | 0.51%             | 1.12x     | 1.37x      | 2.33x     |
| 6   | 30,324          | 0.76%             | 1.25x     | 1.93x      | 6.20x     |
| 8   | 40,244          | 1.01%             | 1.40x     | 2.78x      | 18.14x    |
| 12  | 60,084          | 1.50%             | 1.79x     | 6.18x      | 186.09x   |
| 16  | 79,924          | 2.00%             | 2.31x     | 14.77x     | 2,184.47x |

With `k = 8` the section is at most 1.01% of a full block while a holder of half the chain
spends 18.14 times a full holder's storage reads per completed attempt.

Each position comes from a distinct digest. A digest has four 8-byte words, so positions taken
from one digest reuse words when `k - 1` exceeds 4; two positions from the same word differ by
an offset fixed in advance, whether both are held depends on which part of the chain is held,
and a holder can choose that part to complete more than `f^(k-1)` of attempts.

No value varies after `h0`: `final` is a function of `h0` and the chunks `mm_rhs` commits to, so
each attempt is one header, and a miner varies header fields (nonces, extranonce, time,
transactions) to make another. A nonce entering after `h0` would give new `final` values from
the same chunks without new reads.

The commitment fixes the contents of every chunk position before `h0` exists, so a miner cannot
search over chunk contents for a low `final`.

Proof sections are not necessary to check a block's work: a node holding blocks `0..P` can read
the chunks of block `P + 1`'s attempt from its own copy and recompute `final`. Without proof
sections, however, every validating node would have to keep every block from genesis, since
reads 1 to `k - 1` fall anywhere in the chain, so pruned nodes could not validate; a node could
not check a header's work before downloading every block before it, which removes the work check
that bounds the headers a peer can make a synchronizing node store; and light clients could not
check work at all.

The proof section cannot be included in the block hash input: committing it in the header or the
transaction Merkle root changes `h0`, which changes the read positions it proves. It needs no
hash commitment because it has one valid value for a given header and chain; changing any byte
fails verification. Requiring it in every block, rather than relaying it separately, means no
valid block lacks one, so a validator, pruned or archival, never depends on a party that holds
the tree's interior nodes to build it; a header follower receives each header's section in
`hdrproofs` from peers that keep sections or can build them. `ext` lets a node without the
parent block extend the parent's peaks. The section is outside the block's weight and serialized
size limits, so it takes no transaction capacity: counted in weight at one unit per byte, a
section of 40,244 bytes (its bound while `N < 2^28`) would take 5.03% of the 800,000 weight
units allowed until 1 September 2027 and 1.01% of 4,000,000.

A proof alone shows only that its chunks match `mm_rhs`, not that `mm_rhs` commits to the real
chain. The anchor and the per-block bound `C_max` require every header's tree to extend the
anchored tree: a fork can fabricate at most `C_max` chunks per block it adds.

## Backwards compatibility

Hard fork. The header format is unchanged. Its `mm_rhs` field, added as a merge-mining hook
for future use
([bitcoinknots/bitcoin@9a8127194d](https://github.com/bitcoinknots/bitcoin/commit/9a8127194dbc56925e6215e1e48e2733b4e8b32b)),
is hashed in the header hash's `Merge-mining hook` stage
([`block.cpp` line 57](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/primitives/block.cpp#L57))
and not checked before `A`; it carries the commitment and is no longer available for merged
mining.

## Costs

Mining. A miner cannot complete attempts faster than it reads the chain. With the parent cached,
an attempt costs `k - 1` random 4,096-byte reads from the rest of the chain, so a copy with
random read rate `R` completes at most `R / (k - 1)` attempts per second. Reads within an
attempt are serial, so parallel reads come from parallel attempts. An attempt evaluates the
BLAKE2b compression function 264 times over chunks (33 per step, a 4,128-byte input) besides
the header's stages.

Proof sections. At most 40,244 bytes per block while `N < 2^28`: at 52,560 blocks per year
(600-second spacing), at most 2,115,224,640 bytes per year. Building paths requires the tree's
interior nodes: at level 1 and above, `N - popcount(N)` nodes, fewer than `32 x N` bytes (1/128
of the chain's size), with each path's level-0 sibling recomputed from its chunk. No node needs
to store sections: a node may discard a block's section once the block is validated, and a node
holding the blocks and the tree's interior nodes builds any section again on request, so
sections cost bandwidth, not storage.

Validation. Pruned nodes validate from the per-block tree state (Verification) and the proof
section. Light clients download at most 40,244 bytes of proof section with each 164-byte header
while `N < 2^28`, and keep `N` and the peaks, `8 + 32 x popcount(N)` bytes (at most 904 while
`N < 2^28`), per header.

## Deployment

Activation at height `A`, a multiple of 2016 above 961,640, so a retarget period starts at `A`
and every block from `A` has a version 2 header.

- Block `A` MUST have `nBits = 0x1c400000`: 17,179,869,183 expected attempts per block,
  600-second spacing at 2.86e7 attempts per second. It is not computed from earlier blocks.
- From `A`, every retarget measures its timespan from the timestamp of the last block before its
  period to that of the period's last block: `L` intervals for a period of `L` blocks.
- Transition window: retargets at heights `A + 144j` for `j = 1..14`, the last at `A + 2016` in
  place of the 2016-block retarget, each over the 144 blocks before it (from the timestamp of
  block `A + 144(j-1) - 1` to that of block `A + 144j - 1`), with a 144 x 600-second expected
  timespan and the factor-4 clamp. Of the blocks before `A`, only the timestamp of block `A - 1`
  enters a calculation.
- The next retarget is at `A + 4032`, over blocks `A + 2016` to `A + 4031`, then every 2016
  blocks as before, with the timespan measured as above.

Without the reset, 600-second spacing at the difficulty of block 974,606 (`nBits = 0x1900edba`,
1.986e19 attempts per block) requires 3.31e16 attempts per second, and from `A` each attempt
requires `k - 1 = 7` chunk reads besides the parent: 2.32e17 random chunk reads per second
across the network. A network with `r` times fewer reads mines at `600 r`-second intervals until
the next 2016-block retarget, which lowers the difficulty by at most a factor of 4. The reset
target is one quarter of the existing `powLimit`, which would let retargets lower the difficulty
by at most a factor of 4, so `powLimit` is raised (Difficulty): the new limit is 262,144 times the
reset target.

The reset value is set low because the two errors are not symmetric. A network `r` times faster
than 2.86e7 attempts per second mines blocks at `600 / r`-second intervals, and each 144-block
retarget raises the work by up to 4x, so the spacing reaches 600 seconds after `ceil(log4 r)`
retargets: 7 retargets (1,008 blocks) at `r = 1e4`. A network `r` times slower mines blocks at
`600 r`-second intervals and reaches the first retarget after `86,400 r` seconds: 10 days at
`r = 10`. The window's 14 retargets span a factor of 4^14 = 2.7e8. Blocks mined faster than 600
seconds during the window issue their subsidy earlier; for `r` at most 4^14 the window limits
this to its 2016 blocks.

The timespan is measured from the last block of the previous period so that the measured
timespans of consecutive periods sum to the time between their end blocks, which the 2-hour
future-timestamp limit bounds. The existing calculation measures from the period's first block,
so the interval before each period's first block is in no period: a majority of miners can hold
every timestamp except each period's last near the median time past and set each period's last
block to the current time; each period then measures from its first block's held-back timestamp
to the current time, and the target increases by up to 4x per retarget. With 144-block periods
the window would allow this 14 times.

## Security

Outsourcing: a miner without the chain can send each `h0` to a holder or fetch the chunks
remotely. Sending `h0` (32 bytes per attempt; the holder returns only attempts that meet the
target) saves the holder the header's last BLAKE2b stage (the first does not depend on the
nonce), one or two compression function evaluations against 264 for the steps over chunks; the
holder still performs every read and every step. Fetching chunks costs 4,096 bytes and one
serial round trip per read, 28,672 bytes per attempt with the parent held. Each fetched chunk is
read from the holder's disk or memory before it crosses the link, so the fetcher's rate is at
most the holder's read rate, the rate at which the holder mines with the same copy, and is
further bounded by the link at 28,672 bytes per attempt. Fetching adds no
read throughput. The rule requires one copy per unit of read throughput, not one per hashing
device: a copy with random read rate `R` serves at most `R / (k - 1)` attempts per second
(Costs). Partial holding: costs storage reads per completed attempt as given in Rationale. A
partial holder may instead fetch missing chunks from a remote holder, at
`4,096 x (k - 1) x (1 - f)` bytes and up to `k - 1` serial round trips per attempt; chaining does not prevent this; its cost
is that bandwidth, compared with the cost of storing the missing part locally. Forged reads:
every node checks each chunk's path to its own peaks. Fabricated trees: a proof checked against
peaks the prover supplies, with only `mm_rhs` from the header, passes with fabricated chunks at
the cost of hash attempts alone, 17,179,869,183 attempts per block at the reset `nBits`. Checked from
the anchor, a fork of `m` blocks after the anchor holds at most `m x C_max` fabricated chunks,
and each of reads 1 to `k - 1` falls in chunks the anchor fixes with probability at least
`1 - m x C_max / N`, so fabricated headers require reads of the anchored chain. `m` counts every
block after the anchor, so the fabricated share can grow by `C_max` chunks per block.

## Open questions

- Chain work across activation: a block at `nBits = 0x1900edba` carries 1.16e9 times the work
  of a block at the reset `nBits`. Retargets before `A` accept compressed timestamps, so an
  alternative pre-activation segment can raise one 2016-block period's difficulty 4x, adding
  3 x 2016 x 1.986e19 = 1.20e23 attempts of work, the work of 6.99e12 blocks at the reset `nBits`.
  How chains that diverge before `A` are compared is not specified.
- Block announcements: how a node obtains the proof section of a block announced by `headers`
  or `inv` is not specified.
- Header followers: each `hdrproofs` entry carries the header's full proof section (Relay), at
  most 40,244 bytes while `N < 2^28` against 164 bytes of header, of which at most 564 are the
  tree extension (`len`, `N`, `S` and at most 17 `ext` roots). How a header follower can check
  headers' work with less than one section per header is not specified.
- Stripped blocks: a node holding the chain could ask a peer, between `version` and `verack` (a
  BIP434 `feature` message; Bitcoin Knots does not implement BIP434, and without it a
  `sendddpow` message), to omit the section from `block` and `cmpctblock` messages, and check
  the reads against its own chain. A block's validity would not change: its work must be valid
  whether or not its section was sent.
- Concentration: the security model changes from aggregate hash rate to aggregate read
  throughput over held chains; its concentration properties (disk versus DRAM cost per unit
  rate) are not analyzed.
- Test vectors: none yet.

## Reference implementation

A regtest implementation in a fork of Bitcoin Knots implements the rule, the node's miner, the
proof section in `block`, `cmpctblock` and `submitblock` (stored per block, not in the block
files), `sendddpow` and `hdrproofs`, header verification from an anchor set by a configuration
option, pruned validation, and fault attribution. It differs from this specification in:

- Chunk size: 64 bytes, not 4,096.
- Section encoding: `N`, `S`, the peaks, `ext`, per read the chunk and path, with compact-size
  counts and no `len` field.
- `hdrproofs` limit: 128 entries per message sent and 2,000 accepted, not 81.
- Message size limit: 4,000,000 bytes, not raised.
- Difficulty: a fixed regtest target; no Deployment rules and no raised `powLimit`.

Its functional tests check it against an independent Python implementation.

## Prior art

Reads of chain data selected by a hash:

- [Hashimoto](http://diyhpl.us/~bryan/papers2/bitcoin/meh/hashimoto.pdf) (Dryja, undated,
  cited as 2014): the header hash selects 64 transaction identifiers across the whole chain;
  verifiers repeat the lookups against their own chain. This rule has the same order (header
  hash, then reads, then the target check) and reads raw block bytes at chained positions, with
  proofs.
- [Popescu](http://web.archive.org/web/20251114113328/http://trilema.com/2016/the-necessary-prerequisite-for-any-change-to-the-bitcoin-protocol/)
  (2016): a digest of the nonce-th byte of every preceding block enters the header hash.
  Selection by the nonce alone lets one digest table serve every miner; here positions depend on
  the whole header.
- [EWoK](https://eprint.iacr.org/2017/1067) (Armknecht, Bohli, Karame, Li, 2017): considers
  reading the chain after the proof of work is solved, the order used here, and rejects it
  because "such a solution only ensures that the pool operator (or any other entity) stores the
  full blockchain". NEC holds [US10397328B2](https://patents.google.com/patent/US10397328B2/en)
  on this work; its scope relative to this rule has not been analyzed.
- [Arweave SPoRA, ANS-103](https://github.com/ArweaveTeam/arweave-standards/blob/master/ans/ANS-103.md)
  (Williams, Berman, 2020): one chunk of the chain's data read per attempt, proven by Merkle
  paths to committed roots. Its predecessor put one chunk, fixed by the chain state, into every
  preimage; ANS-103 states that a remote storage and computation pool could then serve preimages
  "to millions of clients per second via a Gbit Internet link" and that such a pool "has been
  evidenced in the Arweave network". [Arweave 2.6](https://2-6-spec.arweave.net/) adds
  encoding of the data per mining address and a verifiable delay function that limits reads per
  second; this rule has neither.

Sequential reads, each position derived from the previous step:

- [Permacoin](https://www.ieee-security.org/TC/SP2014/papers/Permacoin_c_RepurposingBitcoinWorkforDataPreservation.pdf)
  (Miller, Juels, Shi, Parno, Katz, 2014): sequential reads of a Merkle-committed archive, each
  position depending on the previous step, each read proven by a Merkle path. Each step is
  signed with the payout key, so outsourcing a step hands over the key. This rule has no key
  step: the header commits to the coinbase, so a party performing reads for a miner cannot
  redirect the reward.
- [Merkle Tree Proof](https://arxiv.org/abs/1606.03588) (Biryukov, Khovratovich, 2016): 70
  sequential reads of a generated dataset, each opened by a Merkle path to a committed root.
  [Attacks on its deployment](https://blog.zorinaq.com/attacks-on-mtp/) include openings not
  checked against their positions; here a verifier computes each `a_i` and folds each path by it.
- [Lerner](https://bitslog.com/2014/11/03/proof-of-local-blockchain-storage/) (2014,
  [revised 2015](https://bitslog.com/2015/09/16/proof-of-unique-blockchain-storage-revised/)):
  timed challenges over the chain at chained indices, with the chain encoded per node identity so
  one copy cannot answer for many nodes; a peer challenge, not proof of work.

Generated datasets:

- [Dagger-Hashimoto](https://ethereum.org/developers/docs/consensus-mechanisms/pow/mining/mining-algorithms/dagger-hashimoto/)
  and [Ethash](https://ethereum.org/developers/docs/consensus-mechanisms/pow/mining/mining-algorithms/ethash/):
  Hashimoto's reads over a dataset generated from a seed. Dagger-Hashimoto listed full chain
  storage as an optional goal; Ethash removed it. A generated dataset does not require holding
  the chain.

Commitments:

- [Merkle mountain range](https://github.com/opentimestamps/opentimestamps-server/blob/master/doc/merkle-mountain-range.md)
  (Todd, 2012): the tree structure used here.
- [RFC 6962](https://www.rfc-editor.org/rfc/rfc6962.txt) (2013): the leaf and node prefixes
  `0x00` and `0x01`.
- [FlyClient](https://eprint.iacr.org/2019/226) (Bünz, Kiffer, Luu, Zamani, 2019) and
  [ZIP 221](https://zips.z.cash/zip-0221) (Zcash, 2019): each header commits to a Merkle mountain
  range through its parent; the leaves are header-derived values, not block bytes.

Outsourcing and archival requirements:

- [Nonoutsourceable scratch-off puzzles](https://www.cs.umd.edu/~jkatz/papers/nonoutsourceable.pdf)
  (Miller, Kosba, Katz, Shi, 2015): a puzzle is nonoutsourceable if a party able to mine for
  others can take the reward. This rule does not meet that criterion (Security).
- [Todd](https://www.mail-archive.com/bitcoin-dev@lists.linuxfoundation.org/msg03178.html)
  (2015): each block commits to a hash of the previous block's witness data with a per-miner
  prefix; once per block, outside the hashing loop.

Searches of papers, forums, mailing lists, specifications and code found no precedent for raw
serialized block bytes as committed leaves, a required read in the parent block, or proofs
carried with headers during headers-first synchronization.
