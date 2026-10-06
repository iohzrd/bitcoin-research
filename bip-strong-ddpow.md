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
bytes into the value checked against the difficulty target. The first read position comes from the
header hash; each later position comes from a digest over the chunk read before it, and positions
span the whole chain from the genesis block. Before a chunk is hashed it is XORed with seven chunks
of earlier blocks, whose positions are computed from the hash of the block containing the chunk. A
miner that can recompute a chunk's bytes without storing them, such as bytes it generated from a
seed and included in a block, still has to read stored data for that chunk unless it can also
recompute all seven of those chunks. Because every hash requires reads, and each position of an
attempt after the first is known only after the previous read is performed, a miner holding only
part of the chain spends reads on attempts it cannot complete. A node checks a block's work by
reading its own copy of the chain. At activation the difficulty is reset, the proof-of-work limit
is raised, and each retarget's timespan includes the interval before its period.

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

Chunks. Each block from genesis, in its network serialization with witness data (header,
transaction count and transactions), is split separately into 4,096-byte pieces, its last piece
zero-padded; the chunks of all blocks are taken in height order. For a block at height `P + 1`
(parent `P`), the chunk space is the chunks of blocks `0..P` of its chain: `N` is their count and
`S` the count of blocks `0..P-1`, so the parent's chunks are `[S, N)`; `first_b` is the position
of block `b`'s first chunk. `chunk(a)` is the chunk at position `a`.

Packing (`m = 7`). `BLAKE2b-256` is unkeyed BLAKE2b with a 32-byte digest. `I_b` is block `b`'s
block hash as 32 bytes in the order `hashPrevBlock` serializes it. The partners of chunk `u` of
block `b` (position `first_b + u`) are: none if `first_b = 0`; every position in `[0, first_b)`
if `first_b <= m`; otherwise `m` distinct positions taken in order from the 8-byte words of
`BLAKE2b-256(0x03 || I_b || LE32(u) || LE32(t))` for `t = 0, 1, ...`, each word read as `u64le`
and reduced modulo `first_b`, a position already taken skipped. `packed(a)` is `chunk(a)` XORed
with `chunk(p)` for each partner `p` of `a`. Packing gives the selection as steps, with examples.

