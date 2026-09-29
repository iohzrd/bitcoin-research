# Producer identity and block-share limits (keypow, retired)

Status: retired. This file is the record; the source (`DESIGN.md`,
`research/`, the `keypow` measurement tool) is in commit `5021475` under
`research/keypow/` (section 9).

## 1. Problem

One entity producing too many blocks. On this chain the top producer reached
50.2% of a 504-block window; a flag-day change needing 55% of blocks is
decided by a few parties. No consensus rule can restrict it because a block
contains no producer identity: the header-v2 fields consensus constrains
(`m_flags & 0xc0`, `m_height`, `m_txcount`) identify no producer.

Starting point: Luke Dashjr's proposal. Mine a key instead of a block, make a
block valid only if signed by such a key, revoke identities to cost an
operator the work of minting another. The signature requirement was kept.
The mint cost and revocation were removed (sections 4 and 5).

## 2. Constraints

1. Non-custodial pooling: no consensus rule may reference coinbase outputs.
2. A consensus rule in the node, not a pool or peer-to-peer mechanism.
3. Permissionless entry, at a cost a hobbyist can pay.
4. A producer is an individual running its own node; meaningful cost to that
   person is a design failure.
5. Creation time cannot be backdated.
6. Chainwork stays additive and objective (`GetBlockProof` from `nBits`).
7. `nBits` changes are limited to a factor of four.
8. New state is preserved across pruning, assumeutxo and reindex.

## 3. Design: a rate limit per lineage

A signed producer identity and four parameters:

| | |
| --- | --- |
| `W` | window, in blocks |
| `M` | maximum blocks one lineage signs within any `W` blocks |
| `L` | identity lifetime before renewal |
| `F` | maximum first-appearing (unlinked) identities per `W` |

A lineage is a key plus the chain of predecessor signatures back to its first
appearance. Renewal is a pre-expiry signature from a key to its successor.
`M` applies to the lineage, so renewal is free for continuity and useless for
evasion: the successor signature is the link that rotation to evade `M` omits.

### 3.1 The bound reduces to one ratio

A producer needs `N = sW/M` lineages for share `s` and gains at most `F` per
window, so its ramp is `F*M/W` share per window. With `F >= A` (honest entry
rate, constraint 3) and `M >= W/P` (`P` live lineages must fill `W` blocks):

```
ramp >= A * M / W >= A / P     share per window
```

`W`, `M` and `F` cancel. With `P = A*L/W` in steady state this is also
`ramp >= W/L`. Confirmed by simulation against a greedy adversary.

### 3.2 Measured values: no effect

Post-fork span 961641 to 970372 (8732 blocks): genuine first appearances `A` =
73.9 per 2016 blocks, live producers `P` = 105 to 228, `A/P` = 0.33 to 0.49
per window. Ramp lower bound about 33% per window; the observed takeover took
about three windows, so the rule would not have slowed it.

The rule binds only when `M = 1`, which needs `P >= W`: about 2016 live
lineages, nine times the measured population. Then `ramp = A/W` = 3.7% per
window and 50% takes about 6.5 months against the 6.4 weeks observed. Reaching
`P >= W` requires `L >= W^2/A`, about one year.

### 3.3 Conflicting requirements on `L`

`L` cannot be both long and short. The ramp bound needs `L` large; the
entrant-versus-rotator asymmetry (honest entry uses the quota once, an
unlinked producer again at every expiry) needs `L` small. The same
opposition as the cheap-pseudonyms result and `D = T/Δ` below.

### 3.4 Unanswered

- **Starvation.** `F` is one global quota: the adversary's ramp and honest
  entry consume the same quota.
- **Acquisition.** Buying established lineages. Sale is issuance, so no
  primitive prevents it; block production becomes a transferable asset and
  incumbents earn rent. The strongest objection.
- **Bootstrapping.** About a year at the measured entry rate before `M` can
  be reduced.
- Stockpiling is prevented by binding first appearance to first block signed.

### 3.5 Mechanics settled

- **Carriage.** In a structure committed by `m_mm_rhs` (outside the merkle
  tree, no blockspace, no coinbase output); `h2` commits `m_mm_rhs` while `h1`
  does not depend on it, so a signature over `h1` is committable without
  circularity. Alternative: a 32-byte header field. Open question.
- **Signature.** BIP340 with a scheme-id byte (the only thing that cannot be
  retrofitted). Domain-separated tagged hashes. If an authority key `K` is
  ever bound, sign `h1 || K`: over `h1` alone a rival pool replays the block
  signature under its own valid certificate and it is accepted (measured).
