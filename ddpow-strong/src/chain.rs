//! Block proof section and header verification from an anchor (bip-strong-ddpow.md,
//! Specification). The section is carried in the block, outside the block hash. An archival miner
//! builds it; a pruned validator and a header-only light client check it against Merkle
//! mountain range peaks they computed themselves, holding no chain data.
//!
//! Headers are the chain's v2 headers (`header.rs`): `h0` is the stage-3 digest `hash2`, and
//! `final`, XORed with the header's mask and read as a block hash, must meet `nBits`.
//!
//!   ddpow-strong chain [--blocks 3000] [--activation 1000] [--body-kib 64] [--nbits 1f400000]

use super::header::{self, V2Header};
use super::{CHUNK, Mmr, arg, arg_str, attempt, blake2b, commit, fold, idx, leaf, mix, node, peak_for};
use std::collections::HashSet;
use std::time::Instant;

pub const K: usize = 8;

type Hash = [u8; 32];
type Chunk = [u8; CHUNK];

impl Mmr {
    fn empty() -> Self {
        Mmr { levels: vec![Vec::new()], count: 0 }
    }

    /// Appends a leaf, keeping every level in the layout `build` produces.
    fn push(&mut self, leaf: Hash) {
        self.levels[0].push(leaf);
        self.count += 1;
        let mut l = 0;
        while self.levels[l].len() % 2 == 0 {
            let lo = &self.levels[l];
            let up = node(&lo[lo.len() - 2], &lo[lo.len() - 1]);
            if self.levels.len() == l + 1 {
                self.levels.push(Vec::new());
            }
            self.levels[l + 1].push(up);
            l += 1;
        }
    }

    /// Root of the aligned subtree of height `b` starting at leaf `p`.
    fn root(&self, p: u64, b: u32) -> Hash {
        self.levels[b as usize][(p >> b) as usize]
    }
}

/// Peaks with their heights, highest first, over `count` leaves: what a pruned validator and a
/// light client keep.
#[derive(Clone, Debug, PartialEq)]
pub struct Peaks {
    pub count: u64,
    pub list: Vec<(u32, Hash)>,
}

impl Peaks {
    pub fn new() -> Self {
        Peaks { count: 0, list: Vec::new() }
    }

    fn from_mmr(m: &Mmr) -> Self {
        let heights = (0..64u32).rev().filter(|l| (m.count >> l) & 1 == 1);
        Peaks { count: m.count, list: heights.zip(m.peaks()).collect() }
    }

    /// Append (Specification): push a subtree root of height `b`; while the last two peaks have
    /// equal height, replace them with their parent. Requires `count` to be a multiple of 2^b.
    pub fn append(&mut self, b: u32, root: Hash) {
        assert_eq!(self.count % (1u64 << b), 0, "unaligned append");
        self.list.push((b, root));
        self.count += 1u64 << b;
        while self.list.len() >= 2 {
            let (hr, r) = self.list[self.list.len() - 1];
            let (hl, l) = self.list[self.list.len() - 2];
            if hl != hr {
                break;
            }
            self.list.truncate(self.list.len() - 2);
            self.list.push((hl + 1, node(&l, &r)));
        }
    }

    fn hashes(&self) -> Vec<Hash> {
        self.list.iter().map(|p| p.1).collect()
    }

    /// `mm_rhs` for the tree over these peaks whose parent block starts at leaf `s`.
    pub fn commitment(&self, s: u64) -> Hash {
        commit(self.count, s, &self.hashes())
    }

    /// Index and height of the peak holding leaf `pos`.
    fn holding(&self, pos: u64) -> Option<(usize, u32)> {
        let mut start = 0u64;
        for (i, &(h, _)) in self.list.iter().enumerate() {
            start += 1u64 << h;
            if pos < start {
                return Some((i, h));
            }
        }
        None
    }
}

/// Aligned cover of leaves `[s, n)` (Specification): (start, height) left to right, each the
/// largest subtree with `start mod 2^height = 0` that ends at or before `n`.
pub fn cover(s: u64, n: u64) -> Vec<(u64, u32)> {
    let mut out = Vec::new();
    let mut p = s;
    while p < n {
        let mut b = if p == 0 { 63 } else { p.trailing_zeros() };
        while n - p < 1u64 << b {
            b -= 1;
        }
        out.push((p, b));
        p += 1u64 << b;
    }
    out
}

/// Root of a perfect subtree over `leaves` (length a power of two).
fn subtree_root(leaves: &[Hash]) -> Hash {
    let mut level = leaves.to_vec();
    while level.len() > 1 {
        level = level.chunks(2).map(|p| node(&p[0], &p[1])).collect();
    }
    level[0]
}