Per attempt (`k = 8`). `h0` is the output of the last BLAKE2b-256 stage of the version 2
header hash (`hash` after the second `blake2b_nokey` call in `CBlockHeader::GetHash`,
Bitcoin Knots
[`src/primitives/block.cpp`](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/primitives/block.cpp#L13-L105);
every stage for test headers in
[`src/test/data/block_header_v2.json`](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/test/data/block_header_v2.json)),
before the XOR mask and byte reversal that produce the block hash. `mask` is that XOR mask: the
tagged SHA-256 (tag `Bitcoin block hash PoW XOR mask`) of the header's `m_xor_key`, with the
first `m_xor_key_mask_clear_bits` bits of that digest cleared (in byte order, high bit first),
or zero if `m_xor_key` is zero. `mr(d)` is `d XOR mask` with its bytes reversed; the block hash
is `mr(h0)`.

    x_0   = h0                                         (blake2b_2 in the test vectors)
    a_0   = S + idx(x_0, N - S)                        parent block
    x_i   = BLAKE2b-256( x_{i-1} || packed(a_{i-1}) )  i = 1..k
    a_i   = idx(x_i, N)                                i = 1..k-1, whole chain
    final = x_k

`idx(x, n)` is `u64le(x[0..8]) mod n`. The proof of work is valid if `mr(final)`, read as a
256-bit number as a block hash is, is `<= target(nBits)`. The block hash remains `mr(h0)` and is
not compared with the target.

Validation. A node checks a block's work from its own copy of blocks `0..P` of the block's
chain: each of the `k` reads takes a raw chunk and its partners, at most `k x (m + 1) = 64` raw
chunk reads, or one read each from a stored copy of the packed chunks. A block whose `mr(final)`
exceeds `target(nBits)` is invalid. A node MUST NOT connect a block before checking its work. A
node that does not hold every ancestor's data, or cannot read a chunk from its copy, has not
checked the work: it records no block as invalid for that reason and checks the work once it
holds the data. Blocks, compact blocks and headers are relayed as before.

Difficulty. `final` is the proof-of-work value. From `A`, `powLimit` is `2^240 - 1` (compact
`0x1f00ffff`, 65,537 expected attempts per block) in place of `2^224 - 1`; it bounds `nBits`
and every retarget as before. `nBits` is reset at activation and retargets on a shortened period
during a transition window, then every 2016 blocks (Deployment).

## Rationale

Read 0 in the parent requires holding the parent block before mining on it. Reads 1 to k-1 over
the whole chain require holding all of it.

Chunks are 4,096 bytes, one page (here: the 4,096-byte logical block of a drive formatted with
4,096-byte sectors, and the memory page of common operating systems), so that memory holding the
chain has as little advantage over drives holding it as the chunk size allows. A drive reads
whole logical blocks, so up to one page its reads per second do not depend on the chunk size.
Memory transfers a chunk in units smaller than a page, so a smaller chunk costs memory fewer
bytes per read and raises its reads per second relative to a drive's; with 4,096-byte chunks,
memory's reads per second per copy are at most its bandwidth divided by 4,096 bytes. A copy
split across devices, such as accelerator memory joined by an interconnect, moves 4,096 bytes
across the interconnect for each read held on another device. A chunk larger than a page would
cost a drive more than one logical block per read. Each step hashes the whole chunk: a step
depending on a digest of the chunk would let a miner store digests instead of chunks, and a step
depending on part of the chunk would let memory transfer only that part. The cost is 33
BLAKE2b compression function evaluations per step (Costs).

Measurement (informative; no requirement of this specification depends on it). One laptop (AMD
Ryzen AI 9 HX 370, 24 threads, 30 GiB LPDDR5X, one Micron MTFDKBA1T0QFM NVMe drive), 2026-09-30,
`k = 8`, chained reads, with the `ddpow-strong` prototype (`bench --read-bytes`; method in its
README). RAM: an 8 GiB dataset, 8 interleaved attempts per thread. NVMe: a 16 GiB file read with
O_DIRECT, 192 threads; read 0 from the parent in RAM. In the RAM runs each read is folded into
the digest with XOR and a 64-bit mix instead of hashed, so memory, not this processor's hashing,
sets the rate. In the NVMe runs each read is hashed whole; folding instead gave the same rate at
4 KiB (2.24e4 attempts/s), so the drive sets it.

| read size | RAM (attempts/s) | NVMe (attempts/s) | RAM over NVMe |
| --------- | ---------------- | ----------------- | ------------- |
| 64 B      | 1.83e7           | 2.18e4            | 838x          |
| 256 B     | 1.24e7           | 2.21e4            | 562x          |
| 512 B     | 7.59e6           | 2.22e4            | 342x          |
| 1 KiB     | 5.50e6           | 2.22e4            | 248x          |
| 4 KiB     | 1.84e6           | 2.23e4            | 82x           |

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
full holder: 1.4x at `f = 0.9`, 18x at `0.5`.

The read count `k` sets two costs against each other. A node without a packed copy reads
`k x (m + 1)` raw chunks to check a header, so its cost grows linearly with `k`; the storage
reads a holder of a fraction `f` of the chain spends per completed attempt, relative to a full
holder, grow exponentially with `k` (the formula above). `k` does not change the ratio between
miners whose rates are bounded by their random reads, whatever their storage: each performs
`k - 1` storage reads per attempt, so `k` divides every such rate alike. In the table, the `f`
columns give that relative read count to two decimal places:

| `k` | raw reads per header, `k x (m + 1)` | `f = 0.9` | `f = 0.75` | `f = 0.5` |
| --- | ----------------------------------- | --------- | ---------- | --------- |
| 4   | 32                                  | 1.12x     | 1.37x      | 2.33x     |
| 6   | 48                                  | 1.25x     | 1.93x      | 6.20x     |
| 8   | 64                                  | 1.40x     | 2.78x      | 18.14x    |
| 12  | 96                                  | 1.79x     | 6.18x      | 186.09x   |
| 16  | 128                                 | 2.31x     | 14.77x     | 2,184.47x |

With `k = 8` a node without a packed copy reads at most 64 raw chunks per header while a holder
of half the chain spends 18.14 times a full holder's storage reads per completed attempt.

Each position comes from a distinct digest. A digest has four 8-byte words, so positions taken
from one digest reuse words when `k - 1` exceeds 4; two positions from the same word differ by
an offset fixed in advance, whether both are held depends on which part of the chain is held,
and a holder can choose that part to complete more than `f^(k-1)` of attempts.

No value varies after `h0`: `final` is a function of `h0` and the chain's chunks, so each attempt
is one header, and a miner varies header fields (nonces, extranonce, time, transactions) to make
another. A nonce entering after `h0` would give new `final` values from
the same chunks without new reads.

The header commits to its parent's block hash, and each block hash commits that block's data
and its own parent's hash, so the contents of every chunk position are fixed before `h0` exists:
a miner cannot search over chunk contents for a low `final`.

A proof section could carry each read's chunk with a path to a tree the header commits to, so
that a node without the chain could check work. With packing, each read needs its chunk and its
`m` partners: with raw chunks as leaves, a section of `k x (m + 1)` chunks with their paths, at
most 318,004 bytes while `N < 2^28`; with packed chunks as leaves, every node must read raw
partners from the whole chain to extend its tree, which a pruned node cannot. This rule has no
proof sections: a node checks work from its own copy of the chain, and a node without one cannot
check work from `A`.

## Packing

Packing (Specification) XORs each chunk with `m = 7` raw chunks of older blocks before the walk
hashes it. This section gives what it prevents, how partners are selected, the bound it gives,
the choice of `m`, and the alternatives not taken.

### Regenerable data

A chunk is regenerable by a party if the party can compute it without a storage read. A party
that writes block data, a miner filling its own blocks or anyone paying fees for block space, can
write bytes it regenerates from a short secret: every field of a transaction it builds (outpoints
of its own coins, amounts, keys, deterministic signatures, pushed data) is a function of that
secret. Without the secret these bytes cannot be distinguished from random bytes, so no validity
rule can exclude them. Without packing, a read at a chunk wholly inside such data is computed
instead of performed: a party that can regenerate a fraction `q` of the chunk positions skips that
fraction of its storage reads and completes up to `1 / (1 - q)` times the attempts per second of
a miner with the same read rate, and `q` grows with every block it fills.

Packing makes the hashed value of each chunk depend on `m` other chunks that the writer neither
chose nor knew when writing. A packed chunk can be computed without a storage read only if the
chunk and all `m` partners are regenerable.

### Selection

The partners of chunk `u` of block `b` depend only on `I_b`, `u` and `first_b`, the number of
chunks in blocks `0..b-1`:

1. If `first_b = 0` (the genesis block) there are none. If `first_b <= m`, they are every
   position in `[0, first_b)`.
2. Otherwise, for `t = 0, 1, ...`, compute `e_t = BLAKE2b-256(0x03 || I_b || LE32(u) || LE32(t))`,
   a hash of 41 bytes.
3. Read the four 8-byte words of `e_t` in order, each as `u64le`, and reduce each modulo
   `first_b`. Take the result unless it is already taken.
4. Stop when `m` positions are taken.

`packed(first_b + u)` is `chunk(first_b + u)` XORed with the `m` partner chunks. In the following
example `I_b` is the 32 bytes
`c7e5c1fa198b8a71094338b52531e5f906ac715adfd26302dba30c3818f0742b` (`BLAKE2b-256` of the six
bytes `696406000000`, not a block hash of any chain), `u = 1`, `first_b = 13` and `m = 7`. Each
cell is a word of `e_t` reduced modulo 13:

| `t` | word 0 | word 1     | word 2      | word 3      |
| --- | ------ | ---------- | ----------- | ----------- |
| 0   | 11     | 7          | 11, skipped | 0           |
| 1   | 5      | 5, skipped | 10          | 10, skipped |
| 2   | 3      | 12         |             |             |

The partners are 11, 7, 0, 5, 10, 3 and 12. With the same `I_b`, `u = 0` and
`first_b = 1,000,000`, they are 605,580, 489,461, 862,574, 23,234, 605,162, 652,525 and 310,112,
from `t = 0` and `t = 1` with no repeat. The reference implementation's unit tests contain both
(the second as the first seven positions of an `m = 8` case).

### Properties

- Older partners. Every partner exists when block `b` arrives, so a block is packed once, on
  arrival, and its packed chunks never change. A reorganization changes only the packed chunks
  of the new branch's blocks.
- Selected by `I_b`. The block hash commits the block's data, so the partners are unknown while
  the data is written, to the block's miner and to anyone buying space in it. A writer therefore
  cannot write `G` XORed with its chunk's partners to make the packed chunk a regenerable `G`.
  The miner of block `b` can compute the partners for each solved header and discard headers
  with unfavourable ones; that selects among headers but cannot change data already committed.
- Per chunk. `u` is hashed, so the chunks of one block have independent partners.
- Raw partners. A packed chunk is a function of `m + 1` raw chunks, so a node holding only the
  blocks forms it with `m + 1` reads, which can be issued together. With packed partners,
  forming one packed chunk from the blocks would require the partners' partners, recursively, to
  the genesis block.
- Distinct partners. Two equal partners cancel in the XOR.
- Reduction. A uniform 64-bit word reduced modulo `first_b` gives each position with a
  probability that differs from `1 / first_b` by less than `2^-64`.
- Mining reads. A miner reads one packed chunk per step from its packed copy, so packing does not
  change the reads per attempt; it adds `m` raw reads per chunk once, when the block arrives.

### Bound

Model the partner hash and the walk's digests as random functions, and let a party be able to
regenerate at most a fraction `s` of the chunks of every prefix `[0, n)` of the chain. The `m`
partners of a chunk of block `b` are distinct positions in `[0, first_b)`, of which at most
`s x first_b` are regenerable, so all `m` are regenerable with probability
`prod(i = 0..m-1) (s x first_b - i) / (first_b - i) <= s^m`. Reads 1 to `k - 1` are at positions
uniform over `[0, N)`, of which at most a fraction `s` are regenerable; read 0 is in the parent,
which a miner caches (Costs). The expected fraction of reads 1 to `k - 1` that the party computes
instead of performing is therefore at most `s^(m+1)`, and its attempts per second at a given read
rate are at most `1 / (1 - s^(m+1))` times an honest miner's: at `s = 1/2` and `m = 7`, at most
`1/256` of reads and `256/255` times. The bound assumes every partner read costs a storage read;
a party holding older chunks in a faster tier can exceed it (Open questions: Cached partners).

### Partner count

`m` does not change the reads per attempt of a miner with a packed copy. It sets the raw reads
per header of a node without one, `k x (m + 1)`; the raw reads to pack a 4,000,000-byte block of
977 chunks, `977 x m`; and the bound `s^(m+1)`:

| `m` | raw reads per header | packing reads per block | `s^(m+1)`, `s = 1/2` | `s = 1/4` |
| --- | -------------------- | ----------------------- | -------------------- | --------- |
| 0   | 8                    | 0                       | 1/2                  | 1/4       |
| 1   | 16                   | 977                     | 1/4                  | 1/16      |
| 2   | 24                   | 1,954                   | 1/8                  | 1/64      |
| 3   | 32                   | 2,931                   | 1/16                 | 1/256     |
| 4   | 40                   | 3,908                   | 1/32                 | 1/1,024   |
| 5   | 48                   | 4,885                   | 1/64                 | 1/4,096   |
| 6   | 56                   | 5,862                   | 1/128                | 1/16,384  |
| 7   | 64                   | 6,839                   | 1/256                | 1/65,536  |
| 8   | 72                   | 7,816                   | 1/512                | 1/262,144 |

`m = 7` bounds the computed fraction at `1/256` for a party that regenerates half of every
prefix, at 64 raw reads per header for a node without a packed copy.

### Alternatives not taken

- A validity rule excluding regenerable data: without the secret the data cannot be
  distinguished from random bytes.
- Larger chunks: a party filling whole blocks covers whole chunks at any size up to a block, and
  above a page a read costs in proportion to its bytes, so a chunk partly inside regenerable data
  costs the party only its other bytes.
- Partners in the next block: a miner with a fraction `h` of blocks mines both blocks of a
  fraction `h^2` of consecutive pairs, and can then regenerate both.
- Partners selected by a later block's hash: this removes the containing block's miner's choice
  among solved headers, but a block could be packed only once the next block exists, so read 0,
  in the parent, would read raw chunks.
- A fixed partner pool, or partners from a recent window: a party can hold the pool or window in
  a faster tier, so partner reads cost it that tier's read cost.
- Iterated or slow hashing. Hashing a chunk `N` times and hashing the digest in the walk would
  let a miner store digests instead of chunks (Rationale). XORing a chunk with a 4,096-byte
  keystream that costs `N` hash evaluations replaces the missing data with computation: `N`
  evaluations on the fastest hardware for that hash must cost more than one storage read, a
  value that depends on hardware prices; a node without an encoded copy computes `k x N`
  evaluations per header on general-purpose processors; and an `N` taken per chunk from other
  data lets the party compute only the chunks with small `N`. Encoding per mining address with
  an expensive function, as in Arweave 2.6, has the same costs. Partners require data the party
  does not hold, which no hardware computes.

### Option: group encoding

Group encoding, not specified, would replace packing so that a miner keeps one copy of the
chain. A regtest prototype, not kept, produced the group results in Results.

- Windows: window `j` is blocks `jW` to `(j+1)W - 1`. Its `C_j` chunks, with window indices
  `c = 0..C_j - 1`, are ordered by `u64le` of the first 8 bytes of
  `BLAKE2b-256(0x04 || K_j || LE32(c))`, ties by `c`, where `K_j` is the block hash of block
  `(j+1)W - 1` as 32 bytes in the order `hashPrevBlock` serializes it. Consecutive runs of `g`
  chunks in that order are groups, `g` even; if the last run has an odd size, its last chunk is
  a group of one. The reference implementation uses `W = 144` and `g = 8` by default.
- Encoding: `E(a)` is the XOR of the raw chunks of `a`'s group other than `a`; for a group of
  one, `E(a) = chunk(a)`.
- Walk: read 0 hashes `chunk(a_0)` in the parent; reads 1 to `k - 1` hash `E(a_i)` at
  `a_i = idx(x_i, G)`, where `G` is the chunk count of the complete windows among blocks
  `0..P`, which requires `A >= W`. Blocks after the last complete window are read only as the
  parent.

Properties:

- One copy. With `T` the XOR of a group's raw chunks, `E(a) = T XOR chunk(a)`, so for even `g`
  the XOR of the other members' encodings is `chunk(a)`: `T` appears `g - 1` times, an odd
  number. A miner keeps only the encoded chunks and recovers a raw chunk with `g - 1` reads; it
  encodes a complete window reading each raw chunk once. A node keeping raw blocks forms
  `E(a)` with `g - 1` reads, at most `1 + (k - 1) x (g - 1)` raw reads per header: 50 at
  `g = 8`, 106 at `g = 16`.
- Bound. With the ordering hash modeled as a random function, the other members of a chunk in a
  group of `g` are a uniform `(g - 1)`-subset of the window's other chunks. If a fraction `w` of
  a window's `C` chunks are regenerable by one party, all `g - 1` are regenerable with
  probability at most `(w x C / (C - 1))^(g - 1)`. `w` is the party's share of that window:
  unlike `s` under packing, it is not diluted by older data.
- Locality. A group's encodings depend only on its members. A party holding the raw chunks of a
  group's `u` non-regenerable members in a faster tier forms every encoding of that group from
  the tier and regenerable data, at most `u` fast reads each: `u` slots for up to `g` positions,
  where an honest miner holds one encoded chunk per position. Under packing a chunk's partners
  are spread over the older chain, so holding part of it forms few packed chunks, except through
  the oldest chunks (Open questions: Cached partners).
- `g = 2` gives no protection: `E(a)` is the other member's raw chunk.
- Each window has at most one group of fewer than `g` chunks and at most one group of one. A
  branch that replaces a window's last block changes that window's groups. The miner of that
  block can discard solved headers to choose among partitions, as with packing.

### Option: two-layer packing

Two-layer packing, not specified, would replace packing so that a miner keeps one copy, with
partners spread over the older chain as in packing. A regtest prototype, not kept, implemented it
(Results).

- Layers: chunk `u` of block `b` is in layer `L = BLAKE2b-256(0x06 || I_b || LE32(u))[0] mod 2`.
- Encoding: a layer-0 chunk's encoding is `chunk(a)` XORed with the raw chunks of `m0` distinct
  layer-1 chunks of older blocks; a layer-1 chunk's encoding is `chunk(a)` XORed with the
  encodings of `m1` distinct layer-0 chunks of older blocks. Partners are selected as in packing
  (prefix bytes `0x07` and `0x08`) over the older chunks of the other layer.
- Walk: as in the Specification, with the encoding in place of `packed`.

Properties:

- One copy. A layer-1 raw chunk is its encoding XORed with its partners' encodings, `m1 + 1`
  reads; a layer-0 raw chunk is its encoding XORed with its partners' raw chunks, at most
  `1 + m0 x (1 + m1)` reads. A miner keeps only the encodings.
- Nodes keep raw blocks: a layer-0 encoding takes `m0 + 1` raw reads, a layer-1 encoding at most
  `1 + m1 x (1 + m0)`, so a header takes at most `k x (1 + m1 x (1 + m0))`: 456 at
  `m0 = m1 = 7`, 1,928 at `m0 = m1 = 15`.
- Reuse. A layer-1 encoding is a function of its raw chunk and `m1` encodings that a miner holds
  for their own positions. A party holding the layer-0 encodings that its regenerable layer-1
  chunks use forms those chunks' encodings without holding them; `m1` sets the reads this
  costs. The results use `m0 = m1 = m`.

### Results

Results (informative; no requirement of this specification depends on them). 2026-10-05, regtest
prototypes of group encoding and two-layer packing, not kept; `k = 8`, `W = 144`. Each chain has
101 blocks without payload, 300 blocks with random payloads, then 200 (run A) or 700 blocks, each
mined by a stuffer with probability `h`. A stuffer payload is 880,000 bytes of BLAKE2b-512 output
in counter mode from a seed, checked byte for byte against the chain; other payloads are random
bytes:

- A: `h = 0.3`, other payloads 880,000 bytes; 0.1188 of the chunks regenerable.
- B: `h = 0.5`, other payloads 880,000 bytes; 0.3466 regenerable.
- C: `h = 0.5`, other payloads 220,000 bytes; 0.6750 regenerable.
- D: `h = 0.3`, other payloads 220,000 bytes; 0.5118 regenerable.

Each value is the stuffer's speedup over an honest miner at the same read rate. Single tier:
`n / (n - f)`, where `f` of the `n` positions (the complete windows for groups, every chunk
otherwise) have an encoded or packed chunk the stuffer forms from regenerable data. Fast tier: a
tier of `n / 4` chunks whose reads cost `c` against 1 for a storage read; the honest miner holds
encoded or packed chunks in it, and the speedup is the honest miner's total read cost over the
stuffer's. A position costs `c` per held chunk read to form it, or 1 if it cannot be formed from
held and regenerable data. The stuffer's holdings: for groups, the raw chunks of groups'
non-regenerable members, greedily by saving per slot; for packing and two-layer packing, raw
chunks oldest first or most used by its regenerable chunks first (best of five amounts), and for
two-layer packing also the layer-0 encodings used by the most regenerable layer-1 chunks; encoded
or packed chunks in the remaining slots. The two-layer prototype's node computed the same partners
and encodings as the analysis at sampled positions.

| Run | Encoding            | Single tier | `c = 0` | `c = 0.07` | `c = 0.15` |
| --- | ------------------- | ----------- | ------- | ---------- | ---------- |
| A   | groups, `g = 8`     | 1.0000      | 1.1381  | 1.0265     | 1.0050     |
| A   | groups, `g = 16`    | 1.0000      | 1.1277  | 1.0007     | 1.0000     |
| A   | packing, `m = 7`    | 1.0000      | 1.0003  | 1.0000     | 1.0000     |
| A   | packing, `m = 15`   | 1.0000      | 1.0000  | 1.0000     | 1.0000     |
| A   | two-layer, `m = 7`  | 1.0000      | 1.0680  | 1.0328     | 1.0000     |
| A   | two-layer, `m = 15` | 1.0000      | 1.0098  | 1.0000     | 1.0000     |
| B   | groups, `g = 8`     | 1.0046      | 1.6132  | 1.3067     | 1.1300     |
| B   | groups, `g = 16`    | 1.0000      | 1.5629  | 1.0773     | 1.0096     |
| B   | packing, `m = 7`    | 1.0000      | 1.0374  | 1.0000     | 1.0000     |
| B   | packing, `m = 15`   | 1.0000      | 1.0036  | 1.0000     | 1.0000     |
| B   | two-layer, `m = 7`  | 1.0000      | 1.1209  | 1.0569     | 1.0000     |
| B   | two-layer, `m = 15` | 1.0000      | 1.0622  | 1.0000     | 1.0000     |
| C   | groups, `g = 8`     | 1.1650      | 7.8406  | 3.6761     | 2.4510     |
| C   | groups, `g = 16`    | 1.0219      | 7.8406  | 2.3820     | 1.5360     |
| C   | packing, `m = 7`    | 1.0181      | 5.5623  | 1.9482     | 1.1974     |
| C   | packing, `m = 15`   | 1.0005      | 3.7646  | 1.1064     | 1.0006     |
| C   | two-layer, `m = 7`  | 1.0087      | 5.1443  | 1.1519     | 1.0346     |
| C   | two-layer, `m = 15` | 1.0003      | 3.2623  | 1.0066     | 1.0003     |
| D   | groups, `g = 8`     | 1.0238      | 2.4531  | 1.7923     | 1.4098     |
| D   | groups, `g = 16`    | 1.0006      | 2.3551  | 1.3279     | 1.0734     |
| D   | packing, `m = 7`    | 1.0016      | 1.4663  | 1.0634     | 1.0020     |
| D   | packing, `m = 15`   | 1.0000      | 1.2716  | 1.0000     | 1.0000     |
| D   | two-layer, `m = 7`  | 1.0007      | 1.3797  | 1.0931     | 1.0009     |
| D   | two-layer, `m = 15` | 1.0000      | 1.2417  | 1.0000     | 1.0000     |

With the fast tier, groups of 8 exceeded packing with 7 partners, and groups of 16 exceeded
packing with 15 partners, in every run and at every cost `c`, except groups of 16 against 15
partners in run A at `c = 0.15`, where both are 1.0000. At `c = 0.15`, two-layer packing was at
most 1.0346 with `m = 7` and 1.0003 with `m = 15`, and packing at most 1.1974 with 7 partners and
1.0006 with 15 (all in run C). At `c = 0`, every encoding gave run C a speedup of at least
3.2623: a party that regenerates 0.6750 of the chain can hold 0.25 / 0.3250 = 0.7692 of the
other chunks in a tier of a quarter of the chain and form its chunks from that tier.

## Backwards compatibility

Hard fork. The header format is unchanged. Its `mm_rhs` field, added as a merge-mining hook
for future use
([bitcoinknots/bitcoin@9a8127194d](https://github.com/bitcoinknots/bitcoin/commit/9a8127194dbc56925e6215e1e48e2733b4e8b32b)),
is hashed in the header hash's `Merge-mining hook` stage
([`block.cpp` line 57](https://github.com/bitcoinknots/bitcoin/blob/58398baf33e588779685ead478e6397bb28ed3d6/src/primitives/block.cpp#L57))
and is not used by this rule.

Mining. No `h0` is compared with a target, so every `h0` is an attempt that requires the reads.
BLAKE2b mining devices return only nonces whose `h0` meets a share target, so a device supplies
attempts at the rate it returns results, not at its hash rate, and a share check on `h0` no longer
measures work: a share is checked on `mr(final)`, which requires the chain. A miner keeps the
packed chunks, which it reads, and the raw blocks, which packing new blocks reads.

Validation. Checking work from `A` requires every earlier block. Pruned nodes, nodes started from
a snapshot until they hold the earlier blocks, and light clients cannot check it (Open questions:
Pruned nodes). In headers-first synchronization a header's work is checked once the blocks before
it are held.

## Costs

Mining. A miner cannot complete attempts faster than it reads the chain. With the parent cached,
an attempt costs `k - 1` random reads of 4,096-byte packed chunks from the rest of the chain, so
a copy with random read rate `R` completes at most `R / (k - 1)` attempts per second. Reads
within an attempt are serial, so parallel reads come from parallel attempts. An attempt
evaluates the BLAKE2b compression function 264 times over chunks (33 per step, a 4,128-byte
input) besides the header's stages. Packing a block reads `m` raw partners per chunk: 6,839 for a
4,000,000-byte block of 977 chunks. Building the packed copy reads `m` raw partners per chunk of
the chain.

Validation. A node without a packed copy reads at most `k x (m + 1) = 64` raw chunks per header,
in `k` serial rounds of at most `m + 1` reads; a chunk's partners depend only on its position and
its block's hash, so a round's reads can be issued together. With a packed copy, a header takes `k`
reads. A node keeps its raw blocks, since partners lie anywhere in the chain.

## Deployment

Activation at height `A`, not yet assigned: a multiple of 2016 above 961,640, so a retarget
period starts at `A` and every block from `A` has a version 2 header.

- Block `A` MUST have `nBits = 0x1c400000`: 17,179,869,183 expected attempts per block,
  600-second spacing at 2.86e7 attempts per second. It is not computed from earlier blocks.
- From `A`, every retarget measures its timespan from the timestamp of the last block before its
  period to that of the period's last block: `L` intervals for a period of `L` blocks.
- Transition window: retargets at heights `A + 144j` for `j = 1..14`, the last at `A + 2016` in
  place of the 2016-block retarget, each over the 144 blocks before it (from the timestamp of
  block `A + 144(j-1) - 1` to that of block `A + 144j - 1`), with a 144 x 600-second expected
  timespan and the factor-4 clamp. Of the blocks before `A`, only the timestamp of block `A - 1`
  enters a retarget calculation.
- The next retarget is at `A + 4032`, over blocks `A + 2016` to `A + 4031`, then every 2016
  blocks as before, with the timespan measured as above.

Without the reset, 600-second spacing at the difficulty of block 974,606 (`nBits = 0x1900edba`,
1.986e19 attempts per block) requires 3.31e16 attempts per second, and from `A` each attempt
requires `k - 1 = 7` chunk reads besides the parent: 2.32e17 random chunk reads per second
across the network. A network with `r` times fewer reads mines at `600 r`-second intervals until
the next 2016-block retarget, which lowers the difficulty by at most a factor of 4. The reset
target is 2^222, and the existing `powLimit`, `2^224 - 1`, is below 4 times it, so retargets
could lower the difficulty by less than a factor of 4 in total; `powLimit` is raised to
`2^240 - 1` (Difficulty), below 2^18 times the reset target.

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
further bounded by the link at 28,672 bytes per attempt. Fetching adds no read throughput. The
rule requires one copy per unit of read throughput, not one per hashing device: a copy with
random read rate `R` serves at most `R / (k - 1)` attempts per second (Costs). Partial holding:
a holder of a fraction `f` of the chain spends the storage reads per completed attempt given in
Rationale. A partial holder may instead fetch missing chunks from a remote holder, at an
expected `4,096 x (k - 1) x (1 - f)` bytes and up to `k - 1` serial round trips per attempt;
chaining does not prevent this; its cost is that bandwidth, compared with the cost of storing
the missing part locally. Forged reads: a node reads every chunk from its own copy. Regenerable
data: a party saves a storage read on a packed chunk only if the chunk and every partner are data
it regenerates (Packing); a party keeping raw chunks in a faster tier also computes a
regenerable chunk at that tier's cost when every partner is regenerable or in the tier (Open
questions).

## Open questions

- Chain work across activation: a block at `nBits = 0x1900edba` carries 1.16e9 times the work
  of a block at the reset `nBits`. Retargets before `A` accept compressed timestamps, so an
  alternative pre-activation segment can raise one 2016-block period's difficulty 4x, adding
  3 x 2016 x 1.986e19 = 1.20e23 attempts of work, the work of 6.99e12 blocks at the reset `nBits`.
  How chains that diverge before `A` are compared is not specified.
- Concentration: the security model changes from aggregate hash rate to aggregate read
  throughput over held chains; its concentration properties (drive versus memory cost per unit
  rate) are not analyzed.
- Attack cost: the machines that hold a copy and perform the reads are general-purpose servers,
  and the number for rent is not bounded by this chain's mining network; hardware built for one
  proof of work, mostly mining one chain, is for rent only in the share not mining it. An
  attacker that rents more read throughput than the network for `t` seconds pays rent for `t`
  seconds; at the price honest miners pay, that is the network's spending over `t` seconds, at
  most the block rewards over `t` seconds while mining is profitable. It need not buy the
  network's hardware ([Budish, 2018](https://www.nber.org/papers/w24717)). Honest miners have
  the same access: no manufacturer controls supply, and during an attack they can rent more, up
  to the value of the rewards, against an attacker paying up to the value of the reversed
  transactions. Each rented machine must first be loaded with a copy of the chain. The cost of
  reversing a transaction with a given number of confirmations under this rule is not analyzed.
- Cached partners: partners are older than their block, so the raw chunks of the oldest blocks
  are partners of every later chunk. A party keeping raw chunks in a faster tier, the oldest or
  those most used as partners of its regenerable chunks, computes a regenerable chunk at that
  tier's read cost whenever every partner is regenerable or in the tier, which raises its
  advantage above `s^m` while `m` fast-tier reads cost less than one storage read (Packing:
  Results). Drawing
  partners from the whole chain, re-packing at fixed intervals, would remove this dependence on
  age; it is not specified. Group encoding has no dependence on age but depends on each group's
  own members (Packing: Option: group encoding).
- Encoding: packing makes miners keep the raw blocks and a packed copy. Group encoding lets a miner
  keep one copy, but its groups are closed, so a party holding the non-regenerable raw members of
  groups that are mostly its data forms their encodings with fewer fast-tier slots than an honest
  miner; in runs B to D of the results its advantage exceeded packing's at every fast-tier cost.
  Two-layer packing lets a miner keep one copy with partners spread as in packing, at up to
  `k x (1 + m1 x (1 + m0))` raw reads per header for a node without encodings. Which is specified,
  and its partner or group counts, is not decided.
- Pruned nodes: a node that discards blocks cannot check work from `A`. It could keep a Merkle
  mountain range over the raw chunks, appending each block's chunks when the block is validated
  (an append needs only the new chunks and the current peaks), and each block's chunk count,
  which with its block hash gives every partner position. A node holding the chain would send the
  pruned node, for each block, the `k x (m + 1)` raw chunks the walk reads with their paths, at
  most 318,004 bytes while `N < 2^28`; the pruned node checks the paths against its peaks, forms
  the packed chunks and runs the walk, and a path that fails is the sender's fault, not the
  block's. The leaves must be raw chunks, since appending packed leaves requires partners from
  the whole chain. This changes no consensus rule but requires a peer that holds the chain. A
  tree root committed in each block would also let nodes that did not build the tree (nodes
  started from a snapshot, light clients, nodes checking headers before their blocks) check work
  from the same sections. Neither is specified.
- Unchecked headers: a header's work cannot be checked until the blocks before it are held. How
  a node bounds the headers it stores before checking them is not specified.

## Test vectors

The vectors use 14 byte strings in place of serialized blocks; the chunk space, packing and the
walk apply to them unchanged. String `b` (`b = 0..13`) has length `L_b`, from
`[285, 4095, 4096, 4097, 10000, 1, 9000, 20000, 30000, 4096, 12288, 50000, 7000, 40000]`, and is
the concatenation of `BLAKE2b-256(ASCII "blk" || LE32(b) || LE32(i))` for `i = 0, 1, ...`,
truncated to `L_b` bytes. `I_b = BLAKE2b-256(ASCII "id" || LE32(b))`. String 0 begins
`130879cbb006877576360ceb50c065697fd07f1ad87e3d5d18ac8d4239bb0755`, and
`I_0 = 18d727d27284acabf9311e5b0837c37f90e075c449c1dba60adf062da92745bf`. The space is that of a
block whose parent is string 13: `N = 54`, `S = 44`, and `first_b` is
`[0, 1, 2, 3, 5, 8, 9, 12, 17, 25, 26, 29, 42, 44]`.

Packing with `m = 7` (SHA-256 of the 4,096-byte packed chunk):

| `a` | `b` | `u` | partners | SHA-256 of `packed(a)` |
| --- | --- | --- | -------- | ---------------------- |
| 0  | 0  | 0 | none | `d7e9cb80c435795a67bdccd18f921b2102ff82cbb977ebd23a2b5d80a78d6f7a` |
| 3  | 3  | 0 | 0, 1, 2 | `e4496d67cf522df1f4f5fb370e223939c8633bb2d94f04a6c8a3388fd0d452af` |
| 5  | 4  | 0 | 0, 1, 2, 3, 4 | `3c122ed6153d05f1686455b617c65a7e2ce2d4c6f637d8960738feeca381bfb1` |
| 12 | 7  | 0 | 1, 9, 2, 10, 3, 0, 11 | `80f59a0fbfe4384ad64cd50b10639dfd16722b6a04a4774f19a99442bda83817` |
| 30 | 11 | 1 | 11, 14, 9, 4, 26, 2, 15 | `42371042fe223513e4c47c6f00850fefc562f58eee272d506807e6924f4af510` |
| 44 | 13 | 0 | 2, 18, 24, 33, 38, 30, 10 | `15b6ef2d39864b1555daad1ba984994bf30eb0726e7805534ef378ea0f4802c9` |
| 53 | 13 | 9 | 13, 36, 38, 4, 35, 6, 5 | `3c67e7c346380a38b3ed5667246ca1589d07303521a6d1c6ac9c926ef70082f4` |

Walks with `k = 8`, `m = 7` (`h0` and `final` as 32 bytes in digest order):

- `h0 = BLAKE2b-256(ASCII "hash2")` =
  `c42e1fde64fe247106e7b67d4f280dec37eec7f974e7372414a83df4a048a347`: positions
  `52, 23, 9, 11, 32, 28, 4, 36`;
  `final = 50dfaa122d6d10463baa607b9a836fc085b231d96e2da98ca412090ff05a3c2e`.
- `h0 = BLAKE2b-256(ASCII "test vector 2")` =
  `9c8bfb368f168c3bc3e7805f7619348030a2ed7f1df5df5ebfb78f5619e67583`: positions
  `48, 17, 11, 12, 12, 31, 30, 8`;
  `final = e0395a36a2dbfcb7c2978db06fc4b7f15acf194a66116ea2295a741698b0ec86`.

The reference implementation's unit test `bip_test_vectors` checks these values.

## Reference implementation

A regtest implementation in a fork of Bitcoin Knots
([`iohzrd/bitcoin`, branch `ddpow-pack`](https://github.com/iohzrd/bitcoin/tree/ddpow-pack);
`-testactivationheight=ddpow@<height>`, `-ddpowreads=<k>`, `-ddpowpartners=<m>`) implements the
chunk space, packing, the walk, the node's miner, and validation from the node's block files. It
differs from this specification in:

- Difficulty on regtest: a fixed target from `A` (`-ddpowblockbits`), not the Deployment
  schedule, which this branch does not implement.

It stores a header whose earlier blocks it does not hold without checking its work, and checks the
work when the block connects. With `-ddpowpackedstore` its miner keeps a packed copy of the chain
it follows (packing the blocks it lacks before it mines, and truncating to the common ancestor
after a reorganization) and walks it with one read per step. Its unit tests check partners, packed
chunks and walks against vectors from an independent Python implementation, against which its
functional tests also check every block.

## Prior art

Reads of chain data selected by a hash:

- [Hashimoto](http://diyhpl.us/~bryan/papers2/bitcoin/meh/hashimoto.pdf) (Dryja, undated,
  cited as 2014): the header hash selects 64 transaction identifiers across the whole chain;
  verifiers repeat the lookups against their own chain. This rule has the same order (header
  hash, then reads, then the target check) and reads packed chunks of block bytes at chained
  positions.
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
  second; this rule packs chunks with other chain data instead and has no verifiable delay
  function.

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
  checked against their positions; here a verifier computes each `a_i` and reads the chunk itself.
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

Outsourcing and archival requirements:

- [Nonoutsourceable scratch-off puzzles](https://www.cs.umd.edu/~jkatz/papers/nonoutsourceable.pdf)
  (Miller, Kosba, Katz, Shi, 2015): a puzzle is nonoutsourceable if a party able to mine for
  others can take the reward. This rule does not meet that criterion (Security).
- [Todd](https://www.mail-archive.com/bitcoin-dev@lists.linuxfoundation.org/msg03178.html)
  (2015): each block commits to a hash of the previous block's witness data with a per-miner
  prefix; once per block, outside the hashing loop.