- **Succession.** Record `(old, new, height, sig_old)`, 136 bytes, verified
  once when mined; about 64 bytes of state per identity for its lifetime.
  Renewal and unlinkable rotation differ by one 64-byte signature.
  DNSSEC-style overlap window. Not forward-secure signatures (a fixed public
  key makes rotation unobservable).
- **State.** At most one entry per block, about 72 bytes, append-only, under
  4 MB per year; every query is answered from a sorted flat file.

## 4. Research results

### 4.1 Sybil cost

- One entity presents as many identities as its resources allow; with temporal
  resources, arbitrarily many (Douceur 2002). The only countermeasure is a
  non-temporal resource re-challenged at unpredictable times.
- Sybil cost is zero on every permissionless chain, and assigning one without
  a trusted party is an open problem (Kwon et al., AFT 2019).
- **Block-count bound.** Identity count is bounded by block count with no
  additional mechanism. It bounds count, not rotation.
- **Capacity ratio.** For parallelizable costs, entry and replacement cost
  scale with capacity: 959x measured on this hardware.
- **Demand rate.** An entrant needs one first appearance, a rotator one per
  block. The only exploitable asymmetry found.
- Bounded issuance needs state; the cap cannot be tighter than the
  concentration it measures (5 to admit the second producer, 24 the fifth).

### 4.2 What consensus cannot detect

- **Ownership is not a function of a transcript.** 500 parties and one entity
  on 500 machines produce the same distribution.
- No symmetric reputation function is Sybil-proof (Cheng, Friedman 2005), so
  linking must be done off-chain.
- Independence cannot be proven (covert coordination through template
  entropy). Two sub-questions are solvable: "did not copy this template"
  (non-malleable commit-reveal) and "different keys" (traceable ring
  signatures; key-distinct, not entity-distinct).
- Aggregate decentralization statistics are not Sybil-proof; splitting makes
  measured distributions more equal (Yaish et al. 2025).
- Adversary-chosen observables (labels, counts, dispersion, timestamps) have
  zero forensic value; physically constrained ones (mempool contents, latency,
  shared faults) have some.
- Overdispersion carries no information (`var/mean >= 1` for any latent
  rate); detection has a threshold below which it is impossible
  (Kesten-Stigum).

### 4.3 Pseudonym economics

- An entrant and a whitewasher are the same observation; the newcomer penalty
  is the uniquely efficient form (Friedman, Resnick 2001). Its cost depends on
  honest turnover, which measured high here (3.2), so it is not cheap.
- A rule costing two consenting parties is evadable by side payment
  (Roughgarden, off-chain-agreement proofness); only costs against the
  protocol itself remain effective.

### 4.4 Credentials, delegation, revocation

- The credential literature bounds uses per identity; this problem needs
  identities per entity. Per-identity counting provably requires a
  registration step (Anonymous Counting Tokens).
- Key transparency requires no additional mechanism on chain: every node
  stores the same key set.
- Delegation bounds depth, scope and time, never breadth.
- Non-transferability does not hold if the issuer is complicit: sale is
  issuance. Trusted hardware removes the counterparty risk of rental, not
  rental.
- Revocation is a mechanism available only to an issuer. Authority-free
  revocation costs Θ(L) per check; a contentious revocation of a key signing
  half the blocks splits the chain.

### 4.5 Non-outsourceability

The alternative to identity limits, and mutually exclusive with them: strong
non-outsourceability requires tickets indistinguishable from honest ones, and
an attributed ticket is distinguishable. It bounds template share by physical
possession of hardware. The BLAKE2b header design does the opposite: the
hasher receives only `h2`, and the anti-block-withholding XOR mask, whose key
only the pool holds, prevents even a DATUM gateway from determining which
shares are block solutions.

### 4.6 Sequential work

The one cost that applies to rotation without applying to entry (Little's
law). An identity maintains a lane of sequential work seeded with
`H(pk, recent block hash)`; a rotator maintains `D = T/Δ` lanes permanently,
an entrant one lane once. Commodity-to-optimized lane ratios: disk 1.35x,
Argon2id 1.33x, class-group squaring 3 to 4x, RSA 150 to 220x (ASIC). Must
stay observational (never in chainwork or validity), and the newcomer cost is
latency `T`. Assume the delay is rentable.

### 4.7 Signatures and state

| operation | per call |
| --- | --- |
| BIP340 verify | 19.30 µs |
| Ed25519 verify (dryoc) | 28.51 µs |
| BLS12-381 verify | 683.6 µs |

BIP340 chosen over Ed25519 mainly for consensus determinism: four Ed25519
verifier implementations return identical results on 4 of 12
`ed25519-speccheck` vectors. State: flat file; if it must be committed, a
compressed sparse Merkle tree, not Utreexo (no non-membership proofs).
Append-only, never expire.

