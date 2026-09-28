# Coinbase Output Attestation (retired)

Status: retired 2026-09-27. No further work. Work continues in
[data-dependent-pow.md](../data-dependent-pow.md).

## 1. Proposal

A soft fork under which every coinbase payee signs for its payout in every
block. Goal: make Stratum V1 blind hashing uneconomic (not impossible) for
the marginal hasher. With the long coinbase maturity (6480 blocks, about 45
days), a custodial pool must carry weeks of float and, under COA, hold its
hashers' signing keys to keep paying them in the coinbase, which makes it
their key custodian. A miner paid directly in the coinbase holds its own
key and signs with a small device.

The attestation key is the payout key on purpose: a separate attestation
key could be held by a pool for a hasher, which reopens custodial pooling.
Cost accepted: a public per-block signing history per payout address.

## 2. Rule

After activation, for every coinbase output with value > 0:

- the script is P2TR (`51 20 <32>`);
- the next output is `OP_RETURN PUSH64 <sig>` (`6a 40 <64 bytes>`), value 0;
- `sig` verifies under BIP340 with the output's 32-byte key over

```
msg = tagged_hash("COA/attest", height u32 LE || prev_block_hash, header byte order)
tagged_hash(t, x) = SHA256(SHA256(t) || SHA256(t) || x)
```

Zero-value outputs carry no constraint. Cost: one Schnorr verification per
payee, batchable.

Test vector: height 840000, previous block hash (display order)
`0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206`, gives
`msg = 9c8161007376c44fa16f14e2bd55f75389a2edb1441adbaaa00b2a554a45f4f4`.

## 3. Decisions and reasons

- **Placement: outputs.** The coinbase witness must be exactly one 32-byte
  item today; attestations there are a hard fork and need a new commitment.
  Outputs are covered by the txid and fit RDTS's 83-byte OP_RETURN cap.
- **Signature: raw BIP340 over a tagged hash**, not BIP-322 (whose verifier
  lives outside consensus). Payout script in the message is redundant
  (BIP340 binds the key); difficulty adds nothing (a pool can supply nBits).
- **Taproot only.** Key-path P2TR; script-path-only outputs cannot attest.
- **Weight.** 472 WU per payee (P2TR output plus attestation). Under RDTS
  (800 K WU blocks until 2027-09-01) a quarter of a block pays about 420
  payees; about 2100 after RDTS.
- **Unattested payees.** Redistributed to attesting payees (loses that
  block's slice), or carried to a later coinbase from later payees' share.
  Never settled from the pool wallet (custodial).
- **Deployment order.** Pool policy first: a pool can require attestations
  and write them into coinbases before any consensus change; the soft fork
  later makes it mandatory for every pool.

Rejected: coinbase-witness placement (hard fork), MuSig2 per block
(interactive rounds, stateful nonces), half-aggregation (draft BIP458;
kept as a later format), scriptSig (full).

## 4. Limit

A pool can run a public gateway whose hashers attest per tip with their own
devices while mining templates from the pool's node. Height and previous
hash are relayable, so no signed message distinguishes a template the
signer's node built from one the pool sent. COA ends pool custody of
coinbase payouts and makes hasher identities portable; it does not put a
node at the hashing site.

## 5. What was built

- **Device** (Rust workspace): `coa-wire` (framing, messages; `no_std`,
  no dependencies), `coa-core` (BIP32, BIP-322, BIP340 attestation, request
  handling; `no_std`, no allocation), `coa-host` (HID and stream
  transports, `coa` CLI), `coa-device-linux` (daemon on `/dev/hidg0` or a
  Unix socket). Protocol v1: four fixed-length commands over 64-byte HID
  reports: INFO, ADDRESS, ATTEST (BIP-322 form), ATTEST_RAW (consensus
  form). Keys never leave the device; it signs only messages it builds from
  height and previous hash. 72 µs per P2TR attestation (x86_64). cargo-fuzz
  targets for the framer, both decoders and the request path.
- **HSM HAT** (designed, not built): a microcontroller on a Raspberry Pi
  HAT running `coa-core`, holding the seed; the Pi forwards 64-byte frames
  and is trusted for availability only.
- **Knots** consensus patch, regtest-only buried deployment
  `-testactivationheight=coa@<h>`; `getblocktemplate` rule `!coa` with
  `coa_message_hash`; `test/functional/feature_coa.py`.
- **ratum** pool and gateway: attestation-aware coinbases (pair-atomic
  output selection), coinbaser messages v3 (0x12/0x13) and tip
  attestation (0xFA), pool attests its remainder, gateway self-pays until
  the pool attests, P2TR-only identities; e2e scenario `coa` mined attested
  pooled blocks through node, pool, gateway, device and miner.

## 6. Where the code is

| part | location |
| --- | --- |
| consensus patch | `~/src/bitcoin`, branch `coa-regtest`, commit `b314d16259` |
| pool and gateway | `~/src/ratum`, branch `coa`, commit `af950bb` |
| device crates, fuzz targets, protocol, threat model, HAT, gateway and pool notes | this repository, commit `5021475` (no longer on a branch) |

Commit `5021475` is reachable only through the reflog, which expires. To
keep it: `git tag coa-archive 5021475`. To read a file from it:
`git show 5021475:docs/PROTOCOL.md`.