fn chunks_of(bytes: &[u8]) -> Vec<Chunk> {
    bytes
        .chunks(CHUNK)
        .map(|c| {
            let mut x = [0u8; CHUNK];
            x[..c.len()].copy_from_slice(c);
            x
        })
        .collect()
}

pub type Header = V2Header;

impl V2Header {
    /// The stage-3 digest `hash2`: the value the rule's reads start from.
    #[cfg(test)]
    pub fn h0(&self) -> Hash {
        self.stages().hash2
    }

    /// `GetHash` in internal byte order, as `hashPrevBlock` stores it.
    pub fn id(&self) -> Hash {
        let mut h = self.block_hash();
        h.reverse();
        h
    }

    /// A header for block `height` on `prev`: all four hashing-hardware profiles in turn, a
    /// non-null XOR key, and the transaction Merkle root replaced by the body's hash.
    fn template(prev: Hash, content: Hash, height: u64, nbits: u32, mm_rhs: Hash) -> Self {
        V2Header {
            version: 0x2000_0000 | header::V2_FLAG,
            prev,
            merkle: content,
            time: 1_800_000_000 + 600 * height as u32,
            bits: nbits,
            nonce: 0,
            nonce2: 0,
            nonce3: 0,
            extranonce: content[..16].try_into().unwrap(),
            time_offset: 0,
            txcount: 1,
            flags: (height % 4) as u8,
            mask_clear_bits: 0,
            xor_key: content[16..].try_into().unwrap(),
            height: height as i32,
            mm_rhs,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Block {
    pub header: Header,
    pub body: Vec<u8>,
    pub section: Vec<u8>,
}

impl Block {
    /// Chunks of the block serialized without its proof section.
    fn chunks(&self) -> Vec<Chunk> {
        chunks_of(&[&self.header.serialize()[..], &self.body].concat())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reject {
    /// Section absent, truncated, trailing bytes, or `len` wrong.
    Encoding,
    /// `S` or `N` differ from the node's own counts.
    Counts,
    /// `ext` differs from the roots the node kept for the parent.
    Ext,
    /// `N - S > C_max` (header check without the chain).
    Oversize,
    /// `mm_rhs` differs from the commitment of the node's tree.
    Commitment,
    /// A chunk does not fold to its peak.
    Path,
    /// `final` above the target.
    Target,
    /// `nBits` differs from the required value.
    Bits,
    /// Parent is not the node's tip.
    Prev,
    /// Block hash recorded invalid.
    KnownInvalid,
}

impl Reject {
    /// Faults of the header, which record the block hash invalid; the rest are faults of this
    /// copy's proof section and leave the block hash unrecorded.
    fn header_fault(self) -> bool {
        matches!(self, Reject::Commitment | Reject::Target | Reject::Bits)
    }
}

/// The proof section. `reads` holds (position, chunk, path); positions and `fin` are recomputed
/// on decode, not encoded.
#[derive(Clone, Debug, PartialEq)]
pub struct Section {
    pub s: u64,
    pub n: u64,
    pub ext: Vec<Hash>,
    pub reads: Vec<(u64, Chunk, Vec<Hash>)>,
    pub fin: Hash,
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take<const L: usize>(&mut self) -> Result<[u8; L], Reject> {
        let end = self.at.checked_add(L).filter(|&e| e <= self.b.len()).ok_or(Reject::Encoding)?;
        let v = self.b[self.at..end].try_into().unwrap();
        self.at = end;
        Ok(v)
    }
}

impl Section {
    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend(self.s.to_le_bytes());
        body.extend(self.n.to_le_bytes());
        for r in &self.ext {
            body.extend(r);
        }
        for (_, chunk, path) in &self.reads {
            body.extend(chunk);
            for h in path {
                body.extend(h);
            }
        }
        [&(body.len() as u32).to_le_bytes()[..], &body].concat()
    }

    /// Parses a section for a header with digest `h0`. Field counts follow from `S`, `N` and the
    /// read positions, recomputed from `h0` and the chunks in order; `len` must equal the bytes
    /// after it exactly.
    pub fn decode(bytes: &[u8], h0: &Hash) -> Result<Section, Reject> {
        let mut r = Reader { b: bytes, at: 0 };
        let len = u32::from_le_bytes(r.take()?) as usize;
        if bytes.len() != 4 + len {
            return Err(Reject::Encoding);
        }
        let s = u64::from_le_bytes(r.take()?);
        let n = u64::from_le_bytes(r.take()?);
        if s >= n {
            return Err(Reject::Encoding);
        }
        let ext = cover(s, n).iter().map(|_| r.take()).collect::<Result<_, _>>()?;
        let mut reads = Vec::with_capacity(K);
        let mut x = *h0;
        let mut a = s + idx(&x, n - s);
        for i in 0..K {
            let chunk: Chunk = r.take()?;
            let (height, _) = peak_for(n, a);
            let path = (0..height).map(|_| r.take()).collect::<Result<_, _>>()?;
            reads.push((a, chunk, path));
            x = blake2b(&[&x, &chunk]);
            if i + 1 < K {
                a = idx(&x, n);
            }
        }
        if r.at != bytes.len() {
            return Err(Reject::Encoding);
        }
        Ok(Section { s, n, ext, reads, fin: x })
    }
}

/// Checks that each read's chunk folds at its position to the peak holding it.
fn verify_reads(sec: &Section, peaks: &Peaks) -> Result<(), Reject> {
    for (a, chunk, path) in &sec.reads {
        let (i, h) = peaks.holding(*a).ok_or(Reject::Path)?;
        if path.len() != h as usize || fold(leaf(chunk), *a, path) != peaks.list[i].1 {
            return Err(Reject::Path);
        }
    }
    Ok(())
}

/// Mines block `height` on `prev` over the tree `mmr` (parent from leaf `s`), reading chunks
/// through `chunk`, and returns the header with its encoded proof section. Stops at the first
/// nonce whose `final` meets `nbits` if `valid`, else at the first that does not.
#[allow(clippy::too_many_arguments)]
fn solve(prev: Hash, content: Hash, height: u64, mmr: &Mmr, s: u64, chunk: impl Fn(u64) -> Chunk, nbits: u32, valid: bool) -> (Header, Vec<u8>) {
    let n = mmr.count;
    let mut header = Header::template(prev, content, height, nbits, commit(n, s, &mmr.peaks()));
    loop {
        let st = header.stages();
        let mut pos = Vec::with_capacity(K);
        let fin = attempt(&st.hash2, K, n, s, |a| {
            pos.push(a);
            Some(chunk(a))
        })
        .unwrap();
        if header::meets(&fin, &st.mask, nbits) == valid {
            let sec = Section {
                s,
                n,
                ext: cover(s, n).iter().map(|&(p, b)| mmr.root(p, b)).collect(),
                reads: pos.iter().map(|&a| (a, chunk(a), mmr.path(a))).collect(),
                fin,
            };
            return (header, sec.encode());
        }
        header.nonce = header.nonce.wrapping_add(1);
        if header.nonce == 0 {
            header.nonce2 += 1;
        }
    }
}

/// Archival miner: holds every chunk and every tree level.
pub struct Miner {
    mmr: Mmr,
    chunks: Vec<Chunk>,
    /// Chunk count before the tip block (`S` for the next block).
    s: u64,
    /// Tip block hash, internal order.
    tip: Hash,
    height: u64,
    activation: u64,
    nbits: u32,
    max_body: usize,
    rng: u64,
}

impl Miner {
    pub fn new(activation: u64, nbits: u32, max_body: usize, seed: u64) -> Self {
        assert!(activation >= 2, "the anchor covers blocks 0..A-2");
        Miner { mmr: Mmr::empty(), chunks: Vec::new(), s: 0, tip: [0; 32], height: 0, activation, nbits, max_body, rng: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.rng = self.rng.wrapping_add(0x9E37_79B9_7F4A_7C15);
        mix(self.rng)
    }

    fn body(&mut self) -> Vec<u8> {
        let len = 1 + (self.next_u64() % self.max_body as u64) as usize;
        (0..len.div_ceil(8)).flat_map(|_| self.next_u64().to_le_bytes()).take(len).collect()
    }

    /// A block on the tip that is valid if `valid`, else one whose `final` misses the target.
    pub fn make(&mut self, valid: bool) -> Block {
        let body = self.body();
        let content = blake2b(&[&body]);
        let (header, section) = if self.height >= self.activation {
            let chunks = &self.chunks;
            solve(self.tip, content, self.height, &self.mmr, self.s, |a| chunks[a as usize], self.nbits, valid)
        } else {
            (Header::template(self.tip, content, self.height, self.nbits, [0; 32]), Vec::new())
        };
        Block { header, body, section }
    }

    pub fn mine(&mut self) -> Block {
        let block = self.make(true);
        self.s = self.mmr.count;
        for c in block.chunks() {
            self.mmr.push(leaf(&c));
            self.chunks.push(c);
        }
        self.tip = block.header.id();
        self.height += 1;
        block
    }
}

/// Pruned validator: keeps the peaks, the counts, and the tip block's aligned cover roots.
#[derive(Clone)]
pub struct Validator {
    pub peaks: Peaks,
    s: u64,
    ext: Vec<Hash>,
    tip: Hash,
    height: u64,
    activation: u64,
    nbits: u32,
    invalid: HashSet<Hash>,
}

impl Validator {
    pub fn new(activation: u64, nbits: u32) -> Self {
        Validator { peaks: Peaks::new(), s: 0, ext: Vec::new(), tip: [0; 32], height: 0, activation, nbits, invalid: HashSet::new() }
    }

    pub fn accept(&mut self, b: &Block) -> Result<(), Reject> {
        let id = b.header.id();
        if self.invalid.contains(&id) {
            return Err(Reject::KnownInvalid);
        }
        if b.header.prev != self.tip {
            return Err(Reject::Prev);
        }
        if self.height >= self.activation {
            if let Err(e) = self.check(b) {
                if e.header_fault() {
                    self.invalid.insert(id);
                }
                return Err(e);
            }
        }
        let leaves: Vec<Hash> = b.chunks().iter().map(|c| leaf(c)).collect();
        let s = self.peaks.count;
        let n = s + leaves.len() as u64;
        self.ext = cover(s, n).iter().map(|&(p, h)| subtree_root(&leaves[(p - s) as usize..][..1 << h])).collect();
        for l in leaves {
            self.peaks.append(0, l);
        }
        self.s = s;
        self.tip = id;
        self.height += 1;
        Ok(())
    }

    /// Verification (Specification), reading no chain data.
    fn check(&self, b: &Block) -> Result<(), Reject> {
        if b.header.bits != self.nbits {
            return Err(Reject::Bits);
        }
        if b.header.mm_rhs != self.peaks.commitment(self.s) {
            return Err(Reject::Commitment);
        }
        let st = b.header.stages();
        let sec = Section::decode(&b.section, &st.hash2)?;
        if sec.s != self.s || sec.n != self.peaks.count {
            return Err(Reject::Counts);
        }
        if sec.ext != self.ext {
            return Err(Reject::Ext);
        }
        verify_reads(&sec, &self.peaks)?;
        if !header::meets(&sec.fin, &st.mask, b.header.bits) {
            return Err(Reject::Target);
        }
        Ok(())
    }
}

/// Light client: headers and proof sections only, from the anchor.
#[derive(Clone)]
pub struct LightClient {
    /// Count and peaks of the tree the tip header commits to.
    pub held: Peaks,
    tip: Hash,
    nbits: u32,
    c_max: u64,
}

impl LightClient {
    /// `anchor`: peaks over blocks 0..A-2; `tip`: hash of block A-1, internal order.
    pub fn from_anchor(anchor: Peaks, tip: Hash, nbits: u32, c_max: u64) -> Self {
        LightClient { held: anchor, tip, nbits, c_max }
    }

    /// Header verification without the chain (Specification), steps 1 to 4.
    pub fn accept(&mut self, h: &Header, section: &[u8]) -> Result<(), Reject> {
        if h.prev != self.tip {
            return Err(Reject::Prev);
        }
        if h.bits != self.nbits {
            return Err(Reject::Bits);
        }
        let st = h.stages();
        let sec = Section::decode(section, &st.hash2)?;
        if sec.s != self.held.count {
            return Err(Reject::Counts);
        }
        if sec.n - sec.s > self.c_max {
            return Err(Reject::Oversize);
        }
        let mut peaks = self.held.clone();
        for (&(_, b), root) in cover(sec.s, sec.n).iter().zip(&sec.ext) {
            peaks.append(b, *root);
        }
        if h.mm_rhs != peaks.commitment(sec.s) {
            return Err(Reject::Commitment);
        }
        verify_reads(&sec, &peaks)?;
        if !header::meets(&sec.fin, &st.mask, h.bits) {
            return Err(Reject::Target);
        }
        self.held = peaks;
        self.tip = h.id();
        Ok(())
    }
}

/// A header check with peaks supplied alongside the header and no anchor: shows only that the
/// chunks match `mm_rhs`.
pub fn check_unanchored(h: &Header, section: &[u8], peaks: &Peaks) -> Result<(), Reject> {
    let st = h.stages();
    let sec = Section::decode(section, &st.hash2)?;
    if sec.n != peaks.count {
        return Err(Reject::Counts);
    }
    if h.mm_rhs != peaks.commitment(sec.s) {
        return Err(Reject::Commitment);
    }
    verify_reads(&sec, peaks)?;
    if !header::meets(&sec.fin, &st.mask, h.bits) {
        return Err(Reject::Target);
    }
    Ok(())
}

/// A tree over `count` zero chunks: a fabricated history.
fn zero_tree(count: u64) -> Mmr {
    let mut m = Mmr::empty();
    let z = leaf(&[0u8; CHUNK]);
    for _ in 0..count {
        m.push(z);
    }
    m
}

/// A mined chain with a pruned validator and a light client that followed it, and both
/// followers' state before the last block.
pub struct Sim {
    pub miner: Miner,
    #[cfg_attr(not(test), allow(dead_code))]
    pub val: Validator,
    pub light: LightClient,
    pub val_before_last: Validator,
    pub light_before_last: LightClient,
    pub blocks: Vec<Block>,
    pub c_max: u64,
}

/// Mines `blocks` blocks and runs the validator and light client in step, checking both
/// followers' peaks against the miner's tree at every height.
pub fn simulate(blocks: u64, activation: u64, max_body: usize, nbits: u32, seed: u64) -> Sim {
    assert!(blocks > activation, "activation within the run");
    let mut miner = Miner::new(activation, nbits, max_body, seed);
    let mut val = Validator::new(activation, nbits);
    // Header plus the largest body.
    let c_max = (header::SIZE + max_body).div_ceil(CHUNK) as u64;
    let mut light: Option<LightClient> = None;
    let mut before_last = None;
    let mut out = Vec::new();
    for h in 0..blocks {
        if h + 1 == blocks {
            before_last = Some((val.clone(), light.clone().unwrap()));
        }
        // Tree over blocks 0..h-1: what header h commits to.
        let before = Peaks::from_mmr(&miner.mmr);
        let b = miner.mine();
        val.accept(&b).unwrap_or_else(|e| panic!("validator rejected block {h}: {e:?}"));
        if h == activation - 1 {
            light = Some(LightClient::from_anchor(before, b.header.id(), nbits, c_max));
        } else if let Some(l) = light.as_mut() {
            l.accept(&b.header, &b.section).unwrap_or_else(|e| panic!("light client rejected header {h}: {e:?}"));
            assert_eq!(l.held, before, "light client peaks differ at {h}");
        }
        assert_eq!(val.peaks, Peaks::from_mmr(&miner.mmr), "validator peaks differ at {h}");
        out.push(b);
    }
    let (val_before_last, light_before_last) = before_last.unwrap();
    Sim { miner, val, light: light.unwrap(), val_before_last, light_before_last, blocks: out, c_max }
}

/// Flips each bit pattern in `flips` at every byte of the last block's section and submits each
/// copy to the validator and the light client as they stood before that block. Returns reject
/// counts per reason; panics if any copy is accepted or recorded invalid.
pub fn mutate_all(sim: &Sim, flips: &[u8]) -> Vec<(Reject, usize)> {
    let b = sim.blocks.last().unwrap();
    let mut copies: Vec<Vec<u8>> = Vec::new();
    for i in 0..b.section.len() {
        for f in flips {
            let mut m = b.section.clone();
            m[i] ^= f;
            copies.push(m);
        }
    }
    copies.push(Vec::new());
    copies.push(b.section[..b.section.len() - 1].to_vec());
    copies.push([&b.section[..], &[0]].concat());
    let mut counts: Vec<(Reject, usize)> = Vec::new();
    let mut val = sim.val_before_last.clone();
    for section in copies {
        let m = Block { section, ..b.clone() };
        let e = val.accept(&m).expect_err("mutated section accepted by validator");
        assert!(!e.header_fault(), "mutated section recorded as a header fault: {e:?}");
        sim.light_before_last.clone().accept(&m.header, &m.section).expect_err("mutated section accepted by light client");
        match counts.iter_mut().find(|c| c.0 == e) {
            Some(c) => c.1 += 1,
            None => counts.push((e, 1)),
        }
    }
    assert!(val.invalid.is_empty(), "a mutated section recorded the block hash invalid");
    val.accept(b).expect("original block rejected after mutated copies");
    counts
}

/// `(mean, max)` of `ext` count and section bytes for a full chain of `n` chunks: `samples`
/// blocks of `c_max` chunks with `n` drawn from `[n, n + spread)`.
pub fn sizes(n: u64, spread: u64, block: u64, samples: u64) -> ((f64, usize), (f64, usize)) {
    let (mut ext_sum, mut ext_max, mut b_sum, mut b_max) = (0usize, 0usize, 0usize, 0usize);
    for i in 0..samples {
        let n = n + mix(i) % spread;
        let s = n - block;
        let ext = cover(s, n).len();
        let mut bytes = 4 + 16 + 32 * ext;
        for r in 0..K as u64 {
            let x = mix(i.wrapping_mul(31).wrapping_add(r + 1));
            let a = if r == 0 { s + x % block } else { x % n };
            bytes += CHUNK + 32 * peak_for(n, a).0;
        }
        ext_sum += ext;
        ext_max = ext_max.max(ext);
        b_sum += bytes;
        b_max = b_max.max(bytes);
    }
    ((ext_sum as f64 / samples as f64, ext_max), (b_sum as f64 / samples as f64, b_max))
}

pub fn run() {
    let blocks = arg("--blocks", 3000.0) as u64;
    let activation = arg("--activation", 1000.0) as u64;
    let max_body = (arg("--body-kib", 64.0) * 1024.0) as usize;
    let nbits = u32::from_str_radix(&arg_str("--nbits").unwrap_or("1f400000".into()), 16).expect("--nbits: hex");
    let t_bytes = header::target(nbits).expect("--nbits: valid compact target");
    let attempts_per_block = 2f64.powi(256) / t_bytes.iter().fold(0f64, |a, &b| a * 256.0 + b as f64);

    let t = Instant::now();
    let sim = simulate(blocks, activation, max_body, nbits, 1);
    let n = sim.miner.mmr.count;
    let proved = &sim.blocks[activation as usize..];
    let sec_bytes: Vec<usize> = proved.iter().map(|b| b.section.len()).collect();
    println!(
        "chain: {blocks} blocks, activation {activation}, {n} chunks ({:.0} MiB), C_max {} chunks, nBits 0x{nbits:08x} ({attempts_per_block:.0} attempts per block), {:.1}s",
        (n as usize * CHUNK) as f64 / (1 << 20) as f64,
        sim.c_max,
        t.elapsed().as_secs_f64()
    );
    println!("  headers: v2, 164 bytes, h0 = stage-3 digest hash2, final XOR mask read as a block hash against nBits; hardware profiles 0 to 3 in turn");
    println!(
        "  pruned validator (peaks only) and light client (headers and sections from the anchor over blocks 0..{}) accepted all {} proved blocks; both matched the miner's peaks at every height",
        activation - 2,
        proved.len()
    );
    println!(
        "  section bytes: mean {:.0}, max {} (vs block mean {:.0})",
        sec_bytes.iter().sum::<usize>() as f64 / sec_bytes.len() as f64,
        sec_bytes.iter().max().unwrap(),
        proved.iter().map(|b| header::SIZE + b.body.len()).sum::<usize>() as f64 / proved.len() as f64
    );

    // Verification time: light client from the anchor state before the last block, repeated.
    let last = sim.blocks.last().unwrap();
    let reps = 20_000;
    let t = Instant::now();
    for _ in 0..reps {
        sim.light_before_last.clone().accept(&last.header, &last.section).unwrap();
    }
    println!("  light client header check: {:.1} us", t.elapsed().as_secs_f64() * 1e6 / reps as f64);

    let counts = mutate_all(&sim, &[0x01, 0x80]);
    let total: usize = counts.iter().map(|c| c.1).sum();
    println!(
        "mutated sections: {total} copies of the last block's section (each byte, bits 0 and 7; absent; truncated; one trailing byte): all rejected by both, none recorded invalid, original then accepted"
    );
    println!("  validator rejects: {}", counts.iter().map(|(r, c)| format!("{r:?} {c}")).collect::<Vec<_>>().join(", "));

    // Fabricated tree: a header on the real tip whose tree is 1,000 zero chunks.
    let fake = zero_tree(1000);
    let t = Instant::now();
    let tip = last.header.id();
    let (h, sec) = solve(tip, [1; 32], blocks, &fake, 990, |_| [0; CHUNK], nbits, true);
    let secs = t.elapsed().as_secs_f64();
    println!(
        "fabricated tree (1,000 zero chunks, {} attempts, {secs:.3}s): unanchored check {:?}, anchored light client {:?}",
        h.nonce + 1,
        check_unanchored(&h, &sec, &Peaks::from_mmr(&fake)),
        sim.light.clone().accept(&h, &sec)
    );

    // Fabricated history with correct counts: zero chunks over the whole tree.
    let (s, nn) = (sim.miner.s, n);
    let fake = zero_tree(nn);
    let (h, sec) = solve(tip, [2; 32], blocks, &fake, s, |_| [0; CHUNK], nbits, true);
    println!(
        "fabricated history ({nn} zero chunks, S and N correct): unanchored {:?}, anchored {:?}",
        check_unanchored(&h, &sec, &Peaks::from_mmr(&fake)),
        sim.light.clone().accept(&h, &sec)
    );

    // Oversize: the real history, then a tip block claiming C_max + 1 chunks.
    let mut over = Mmr::empty();
    for c in &sim.miner.chunks[..s as usize] {
        over.push(leaf(c));
    }
    for _ in 0..=sim.c_max {
        over.push(leaf(&[0; CHUNK]));
    }
    let chunks = &sim.miner.chunks;
    let (h, sec) = solve(tip, [3; 32], blocks, &over, s, |a| if a < s { chunks[a as usize] } else { [0; CHUNK] }, nbits, true);
    let mut unbounded = sim.light.clone();
    unbounded.c_max = u64::MAX;
    println!(
        "oversize parent (N - S = C_max + 1): light client {:?}; without the bound {:?}",
        sim.light.clone().accept(&h, &sec),
        unbounded.accept(&h, &sec)
    );

    // Fork without the chain: the attacker holds only its m fabricated blocks at the end.
    println!("fork without the chain (attacker holds only m blocks of C_max fabricated chunks; 1,000,000 attempts):");
    println!("{:>8} {:>16} {:>12} {:>14}", "m", "fabricated share", "completed", "expected");
    for m in [1, 16, n / sim.c_max / 2] {
        let fake_len = (m * sim.c_max).min(n);
        let from = n - fake_len;
        let s = n - sim.c_max.min(fake_len);
        let attempts = 1_000_000u64;
        let mut done = 0u64;
        for i in 0..attempts {
            let h0 = blake2b(&[&i.to_le_bytes()]);
            if attempt(&h0, K, n, s, |a| (a >= from).then_some([0; CHUNK])).is_some() {
                done += 1;
            }
        }
        let share = fake_len as f64 / n as f64;
        println!("{m:>8} {share:>16.4} {done:>12} {:>14.3e}", attempts as f64 * share.powi(K as i32 - 1));
    }

    // Section size at the real chain's scale.
    let full = 700u64 << 30;
    let n_real = full / CHUNK as u64;
    let ((em, ex), (bm, bx)) = sizes(n_real, n_real / 100, 62_500, 200_000);
    println!(
        "section at 700 GiB ({n_real} chunks, 62,500-chunk blocks, 200,000 samples): ext mean {em:.1} max {ex}; bytes mean {bm:.0} max {bx}; {:.2} GB per year at the mean",
        bm * 52_560.0 / 1e9
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// About 16 attempts per block.
    const NBITS: u32 = 0x200f_ffff;

    #[test]
    fn append_and_cover_match_full_tree() {
        let mut m = Mmr::empty();
        let mut p = Peaks::new();
        let mut rng = 7u64;
        let mut count = 0u64;
        for _ in 0..300 {
            rng = mix(rng);
            let len = 1 + rng % 700;
            let leaves: Vec<Hash> = (count..count + len).map(|i| leaf(&[i as u8; CHUNK])).collect();
            for l in &leaves {
                m.push(*l);
            }
            // Append the block's aligned cover roots, computed from its leaves alone.
            for (s, b) in cover(count, count + len) {
                let root = subtree_root(&leaves[(s - count) as usize..][..1 << b]);
                assert_eq!(root, m.root(s, b), "cover root is not a node of the tree");
                p.append(b, root);
            }
            count += len;
            assert_eq!(p, Peaks::from_mmr(&m));
        }
        let built = Mmr::build(&(0..count).map(|i| [i as u8; CHUNK]).collect::<Vec<_>>());
        assert_eq!(built.peaks(), m.peaks());
    }

    /// Vectors A and B of the node's ddpow_tests.cpp under the strong rule: hash2 = 0..31,
    /// eight reads. The node's unit test checks the same positions and final digests.
    #[test]
    fn node_strong_vectors() {
        let pattern = |n: usize, mul: usize, add: usize| -> Vec<u8> { (0..n).map(|i| ((i * mul + add) & 0xff) as u8).collect() };
        let h2: Hash = std::array::from_fn(|i| i as u8);
        let run = |ch: &[Chunk], s: u64| {
            let mut pos = Vec::new();
            let fin = attempt(&h2, 8, ch.len() as u64, s, |a| {
                pos.push(a);
                Some(ch[a as usize])
            })
            .unwrap();
            (pos, fin.iter().map(|b| format!("{b:02x}")).collect::<String>())
        };
        let a = chunks_of(&pattern(64 * 10 + 17, 7, 3));
        assert_eq!(run(&a, 0), (vec![6, 6, 6, 9, 5, 7, 0, 6], "fb4db47c71f5519b6405341a9ff5c34fa56d068b642b375613ff9d2d911e733f".into()));
        let b: Vec<Chunk> = [pattern(100, 1, 11), pattern(200, 2, 11), pattern(300, 3, 11)].iter().flat_map(|x| chunks_of(x)).collect();
        assert_eq!(run(&b, 6), (vec![9, 8, 1, 4, 8, 3, 10, 5], "005af8794a441fab3cc5af9f4cf200296ad7d00d11612392c3ef1207b4996f5f".into()));
    }

    #[test]
    fn cover_bounds() {
        for s in 0..300u64 {
            for len in 1..300u64 {
                let c = cover(s, s + len);
                let mut p = s;
                for &(q, b) in &c {
                    assert_eq!(q, p);
                    assert_eq!(q % (1 << b), 0);
                    p += 1 << b;
                }
                assert_eq!(p, s + len);
                assert!(c.len() <= 2 * (64 - len.leading_zeros()) as usize);
            }
        }
    }

    #[test]
    fn chain_followers_and_mutations() {
        let sim = simulate(80, 20, 3000, NBITS, 11);
        let counts = mutate_all(&sim, &[0x01, 0x10, 0x80]);
        assert!(counts.iter().map(|c| c.1).sum::<usize>() > 3 * 1000);
        // Encoding is canonical: decode then encode returns the same bytes.
        for b in &sim.blocks[20..] {
            assert_eq!(Section::decode(&b.section, &b.header.h0()).unwrap().encode(), b.section);
        }
    }

    #[test]
    fn header_faults_recorded_invalid() {
        let mut sim = simulate(40, 10, 2000, NBITS, 3);
        let last = sim.blocks.last().unwrap();
        let mut v = sim.val_before_last.clone();
        let mut bad = last.clone();
        bad.header.mm_rhs[0] ^= 1;
        assert_eq!(v.accept(&bad), Err(Reject::Commitment));
        assert_eq!(v.accept(&bad), Err(Reject::KnownInvalid));
        let mut bad = last.clone();
        bad.header.bits = 0x2007_ffff;
        assert_eq!(v.accept(&bad), Err(Reject::Bits));
        assert!(v.invalid.contains(&bad.header.id()));
        v.accept(last).unwrap();
        // Correct section for a nonce whose final misses the target.
        let miss = sim.miner.make(false);
        assert_eq!(sim.val.clone().accept(&miss), Err(Reject::Target));
        assert_eq!(sim.light.clone().accept(&miss.header, &miss.section), Err(Reject::Target));
        let hit = sim.miner.mine();
        sim.val.accept(&hit).unwrap();
        sim.light.accept(&hit.header, &hit.section).unwrap();
    }

    #[test]
    fn fabricated_trees_rejected_from_anchor() {
        let sim = simulate(40, 10, 2000, NBITS, 5);
        let tip = sim.blocks.last().unwrap().header.id();
        let fake = zero_tree(500);
        let (h, sec) = solve(tip, [1; 32], 40, &fake, 490, |_| [0; CHUNK], NBITS, true);
        assert_eq!(check_unanchored(&h, &sec, &Peaks::from_mmr(&fake)), Ok(()));
        assert_eq!(sim.light.clone().accept(&h, &sec), Err(Reject::Counts));

        let n = sim.miner.mmr.count;
        let fake = zero_tree(n);
        let (h, sec) = solve(tip, [2; 32], 40, &fake, sim.miner.s, |_| [0; CHUNK], NBITS, true);
        assert_eq!(check_unanchored(&h, &sec, &Peaks::from_mmr(&fake)), Ok(()));
        assert_eq!(sim.light.clone().accept(&h, &sec), Err(Reject::Commitment));
    }

    #[test]
    fn oversize_parent_rejected() {
        let sim = simulate(40, 10, 2000, NBITS, 9);
        let tip = sim.blocks.last().unwrap().header.id();
        let s = sim.miner.s;
        let mut over = Mmr::empty();
        for c in &sim.miner.chunks[..s as usize] {
            over.push(leaf(c));
        }
        for _ in 0..=sim.c_max {
            over.push(leaf(&[0; CHUNK]));
        }
        let chunks = &sim.miner.chunks;
        let (h, sec) = solve(tip, [3; 32], 40, &over, s, |a| if a < s { chunks[a as usize] } else { [0; CHUNK] }, NBITS, true);
        assert_eq!(sim.light.clone().accept(&h, &sec), Err(Reject::Oversize));
        let mut unbounded = sim.light.clone();
        unbounded.c_max = u64::MAX;
        assert_eq!(unbounded.accept(&h, &sec), Ok(()));
    }
}
