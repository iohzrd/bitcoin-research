# Data-dependent proof of work: prior art survey

2026-09-28

## Summary

Our rule is Hashimoto's structure (header hash first, then reads of real chain data chosen by that hash, then a final check against the target), with three additions: a pre-filter so deployed ASICs run unchanged, a Merkle mountain range commitment in the header so nodes without the chain can check work, and one read forced into the parent block. The pre-filter and the commitment each have close precedents; the parent read, and raw block bytes as the committed data, have none that the searches found. The closest overall precedent is Arweave, whose per-attempt chain reads were outsourced in production.

**The design surveyed against.** Every block's serialized bytes since genesis are split into 64-byte chunks, the leaves of a Merkle mountain range. A block's header commits to the Merkle mountain range after its parent: chunk count N, the parent's first chunk S, and the bagged peaks. The chip's ordinary stage-3 header hash c is a candidate if it has p leading zero bits (default 28). Each candidate reads 8 chunks at positions derived from c: read 0 in the parent's chunks [S, N), reads 1 to 7 anywhere in [0, N). The block is valid if BLAKE2b-256(c ‖ 8 chunks) meets the target. A proof (N, S, peaks, each chunk with its Merkle mountain range path) lets a node verify a header's full work without the chain.

**Purpose.** Make holding an archival copy of the chain a condition of mining, for mining facilities and hashrate renters that run no node today. Known weakness, shared with Hashimoto and Popescu's proposal: nothing forces the reads to happen at the hashing site; a site without the chain can send each candidate (about 16 bytes) to a remote holder.

## Proof of work over chain data

Hashimoto is our rule's direct predecessor: header hash first, then reads selected by it across the whole chain, then a comparison with the target. Arweave is the only deployed family found that reads historical chain data per attempt with Merkle proofs, and its history records the same outsourcing failure our rule is exposed to. EWoK's authors considered reading the chain after the proof of work is solved and rejected it because it "only ensures that the pool operator … stores the full blockchain".

