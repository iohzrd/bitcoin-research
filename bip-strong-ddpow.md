    BIP: XXXX
    Title: Strong data-dependent proof of work
    Author: iohzrd
    Status: Draft
    Type: Standards Track
    Layer: Consensus (hard fork)
    Created: 2026-09-28

## Abstract

This consensus rule makes every mining hash read bytes of the block chain and fold them into
the value checked against the difficulty target. Each hash selects the byte positions it
reads from its own output, spanning the whole chain from the genesis block. Because every
hash reads, and the positions cannot be known before the hash is computed, a miner must hold
the whole chain in local storage to mine at any speed, and cannot hand the reads to a remote
party. Nodes hold the chain and verify a block by recomputing its reads, as Bitcoin nodes
validate today.

## Motivation

Today a miner needs no block chain data and runs no node. A pool assembles the candidate
block, reduces it to an 80-byte header, and sends that header to hashing hardware. The
hardware tries nonces and returns any whose hash meets the target. It stores no block chain
and validates nothing. This lets hashing concentrate at parties that hold no chain, and lets
miners extend blocks they have not checked, which has produced chains built on invalid blocks
in the past.

To make holding the chain a condition of mining, the hash must depend on chain data that a
miner cannot obtain cheaply from elsewhere. Reading the chain on only a small share of hashes
does not achieve this: a miner without the chain sends those few hashes to a party that holds
the chain, receives the result, and still keeps no local copy; the messages are few and
small. This rule therefore makes every hash read the chain. A miner without a local copy
would then have to send one message per hash to a remote holder. At mining speeds this is
billions of messages per second (hardware at one trillion hashes per second would send about
32 terabytes per second), beyond any network, so it is not possible. Every hashing unit must
hold the whole chain locally, which is the goal.

## Specification

Chunks. Every block from genesis, in height order, serialized, split into 64-byte pieces,
the last zero-padded.

Tree. `T` is a Merkle mountain range over the chunks of blocks `0..P` (parent `P`):
leaf `= BLAKE2b-256(0x00 || chunk)`, node `= BLAKE2b-256(0x01 || left || right)`.
`N` = chunk count of `0..P`; `S` = chunk count of `0..P-1`.

Commitment. The header field `mm_rhs` MUST equal
`BLAKE2b-256(0x02 || N as u64le || S as u64le || bag(peaks(T)))`, where `bag` folds the
peaks highest first from the right with the node hash. `mm_rhs` is inside the header, so the
reads are fixed before hashing.

Per attempt (header `H` with nonce `n`, `k = 8`):

    h0    = BLAKE2b-256(H)
    a_0   = S + ( word_0(h0) mod (N - S) )              parent block
    a_i   = word_i(h0) mod N            i = 1..k-1       whole chain
    final = BLAKE2b-256( h0 || chunk(a_0) || ... || chunk(a_{k-1}) )

`word_i(h0)` is `u64le(h0[8*(i mod 4) ..]) + i * 0x9E3779B97F4A7C15`. The block is valid if
`final`, masked and byte-reversed as a block hash, is `<= target(nBits)`. Every value of the
nonce performs the reads; no cheaper test exempts an attempt from reading.

Verification. A node that holds the chain checks a block by recomputing `h0` from the header,
each `a_i` from `h0`, reading `chunk(a_i)` from its own copy, recomputing `final`, and
comparing with the target. This is the normal path.

Header proof (initial synchronization only). During headers-first synchronization a node
receives headers before the blocks they read, so it cannot yet read the chunks. A header MAY
carry a proof: `N`, `S`, `peaks(T)`, and per read the chunk with its Merkle path to its peak.
The node recomputes each `a_i` from `h0`, folds each chunk at `a_i` to its committed peak,
recomputes `final`, and compares with the target, checking the header's work before it has
downloaded the chain. Once the chain is downloaded, verification is by recomputation and the
proof is not used.

Difficulty. `nBits` retargets as before; `final` is the proof-of-work value.

## Rationale

Reading on every hash, rather than on a selected few, is what makes every hash depend on the
chain and makes outsourcing infeasible (Motivation). Read 0 in the parent forces holding the
parent block before mining on it. Reads 1 to k-1 over the whole chain force holding all of
it; `k` sets resistance to holding only part of the chain (a holder of fraction `f` completes
`f^(k-1)` of attempts). The commitment fixes which chunks are read before `h0` exists, so a
miner cannot search for chunks that produce a low `final`. The header proof serves only initial synchronization, letting a node check a header's work
before it has downloaded the chain; a synchronized node verifies by recomputation.

## Backwards compatibility

Hard fork. Hash-optimized ASICs lose their advantage: a miner cannot hash faster than it can
read the chain, so effective rate is bounded by random-read throughput over the held copy
(order 1e5 to 1e6 per second per drive, higher from DRAM), not by hash rate. Mining becomes
a storage-I/O contest that requires possession of the chain. Existing block and header
formats are unchanged except for the already-present `mm_rhs` commitment.

## Security

Outsourcing: infeasible, since every hash needs a local read and per-hash intermediates
cannot be shipped at hash rate. Grinding: prevented by the commitment. Forged
reads: a validating node recomputes `final` from its own chain, so a block whose reads do not
match is rejected; a header proof presented during synchronization is checked against the
committed peaks. The proof-of-work security model shifts from
aggregate hash rate to aggregate read throughput over held chains; its concentration
properties (disk versus DRAM cost per unit rate) require analysis before deployment.

## Reference

Software prototype and measurements: `ddpow-strong/` (read-per-hash miner, memory and disk
regimes, Merkle mountain range proof roundtrip). A related design that reads the chain on
only a selected share of hashes, and the shared structures (chunking, the Merkle mountain
range, the commitment, the proofs), is described in `data-dependent-pow.md`.