### 4.8 Off-chain linking

Detects links that consensus rules cannot: template similarity (related pools
81 to 99%, unrelated 1%), correlated faults (identical invalid jobs from
shared bugs), exclusion-policy clustering (cannot be evaded without ending the
censorship). Pairwise attribution among 500 identities needs about 16.9 bits
beyond chance. Under full rotation identity-keyed statistics have zero power.

## 5. The template constructor and the payout aggregator

An earlier design split the producer `G` (who chose the transactions; the only
party that can censor) from the payout aggregator `K` (the "pool has 50%"
figure), with an optional certificate binding them (Stratum V2 layout, block
heights instead of timestamps, depth one, expiry only). A mandatory capped `K`
is defeated by certificate rental: a producer at 45% buys certificates from
eight pools and the record names eight operators for hashrate they do not
control. What remains is `K` as an optional, signed, uncapped affiliation:
"the share of blocks a pool vouches for". A bonded optional `K` (certificate
indices bounded by a bond, equivocation slashable) is the one configuration
where a ceiling binds without excluding anyone; it imposes a cost on capacity,
not on renting, and adds state. Open question.

Attribution alone does not limit concentration (Ethereum builders: three at
80% within eighteen months despite full attribution). It is a prerequisite for
measurement and governance, not an incentive.

## 6. Measurements on this chain

- **No reliable producer identity exists.** Coinbase tags are unverified;
  35 tags map to 14 pools (2.5x fragmentation), so `A` and `P` above are
  overstated by up to that factor; their ratio may still be accurate.
- **Custodial preference.** One operator with both a custodial Stratum V1
  endpoint and a DATUM endpoint: 174 against 7 blocks in 504, about 25 to 1.
- **The takeover.** `AlphaPool`, one payout script, zero multi-payee
  coinbases: 0.4% to 50.2% of a 504-block window in about 5000 blocks, 11.7%
  to 40.1% within one window. Its coinbases were paid out in batches of up to
  175 outputs, keeping 3.1% of 3571.9 coins mined: a custodial pool, not a
  solo miner. Over the full post-fork span it was second (13.1%) behind a
  non-custodial pool (15.4%).
- **Grinding.** Key grinding is 101x more expensive per attempt than nonce
  grinding (not the assumed 1000x).
- **Identity witness** on real headers: 106 bytes solo, 202 affiliated;
  18.54 µs and 39.05 µs to verify.

## 7. Rejected

| construction | reason |
| --- | --- |
| key proof of work | block count already bounds identity count; it imposes the cost twice |
| a second proof of work in chainwork | security scales with world hashrate in that algorithm |
| detectors (dispersion, mempool independence) | adversary-chosen statistics; subsidizes censorship |
| age multipliers on difficulty or subsidy | bias chainwork toward the attacker; penalize entry like rotation |
| per-identity rate penalty | defeated by splitting (reconsidered per lineage; still too weak at measured `A/P`) |
| binding identity to the coinbase | constraint 1 |
| revocation | needs an authority, or Θ(L) per check |
| ring signatures for membership | linear verification; initial block download cost grows as h² |
| stateful hash-based signatures | leaf use is per signing attempt; state cannot be backed up |
| BLS | 35x BIP340 verification cost |
| trusted execution environment attestation | forgeable with cheap hardware; permanent-verifiability problem |
| Bloom and cuckoo filters | a false positive grants seniority |
| recursive succinct non-interactive argument of knowledge (SNARK) state | prover latency on the propagation path |

## 8. Where it ended

The record's first open item: the design's bound depends only on `A/P`, and it
measured 0.33 to 0.49 on this chain. Either a rule is found whose ramp bound
does not reduce to `A/P`, or this family of rules needs a producer population
about nine times the current one before it has any effect. Also open: whether
exceeding `M` is a rejection or a difficulty change, chain reorganization
behaviour around first appearances and renewals, and acquisition.

## 9. The tool and the source

`keypow` was a Rust command-line tool: `bench`, `mint`, `verify`, `identity`
(recomputes `h1` from live v2 headers and signs and verifies a witness),
`schemes` (signature benchmarks), `tip`, `scan` (producer statistics from
coinbases), `simulate` (splitting and liveness), `calibrate`.

The source is in this repository's commit `5021475` under `research/keypow/`,
on no branch and reachable only through the reflog, which expires. To keep
it: `git tag coa-archive 5021475` (the same commit holds the COA material).
To read a file: `git show 5021475:research/keypow/DESIGN.md`.