| Work | Year | Data read | Selection and order | Reads per attempt | How others verify | Relation to our design |
| --- | --- | --- | --- | --- | --- | --- |
| [Hashimoto](http://diyhpl.us/~bryan/papers2/bitcoin/meh/hashimoto.pdf) (Dryja) | Undated PDF, usually cited as 2014 | 32-byte txids, all transactions in the chain numbered in order | sha256(prev_hash, merkle_root, nonce), then position i = (hash >> i) mod total transactions | 64 per hash, no filter | Repeat the lookups against their own chain; no proofs | Same order and purpose, and the same bandwidth argument ("several terabytes per second" to outsource). Differs: txids not raw bytes, reads on every hash, XOR mix not a hash, no parent read, no proofs |
| [Proof of work with unspent transaction output queries](https://en.bitcoin.it/wiki/User:Gmaxwell/alt_ideas) (credited to Andrew Miller, on Maxwell's alt ideas page) | 2013 to 2017 revisions | Unspent transaction output set | Queries in a memory-hard proof of work | Not specified | Not specified | Conceptual precursor; reads state, not history |
| [Popescu's proposal](http://trilema.com/2016/the-necessary-prerequisite-for-any-change-to-the-bitcoin-protocol/) | 2016 | The nonce-th byte of every preceding block | Data first: SHA3-512 digest of the bytes goes into sha(sha(headers + nonce + digest)) | One byte from every block; an 8-bit nonce shift suggested | Recompute from the full chain | Selection by nonce alone lets one digest table serve every miner, and miners can vary the coinbase instead of the nonce (both raised in the comments). He intended node operators to sell digests |
| Casatta's variant (comment 8 on Popescu's post) | 2016 | A byte from a fixed number of blocks | Blocks derived from the nonce; Popescu proposed parent_hash mod height, shifted and repeated | For example 64 | Full chain | Closest predecessor of our reads 1 to 7, in the opposite order |
| [EWoK, BitcoinPlus](https://eprint.iacr.org/2017/1067) (Armknecht, Bohli, Karame, Li) | 2017, SACMAT 2021; [NEC patent US10397328B2](https://patents.google.com/patent/US10397328B2/en) | Each worker's pseudorandom partition, one block per group | Data first: a coinbase nonce hashes a partition block chosen by a bounded pre-nonce | One block per coinbase variant | Full nodes holding the chain | A design they consider reads ℓ blocks after the proof of work is solved (our order); they reject it because it binds only the pool operator. The patent may apply to any deployment |
| [Arweave Proof of Access](https://www.arweave.org/yellow-paper.pdf) (Williams et al.) | Yellow paper draft, references to 2019 | One whole historical block | Recall block = block list[prev indep_hash mod height], included in the proof of work input | One per block interval | Verifiers already hold the recall block | Outsourced in production: a "storage and computation pool" served preimages "to millions of clients per second via a Gbit Internet link" ([ANS-103](https://github.com/ArweaveTeam/arweave-standards/blob/master/ans/ANS-103.md)) |
| [SPoRA, ANS-103](https://github.com/ArweaveTeam/arweave-standards/blob/master/ans/ANS-103.md) (Williams, Berman) | 2020 spec, deployed 2021 | 256 KiB chunk of the weave | H0 = RandomX(nonce, block); recall byte from H0 and the previous hash within 10% of the weave; SolutionHash = RandomX(H0, prev, time, chunk) | 1 | Chunk plus Merkle paths to committed roots | Same per-attempt read plus Merkle proof; a slow RandomX hash limits attempts where we use a pre-filter on a fast hash |
| [Arweave 2.6 and later](https://2-6-spec.arweave.net/) | Spec undated, after SPoRA | Chunks stored encrypted per mining address ("packing") | A SHA-256 verifiable delay function advances one step per second; one recall range in the miner's 3.6 TB partition, one anywhere in the weave | 2 ranges (100 MiB in 2.6, 2.5 MiB now) | Merkle paths plus verifiable delay function checkpoints | One local plus one global read approximately corresponds to our read 0 plus reads 1 to 7. Packing binds data to an address and the verifiable delay function limits reads per second; our rule has neither |
| [Autonomys (Subspace) proof of archival storage](https://academy.autonomys.xyz/autonomys-network/consensus) | Deployed | Erasure-coded pieces of chain history, KZG-committed, masked with each farmer's proof-of-space table | A proof-of-time beacon picks one bucket per sector | Scan of one bucket | Chunk, proof-of-space values, KZG witness | Proof of space over real chain history, not proof of work; per-identity encoding |

Ethereum's Dagger-Hashimoto spec also records an abandoned "blockchain-based proof of work" that ran contracts taken from the chain; it was dropped because attackers could fork and populate the chain with contracts they had a fast trapdoor for. It shows why the safe form reads data and does not execute it.

## Generated-dataset and memory-hard proof of work

These schemes read a dataset derived from a seed, not the chain, so none of them forces possession of the chain. Two of them use our proof mechanism: Merkle Tree Proof and SmartPool open each read with a Merkle path to a committed root, so the verifier holds no data. Dagger-Hashimoto listed "full chain storage" as an optional goal; Ethash removed it.

| Work | Year | Dataset | Reads per attempt | How a verifier checks without the dataset | Relation to our design |
| --- | --- | --- | --- | --- | --- |
| [scrypt](https://www.tarsnap.com/scrypt/scrypt.pdf) (Percival) | 2009 | V[0..N−1] by iterated hashing, per hash | N, indices from the running state | It cannot; the verifier recomputes everything | Verifier cost limits memory size, the problem the later schemes address |
| [Coelho, Merkle-tree proof of work](https://eprint.iacr.org/2007/433) | 2007, AfricaCrypt 2008 | Merkle tree over N generated leaves | P leaves chosen from the root | Recomputes the opened leaves and their paths | Earliest found instance of openings chosen from a committed root; not a repeated nonce search |
| [Dagger](http://www.hashcash.org/papers/dagger.html) (Buterin) | 2013 | 10-level directed acyclic graph, about 2^25 nodes of 32 bytes | Bottom nodes chosen by the nonce | Recomputes the needed nodes, about 6,000 hashes | Generated dataset; [Lerner's critique](http://bitslog.com/2014/01/17/ethereum-dagger-pow-is-flawed/) argues a 100× ASIC speedup |
| [CryptoNight](https://cryptonote.org/cns/cns008.txt) | 2013 | 2 MiB scratchpad per hash | 524,288 data-dependent read-writes | Full recomputation | No proofs; per-hash scratchpad |
| [Dagger-Hashimoto](https://ethereum.org/developers/docs/consensus-mechanisms/pow/mining/mining-algorithms/dagger-hashimoto/) | 2014 | Generated dataset, 4 GB initial | 200 | Light clients compute dataset entries from a seed; a stored pre-SHA3 mix value lets a cheap outer check run first | Hashimoto's loop over a generated dataset; listed full chain storage as an optional goal |
| [Cuckoo Cycle](https://eprint.iacr.org/2014/059) (Tromp) | 2014 | Graph whose edges are siphash of the header | Memory-hard cycle search | Rehashes L edges (for example 42) | Memory-hard solving, no data to prove |
| [Ethash](https://ethereum.org/developers/docs/consensus-mechanisms/pow/mining/mining-algorithms/ethash/) | 2015 | 1 GB dataset initial (+8 MiB per 30,000-block epoch), 16 MB cache | 64 accesses of 128 bytes | `hashimoto_light` computes the 128 needed items from the cache | Header-seeded data-dependent reads; generated dataset, no pre-filter |
| [Equihash](https://eprint.iacr.org/2015/946) (Biryukov, Khovratovich) | 2016 | Generalized birthday problem | Memory-hard sort | 2^k hashes and XORs | Memory-hard solving, no data to prove |
| [MTP, Egalitarian Computing](https://arxiv.org/abs/1606.03588) (Biryukov, Khovratovich) | 2016; in Zcoin Dec 2018 to Oct 2021 | 2 GiB of Argon2d, rebuilt per challenge, Merkle root Φ | L = 70 sequential reads, each seeded by the previous | 3L openings with Merkle paths; proof about 200 kB | Our proof pattern (hash-chosen reads, each opened against a committed root); dataset is regenerated, not the chain |
| [SmartPool](https://eprint.iacr.org/2017/019) (Luu et al.) | 2017 | Ethash dataset | 64 | Miner submits the accessed items with Merkle branches to roots stored in a contract | Merkle-proven reads of an existing data-dependent proof of work; roots are precomputed, not in headers |
| [ProgPoW, EIP-1057](https://eips.ethereum.org/EIPS/eip-1057) | 2018, stagnant | Ethash dataset | 64 reads of 256 bytes plus random math | As Ethash | Generated dataset; see the seed exploit below |
| [RandomX](https://github.com/tevador/RandomX) | 2019, Monero | 2 GiB dataset from a 256 MiB Argon2d cache | 8 programs × 2,048 iterations, one 64-byte load each | Light mode from the 256 MiB cache | Generated dataset; also the hash inside Arweave's SPoRA |

**Lessons that apply to our rule:**

- **Bind every opening to its position.** [Bevand's attacks on MTP](https://blog.zorinaq.com/attacks-on-mtp/) (2017) include "location in merkle tree not verified" and a Zcoin flaw that left a third of the openings unchecked. Our `VerifyProof` derives each position from c and folds its path by that position; the peak index and path length are checked against it.
- **Positions need the full entropy of c.** The [ProgPoW exploit](https://github.com/kik/progpow-exploit) fixed a 64-bit seed, computed the memory stage once, and brute-forced the remaining computation without memory access. Our positions and final hash take all 256 bits of c, and c covers the whole header.
- **Time-memory tradeoffs.** [Dinur and Nadler](https://eprint.iacr.org/2017/497) (CRYPTO 2017) ran Merkle Tree Proof in under 1 MB for a 170× compute penalty. That attack targets regenerable data; chain bytes cannot be regenerated from less, which is our rule's reason for using them.

## Proofs of storage, retrievability and space

Permacoin is the template for our read-and-prove step: hash-derived positions, a small number of reads, 64-byte segments considered, and Merkle-proven reads a verifier checks against a committed root. Every storage scheme below that resists outsourcing binds the stored data to the prover's identity (signature chaining, per-miner replicas, packing, an identity-keyed transform); our rule stores the chain as is and has no such binding.

| Work | Year | What is stored | Challenge and proof | Anti-outsourcing | Relation to our design |
| --- | --- | --- | --- | --- | --- |
| [PORs](https://www.arijuels.com/wp-content/uploads/2013/09/JK07.pdf) (Juels, Kaliski) | CCS 2007 | A client's file, encoded, encrypted, with hidden sentinel blocks | Verifier asks for sentinels at chosen positions; private verification | None | The retrievability concept only |
| [Provable data possession](https://eprint.iacr.org/2007/202.pdf) (Ateniese et al.) | CCS 2007 | A client's file with RSA homomorphic tags | c sampled blocks, constant-size aggregate proof; 460 samples detect 1% loss with 99% probability | None | Source of the sampling argument: a few random reads detect missing data |
| [Compact PORs](https://eprint.iacr.org/2008/073.pdf) (Shacham, Waters) | ASIACRYPT 2008 | A file with BLS authenticators | Aggregated σ and μ over a challenge set; public or private verification | None | Used by Retricoin and KopperCoin; we use plain Merkle paths |
| [Maxwell, proof of storage](https://bitcointalk.org/index.php?topic=310323.0) | 2013 | A seed-expanded table, sorted | Server asks for the index of a value at a random position | None | Peer-to-peer denial-of-service resistance over pseudorandom data, not the chain |
| [Permacoin](https://www.ieee-security.org/TC/SP2014/papers/Permacoin_c_RepurposingBitcoinWorkforDataPreservation.pdf) (Miller, Juels, Shi, Parno, Katz) | IEEE S&P 2014 | A dealer's erasure-coded archive; each key stores segments H0(pk‖i) mod n | k sequential signature-chained reads (k = 20 evaluated); ticket carries segments and Merkle proofs | Signature chaining lets any helper steal the reward; sequential reads cost a round trip each | Our read-and-prove template. Differs: external archive with a trusted dealer, per-key subsets, chained reads |
| [Sia](https://sia.tech/sia.pdf) (Vorick, Champine) | 2014 | Contract files, Merkle root in the contract, 64-byte leaves | One segment chosen by H(contract id ‖ H(previous block)), with its Merkle path | None beyond the contract | Same primitive: a 64-byte leaf and a Merkle path at a block-hash-derived position; not a mining puzzle |
| [Burstcoin / Signum proof of capacity](https://raw.githubusercontent.com/signum-network/signum-node/main/src/brs/util/MiningPlot.java) | Launch year not verified | Self-generated plots of 4,096 scoops of 64 bytes per nonce | One scoop per stored nonce per block, chosen by the generation signature | None needed: the data is the miner's own | Same 64-byte read unit and hash-chosen position; data is generated, not the chain |
| [Lerner, proof of unique blockchain storage](https://bitslog.com/2014/11/03/proof-of-local-blockchain-storage/) ([revised 2015](https://bitslog.com/2015/09/16/proof-of-unique-blockchain-storage-revised/)) | 2014 | The chain under an asymmetric-time transform keyed to the node's Internet Protocol address | Timed hash of about 1,000 blocks at chained, seed-derived indices | Identity-keyed encoding plus a time bound | Targets the chain itself and the "many nodes, one copy" problem our rule leaves open; a peer challenge, not proof of work |
| [Proofs of space](https://eprint.iacr.org/2013/796.pdf) (Dziembowski, Faust, Kolmogorov, Pietrzak) | CRYPTO 2015 | Labels of a hard-to-pebble graph, Merkle-committed | Random openings | The data is the prover's own | Stored data is useless by design, the opposite of our goal |
| [SpaceMint](https://eprint.iacr.org/2015/528.pdf) (Park et al.) | 2015 | Graph labels | Chain-derived challenge selects openings; a quality function picks the winner | As proofs of space | Nothing-at-stake and grinding analysis for storage-based chains |
| [Retricoin](https://www.isical.ac.in/~binanda_r/publications/ICDCN2016.pdf) (Sengupta, Bag, Ruj, Sakurai) | ICDCN 2016 | A dealer's file with Shacham-Waters tags, per-key segments | 128 challenges from the puzzle, key and seeds; pairing check | Permacoin-style signature chaining | Does not store the blockchain |
| [KopperCoin](https://gwern.net/doc/bitcoin/nashx/2016-kopp.pdf) (Kopp, Bösch, Kargl) | ISPEC 2016 | Users' uploaded chunks | Chunk nearest the block hash by XOR; Shacham-Waters proof | None found | Stores user files, not the chain |
| [Chia](https://www.chia.net/wp-content/uploads/2022/07/ChiaGreenPaper.pdf) (Cohen, Pietrzak) | 2019 | Proof-of-space plots, about 10 TB at ℓ = 40 | Proofs of space alternating with a verifiable delay function | Plots keyed to an identity | No chain storage |
| [Filecoin PoRep and PoSt](https://spec.filecoin.io/algorithms/pos/post/) | Current spec | Client data sealed into a replica unique to the prover and sector | WindowPoSt: 10 challenges per sector; compressed with a succinct non-interactive argument of knowledge | Unique replicas prevent deduplication | The per-prover encoding our rule lacks; stores client data |
| [Proof of custody](https://dankradfeist.de/ethereum/2021/09/30/proofs-of-custody.html) (Feist) | 2021 | Shard or blob data | Custody bit over the data and a later-revealed secret; slashing | Secret-dependent | Applies to recent data, not history |
| [EIP-4444](https://eips.ethereum.org/EIPS/eip-4444) | 2021, draft | Nothing: clients stop serving history older than 33,024 epochs | None | None | The opposite trend: no specific party keeps history |

## Pool and outsourcing resistance

Every scheme found that resists outsourcing uses one of two mechanisms: the work depends on a secret whose disclosure lets the helper take the reward, or each attempt makes many dependent reads so remote storage costs a round trip per read. Our rule has neither. Arweave's move from Proof of Access to SPoRA documents our known weakness in production: a remote storage pool served single-chunk proof-of-work preimages to many miners.

| Work | Year | Mechanism | What it binds, and can it be outsourced | Relation to our design |
| --- | --- | --- | --- | --- |
| [P2Pool](https://bitcointalk.org/index.php?topic=18313.0) (forrestv) | 2011 | Share chain of about 30 s shares; each node builds its own block, the coinbase pays prior share owners | Templates to the P2Pool node's bitcoind, by software; hashers connected to a node need none | A node requirement in software does not apply to hashers |
| [Two-phase proof of work](https://web.archive.org/web/2015id_/http://hackingdistributed.com/2014/06/18/how-to-disincentivize-large-bitcoin-mining-pools/) (Eyal, Sirer) | 2014 | Valid if SHA256d(header) < X and SHA256(SIG(header, coinbase key)) < Y; ASICs produce phase-1 "half-solutions" at a raised X | The payout key; outsourcing phase 2 hands over the key, and the holder can take the reward | Structurally closest: ASIC pre-filter, a second per-candidate step, a tunable split. Our phase 2 needs data, not a key, and a data service cannot redirect the payout, so nothing deters outsourcing |
| [Permacoin](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/permacoin.pdf) (Miller, Juels, Shi, Parno, Katz) | 2014 | Payout key signs each of k sequential iterations; each access depends on the previous signature | The key, and local storage: remote data costs a round trip per iteration | Our 8 reads all derive from c and fit in one round trip; Permacoin's sequential dependency is the countermeasure we lack |
| [Proof of unique blockchain storage](https://bitslog.com/2014/11/03/proof-of-local-blockchain-storage/) (Lerner) | 2014 | Chain stored under an asymmetric-time encoding keyed to node identity; timed challenges | A node identity to a unique local copy; for node incentives, not mining | An identity-keyed encoding of chunks would stop one shared copy serving every miner |
| [Nonoutsourceable scratch-off puzzles](https://www.cs.umd.edu/~jkatz/papers/nonoutsourceable.pdf) (Miller, Kosba, Katz, Shi) | CCS 2015 | Weak: Merkle tree of random leaves, attempts open q leaves, a win is signed by revealing leaves. Strong: ticket encrypted, plus a non-interactive zero-knowledge proof | A signing secret; any worker able to mine can steal the win | Supplies the formal criterion our rule fails; its section on combining a weakly nonoutsourceable puzzle with an arbitrary one suggests a hybrid for ASIC compatibility |
| [Validationless mining forks](https://bitcoin.org/en/alert/2015-07-04-spv-mining) | July 2015 | About half the hashrate built on an invalid block after BIP66 enforcement: 6 invalid blocks on July 4, 3 on July 5 | Nothing | The motivating problem: hashpower builds on headers when nothing requires a node |
| [Previous-witness-data proof](https://www.mail-archive.com/bitcoin-dev@lists.linuxfoundation.org/msg03178.html) (Todd) | Dec 2015 | Each block includes a hash of the previous block's witness data re-merkleized with a per-miner prefix; suggests extending it to random earlier blocks | Possession of prior block data, once per block; outsourceable to anyone with the data | Closest precursor on the Bitcoin mailing list to an archival requirement; outside the hashing loop |
| [SmartPool](https://www.usenix.org/system/files/conference/usenixsecurity17/sec17-luu.pdf) (Luu, Velner, Teutsch, Saxena) | 2017 | Ethereum contract replaces the operator; miners build templates locally; share batches checked by sampling | Payout to the contract; local templates permitted, not required | Decentralizes payout, binds nothing |
| [BetterHash](https://github.com/TheBlueMatt/bips/blob/betterhash/bip-XXXX.mediawiki) (Corallo) | 2018 | Work Protocol from a local bitcoind, separate Pool Protocol | Nothing at consensus level; ASICs may run headers-only | A protocol option, not a requirement |
| [SPoRA, ANS-103](https://github.com/ArweaveTeam/arweave-standards/blob/ans-103/ans/ANS-103.md) (Williams, Berman) | 2020 | Search space of 10% of the weave; later packing per mining address and a verifiable delay function | Local storage, later a replica per mining address | Production precedent: the single-chunk design was outsourced "via a Gbit Internet link"; the fix was key-bound encoding plus read volume |
| [Braidpool](https://github.com/braidpool/braidpool) (McElrath) | 2021 (repository created) | Directed acyclic graph of beads at about 1000× the block rate; miner-built blocks; FROST custody | Templates to the miner's node, by software | Software requirement only |
| [Stratum V2 Job Declaration](https://github.com/stratum-mining/sv2-spec/blob/main/06-Job-Declaration-Protocol.md) | Spec undated | Miner-side client declares custom jobs from its own template provider | Nothing at consensus level; opt-in | Leaves the node optional |
| [DATUM](https://github.com/OCEAN-xyz/datum_gateway) (OCEAN, Hughes) | 2024 | Gateway builds templates from a local full node; the pool supplies only the payout split | Template to the operator's node, by pool policy | Closest deployed "miners run nodes" system, still voluntary; ratum implements this protocol |

## Commitments and succinct verification

No published scheme found commits in its header to the serialized bytes of all prior blocks; every chain-history commitment located covers headers, header-derived fields, transaction objects or user data. The closest deployed analog is Zcash ZIP 221: a BLAKE2b Merkle mountain range over history up to the parent, committed in the header, with header-derived leaves.

| Work | Year | What the commitment covers | Where it lives | Proof and verifier | Relation to our design |
| --- | --- | --- | --- | --- | --- |
| [Merkle mountain range (Todd)](https://github.com/opentimestamps/opentimestamps-server/blob/master/doc/merkle-mountain-range.md) | 2012 (first as "Merkle Calendars", 2012-10-13) | Any appended digests; peaks bagged into one digest | OpenTimestamps server | Log-size paths | Our base structure |
| [Crosby and Wallach, history tree](https://www.usenix.org/conference/usenixsecurity09/technical-sessions/presentation/efficient-data-structures-tamper-evident) | 2009 | Append-only log entries | Tamper-evident logs | O(log n) membership and consistency proofs | Earlier append-only Merkle tree (paper not read, venue page only) |
| [RFC 6962, Certificate Transparency](https://www.rfc-editor.org/rfc/rfc6962.txt) | 2013 | Certificates; leaf SHA-256(0x00‖d), node SHA-256(0x01‖l‖r) | Certificate Transparency logs | Audit paths, consistency proofs | Our 0x00 / 0x01 domain separation is taken from this |
| [Grin Merkle mountain ranges](https://github.com/mimblewimble/grin/blob/master/doc/mmr.md) | about 2017 | Headers (`prev_root`), all outputs, range proofs, kernels | Block header | Fast sync validates Merkle mountain ranges against header roots | Header Merkle mountain range commits to the state after the parent, and peaks are bagged with the size N as a prefix, as ours are; leaves are not block bytes and are not inputs to proof of work |
| [FlyClient](https://eprint.iacr.org/2019/226) (Bünz, Kiffer, Luu, Zamani) | 2019, IEEE S&P 2020 | Hash of each prior block, nodes carry aggregate difficulty | Each header holds the Merkle mountain range root through the parent | Light client samples O(log n) blocks by cumulative work, checks their proof of work and paths | Same header-committed Merkle mountain range pattern; leaves are headers, and it proves cumulative work, not one header's data reads |
| [ZIP 221](https://zips.z.cash/zip-0221) (Lai, Prestwich, Konstantopoulos) | 2019, deployed in Zcash Heartwood | Header-derived values per block (hash, time, target, note roots, work) | `hashChainHistoryRoot` in the header, reset at each network upgrade | FlyClient proofs | Closest deployed analog: BLAKE2b Merkle mountain range up to the parent in the header; no transaction bytes |
| [NiPoPoWs](https://eprint.iacr.org/2017/963) (Kiayias, Miller, Zindros) | 2017, FC 2020 | Interlink vector of superblock pointers, as a Merkle tree | Header, coinbase, or optional (velvet) | Superblock headers plus interlink paths, for light clients | Succinct work proofs over headers only |
| [High-Value-Hash Highway](https://bitcointalk.org/index.php?topic=98986.0) (Miller) | 2012 | Back-pointer to the last higher-value block | Block | Skip list for O(log N) work estimates | Precursor of NiPoPoWs |
| [Ultimate blockchain compression](https://bitcointalk.org/index.php?topic=88208.0) (Reiner) | 2012 | Per-address unspent transaction output trees | Merge-mined side chain header | O(log N) branches for light nodes | Unspent transaction output state, not history |
| [Merkle prefix trees BIP draft](https://gist.github.com/maaku/2aed2cb628024800044d) (Friedenbach) | 2013 | Committed unspent transaction output and validation indices | Proposed consensus commitment | Peer-to-peer proof queries | Unspent transaction output state, not history |
| [Delayed TXO commitments](https://petertodd.org/2016/delayed-txo-commitments) (Todd) | 2016 | Merkle mountain range of all transaction outputs, spent status updated in place | Block i commits to the state of block i − n | Spends of archived outputs carry log2(n) paths | Uses Merkle mountain range paths inside a consensus rule, for outputs, not block bytes |
| [Utreexo](https://eprint.iacr.org/2019/611) (Dryja) | 2019 | Forest of perfect Merkle trees over unspent transaction output hashes | Computed by each node, not in headers | Transactions carry inclusion proofs; bridge nodes keep the forest | Same forest-of-perfect-trees shape as a Merkle mountain range; not committed |
| [EIP-2935](https://eips.ethereum.org/EIPS/eip-2935) | 2020, in Pectra 2025 | Last 8191 block hashes, ring buffer | Ethereum state | Ordinary state proofs | Recent headers only |
| [Portal history accumulator](https://github.com/ethereum/portal-network-specs) | Frozen at the merge (2022); EIP-7643 2024 | Pre-merge epochs of (block hash, total difficulty) | Frozen, root hardcoded in clients (EIP-7643) | Paths for historical headers | Header history, not a proof of work rule |

Arweave also uses Merkle paths into historical data inside proof of work; it is covered with chain-data schemes above.

## Provenance of each element

Nine of our rule's twelve elements have a direct precedent. Three have none that the searches found: raw serialized block bytes as the leaves, a mandatory read inside the parent block, and proofs carried with headers to protect headers-first sync. The pre-filter's structure is two-phase proof of work's; no precedent was found for putting it in front of data reads.

| Element of our rule | Earliest precedent found | Other precedents | Our variation |
| --- | --- | --- | --- |
| Header hash selects reads across the whole chain | Hashimoto (Dryja) | Casatta's variant of Popescu (2016), SPoRA (2020) | 8 reads, positions from the four 64-bit words of c plus a per-read offset |
| Reads of real chain data, not a generated dataset | Hashimoto (txids) | Popescu (2016), Arweave Proof of Access, EWoK (2017) | Raw bytes of every block |
| Header hash first, data second, so the ASIC hash is unchanged | Hashimoto | SPoRA (a RandomX first stage) | The first stage is the chain's existing BLAKE2b header hash |
| A cheap first stage filters candidates before a second per-candidate step | Two-phase proof of work (Eyal, Sirer 2014), with a signature as phase 2 | Ethash's stored mix digest (a verifier-side check, not a miner filter) | Phase 2 is data reads, not a key; no precedent found for a p-bit filter in front of data reads |
| Final hash over the first-stage hash and the data read | SPoRA (2020) | Merkle Tree Proof (2016) over a generated dataset | BLAKE2b-256(c ‖ 8 chunks) |
| Reads proven by Merkle paths so verifiers need no data | Coelho (2007) for generated leaves; Permacoin (2014) for stored data | Merkle Tree Proof (2016), SmartPool (2017), SPoRA (2020) | Paths into a Merkle mountain range of the chain |
| 64-byte read unit | Permacoin (64-byte segments considered) | Burstcoin scoops, Sia leaves (64 bytes) | Same size |
| Merkle mountain range | Todd (2012) | Crosby and Wallach (2009), RFC 6962 (2013) | 0x00 / 0x01 / 0x02 domain separation as in RFC 6962 |
| Header commits to history through the parent | FlyClient (2019), ZIP 221 (deployed) | Grin (header Merkle mountain range, bagged with the size N) | Leaves are chunks of block bytes, not headers; the commitment also carries S |
| Leaves are raw serialized block bytes | None found | Arweave commits user data chunks | New within the scope of the searches |
| One read forced into the parent block | None found as a separate rule | Popescu's digest covers a byte of every block, the parent included; Arweave 2.6 splits reads into a local and a global range | Forces receiving the parent before mining on it |
| Header proofs keep headers-first sync protected against denial of service | None found as a proof carried with headers | Dagger-Hashimoto and Ethash describe their cheap outer check as protection against distributed denial of service | Proofs travel with headers in `hdrproofs` |

The on-disk tree layout (levels 6 and up stored, lower levels recomputed from 4 KiB of chunks) is engineering; it was not searched for as prior art.

## What is new, what is inherited, what is open

The combination appears new: Hashimoto's reads over the real chain, run only on pre-filtered candidates so deployed ASICs are unchanged, with a Merkle mountain range of raw block bytes committed in the header so nodes without the chain can check each header. Its central weakness is inherited, and prior art records both the failure and the known fixes.

**Inherited weakness: the reads can be outsourced.**

- Hashimoto argued outsourcing costs "several terabytes per second"; that counts data moved to the hasher, not the hash moved to the data.
- Arweave's Proof of Access was outsourced in production: one storage and computation pool served preimages to many miners over a Gbit link.
- EWoK's authors rejected reading the chain after the proof of work is solved, our order, because it binds only the pool operator.
- For our rule, a site without the chain sends each candidate (about 16 bytes) to a remote holder: about 0.5 Gbit/s per PH/s at p = 28.

**Known fixes in prior art, and what each would cost us:**

| Fix | Used by | Effect on a remote data service | Cost or conflict for our rule |
| --- | --- | --- | --- |
| Payout key inside the second stage | Two-phase proof of work, Miller et al., Permacoin | Whoever runs phase 2 can take the reward | Our phase 2 is data, and the header already commits to the coinbase, so a data service cannot steal; a key step would have to be added to candidate processing |
| Data encoded per mining address (packing) | Arweave 2.6, Filecoin, Lerner | Must hold one replica per customer address instead of one shared copy | Each proof must also show the encoding, so verifiers repeat the encoding cost; about 700 GB per address |
| Sequential dependent reads | Permacoin, Lerner | A round trip per read | Adds latency, which a pipelining service hides, unless attempts are subject to a time limit (Arweave adds a verifiable delay function) |
| Large per-attempt read volume | SPoRA (10% search space, 256 KiB chunks) | Raises bytes moved per attempt | Only binds if the data, not the attempt, has to move |

**Implementation lessons already applied:** bind each opening to its position (the Merkle Tree Proof attacks) and derive positions from the full hash (the ProgPoW exploit); both are covered under generated-dataset proof of work.

**Open questions:**

1. Can per-address packing of chunks, or a payout-key step in candidate processing, be added while chips stay unchanged and proofs stay small?
2. Does any p make remote serving cost more than a local copy, given the device result-path limit? The hardware test measures the result path.
3. [NEC patent US10397328B2](https://patents.google.com/patent/US10397328B2/en) (EWoK, granted 2019) describes binding mining to stored blockchain parts with an embedded proof of storage; its scope relative to our rule was not analyzed.
4. Coverage: five parallel searches over papers, forums, mailing lists, specs and code. Patent databases beyond that one patent, and non-English literature, were not searched.

## Sources

Each work's name in the tables links to the primary source that was opened. Pages cited in the text, and secondary sources used for dates and mechanisms:

- [Popescu's post, archived with its 42 comments](http://web.archive.org/web/20251114113328/http://trilema.com/2016/the-necessary-prerequisite-for-any-change-to-the-bitcoin-protocol/) (the live site did not respond)
- [Dagger-Hashimoto, old Ethereum wiki mirror](https://github.com/BlockChainCaffe/EthereumWiki/blob/master/Dagger-Hashimoto.md) (quotes Hashimoto and records the abandoned blockchain-based proof of work)
- [ANS-103, SPoRA](https://github.com/ArweaveTeam/arweave-standards/blob/master/ans/ANS-103.md) (the Proof of Access outsourcing account)
- [Arweave 2.6 spec](https://2-6-spec.arweave.net/) and [mining docs](https://docs.arweave.org/developers/mining/overview/mining)
- [Bevand, Attacks on MTP](https://blog.zorinaq.com/attacks-on-mtp/); [Dinur and Nadler, time-memory tradeoffs on MTP](https://eprint.iacr.org/2017/497) (abstract only)
- [ProgPoW seed exploit](https://github.com/kik/progpow-exploit)
- [Lerner, Ethereum Dagger PoW is flawed](http://bitslog.com/2014/01/17/ethereum-dagger-pow-is-flawed/)
- [Eyal and Sirer, "It's Time For a Hard Bitcoin Fork"](https://web.archive.org/web/2015id_/http://hackingdistributed.com/2014/06/13/time-for-a-hard-bitcoin-fork/) (motivation only; the two-phase mechanism is in the 18 June post linked above)
- [Portal network history spec](https://github.com/ethereum/portal-network-specs/blob/master/history/history-network.md)

**Searched for but not found or not verified:** the original date and venue of Hashimoto; any deployment of Hashimoto over real chain data; a bitcoin-dev proposal for proof of work with unspent transaction output lookups beyond the wiki entry; an implementation of Popescu's proposal or his later "Luby codes" mention; Crosby and Wallach's full paper; the full Dinur and Nadler paper; Burstcoin's launch date; SpaceMint's venue; Arweave's SPoRA announcement post (HTTP 403).
