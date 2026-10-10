//! Strong data-dependent proof of work: a chain read on every hash attempt, not only on the
//! rare pre-filtered candidate the weak rule reads on. Every nonce reads k 64-byte chunks, and
//! each read's position is derived from the previous chunk's contents, so a miner learns whether
//! it holds an attempt's chunks only by performing the reads. From disk the effective rate falls
//! to the disk's random-read rate (a fast ASIC and a slow CPU then mine at the same rate, both
//! read-bound); from RAM it is hash-bound. A solution carries a Merkle mountain range proof of
//! its reads, checkable without the dataset.
//!
//! Per attempt on header `hdr` with nonce `n`, over N chunks whose last N - S are the parent's:
//!   x_0   = BLAKE2b-256(hdr || n_le)                  (h0)
//!   a_0   = S + idx(x_0, N - S)                        parent block
//!   x_i   = BLAKE2b-256(x_{i-1} || chunk(a_{i-1}))     i = 1..k-1
//!   a_i   = idx(x_i, N)                                whole chain
//!   final = BLAKE2b-256(x_{k-1} || chunk(a_{k-1}))
//!   idx(x, n) = u64le(x[0..8]) mod n
//!   solution if final has >= `bits` leading zero bits
//!
//! Usage:
//!   chain-dependent-pow bench [--gib 4] [--reads 8] [--threads N] [--seconds 10] [--lanes 1]
//!   chain-dependent-pow bench --disk <file> [--gib 16] [--reads 8] [--threads N] [--seconds 20]
//!     both: [--read-bytes 64] (bytes per read, hashed whole; a power of two, at most 4096 on
//!     disk) [--nohash 1] (fold each read instead of hashing it: the memory or disk limit)
//!   chain-dependent-pow partial [--gib 1] [--reads 8] [--threads N] [--seconds 3] [--layout random|prefix]
//!                                                  (partial holder: chained vs independent reads)
//!   chain-dependent-pow prove [--kib 256] [--reads 8]     (build an MMR, find a low-target
//!                                                   solution, prove and verify its reads)
//!   chain-dependent-pow chain [--blocks 3000] [--activation 1000] [--body-kib 64] [--nbits 1f400000]
//!                                                  (block proof sections: pruned validator and
//!                                                   light client from the anchor, attacks)

mod chain;
mod header;

use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

const CHUNK: usize = 64;
const PAGE: usize = 4096;
/// Chunks in the parent block: 4 MiB, a full block. Read 0 lands here; it is cached, not read
/// from storage.
const PARENT_CHUNKS: u64 = 65_536;

/** Which BLAKE2b implementation `blake2b` uses: 0 the `blake2` crate (portable code), 1
 *  `blake2b_simd` (AVX2 or SSE4.1, detected at run time). Set by `--hasher`. */
static HASHER: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

fn blake2b(parts: &[&[u8]]) -> [u8; 32] {
    if HASHER.load(Ordering::Relaxed) == 1 {
        let mut st = blake2b_simd::Params::new().hash_length(32).to_state();
        for p in parts {
            st.update(p);
        }
        return st.finalize().as_bytes().try_into().unwrap();
    }
    let mut h = Blake2b::<U32>::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/** BLAKE2b-256 of each input, several at once (`blake2b_simd::many`: four inputs per AVX2
 *  instruction stream). */
fn blake2b_many(inputs: &[Vec<u8>], out: &mut [[u8; 32]]) {
    let params = blake2b_simd::Params::new().hash_length(32).clone();
    let mut jobs: Vec<blake2b_simd::many::HashManyJob> = inputs.iter().map(|i| blake2b_simd::many::HashManyJob::new(&params, i)).collect();
    blake2b_simd::many::hash_many(jobs.iter_mut());
    for (o, j) in out.iter_mut().zip(jobs.iter()) {
        o.copy_from_slice(j.to_hash().as_bytes());
    }
}

mod b2x8;

/** Panics unless the implementations agree on inputs of the sizes the rule hashes. */
fn check_hashers() {
    let saved = HASHER.load(Ordering::Relaxed);
    for len in [80usize, 96, 128, 129, 288, 1056, 4128, 8224, 32800] {
        let input: Vec<u8> = (0..len).map(|i| (i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15).to_le_bytes()[i % 8]).collect();
        HASHER.store(0, Ordering::Relaxed);
        let a = blake2b(&[&input]);
        HASHER.store(1, Ordering::Relaxed);
        let b = blake2b(&[&input[..32], &input[32..]]);
        let mut c = [[0u8; 32]; 3];
        blake2b_many(&[input.clone(), input.clone(), input.clone()], &mut c);
        assert!(a == b && c.iter().all(|h| *h == a), "BLAKE2b implementations disagree at {len} bytes");
        if b2x8::available() {
            // As the rule hashes: a 32-byte prefix and a body, and a body alone; 8 lanes differ.
            let bodies: Vec<Vec<u8>> = (0..8).map(|l| input.iter().map(|&x| x ^ l as u8).collect()).collect();
            let prefixes: [[u8; 32]; 8] = std::array::from_fn(|l| std::array::from_fn(|k| (k * 7 + l) as u8));
            let mut got = [[0u8; 32]; 8];
            b2x8::hash8(Some(&prefixes), std::array::from_fn(|l| &bodies[l][..]), &mut got);
            for l in 0..8 {
                HASHER.store(0, Ordering::Relaxed);
                assert_eq!(got[l], blake2b(&[&prefixes[l], &bodies[l]]), "AVX-512 BLAKE2b disagrees at {len} bytes, lane {l}");
            }
            b2x8::hash8(None, std::array::from_fn(|l| &bodies[l][..]), &mut got);
            for l in 0..8 {
                assert_eq!(got[l], blake2b(&[&bodies[l]]), "AVX-512 BLAKE2b disagrees at {len} bytes, lane {l}, no prefix");
            }
        }
    }
    HASHER.store(saved, Ordering::Relaxed);
}

/// A read position over `n` chunks from the first 8-byte word of `x`.
fn idx(x: &[u8; 32], n: u64) -> u64 {
    u64::from_le_bytes(x[..8].try_into().unwrap()) % n
}

/// First chunk of the parent block in a dataset of `n` chunks.
fn parent_start(n: u64) -> u64 {
    n - PARENT_CHUNKS.min(n)
}

fn chunk_at(data: &[u8], a: u64) -> [u8; CHUNK] {
    let p = a as usize * CHUNK;
    data[p..p + CHUNK].try_into().unwrap()
}

/// One attempt's k chained reads; returns `final`. `read(a)` returns chunk `a`, or None if the
/// miner does not hold it, which ends the attempt with the reads before it already spent.
fn attempt(h0: &[u8; 32], k: usize, n: u64, s: u64, mut read: impl FnMut(u64) -> Option<[u8; CHUNK]>) -> Option<[u8; 32]> {
    let mut x = *h0;
    let mut a = s + idx(&x, n - s);
    for i in 0..k {
        let chunk = read(a)?;
        x = blake2b(&[&x, &chunk]);
        if i + 1 < k {
            a = idx(&x, n);
        }
    }
    Some(x)
}

/// The superseded rule's i-th position: every position from `h0` alone, so a miner knows all of
/// them before reading any (and reads i and i+4 share a word of `h0`). Kept for `partial`.
fn independent(h0: &[u8; 32], i: usize, n: u64, s: u64) -> u64 {
    let word = |i: usize, m: u64| {
        let at = 8 * (i % 4);
        u64::from_le_bytes(h0[at..at + 8].try_into().unwrap()).wrapping_add((i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)) % m
    };
    if i == 0 { s + word(0, n - s) } else { word(i, n) }
}

fn arg(name: &str, default: f64) -> f64 {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).and_then(|s| s.parse().ok()).unwrap_or(default)
}

fn arg_str(name: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).cloned()
}

fn threads_arg() -> usize {
    let n = arg("--threads", 0.0) as usize;
    if n > 0 { n } else { std::thread::available_parallelism().map_or(4, |x| x.get()) }
}

fn leading_zero_bits(h: &[u8; 32]) -> u32 {
    let mut n = 0;
    for &b in h {
        n += b.leading_zeros();
        if b != 0 {
            break;
        }
    }
    n
}

// Benchmarks: effective attempts/s when each attempt reads k chunks, versus a pure hash with
// no reads. The header is fixed; only the nonce moves.

struct Rate {
    attempts: u64,
    elapsed: f64,
}

fn spawn_loop(threads: usize, seconds: u64, body: impl Fn(u64, &AtomicU64, &AtomicBool) + Sync) -> Rate {
    let total = AtomicU64::new(0);
    let stop = AtomicBool::new(false);
    let start = Instant::now();
    std::thread::scope(|s| {
        for t in 0..threads {
            let (total, stop, body) = (&total, &stop, &body);
            s.spawn(move || body(t as u64, total, stop));
        }
        std::thread::sleep(Duration::from_secs(seconds));
        stop.store(true, Ordering::Relaxed);
    });
    Rate { attempts: total.load(Ordering::Relaxed), elapsed: start.elapsed().as_secs_f64() }
}

/// Pure BLAKE2b-256 of an 80-byte header, no reads: the hasher's ceiling.
fn pure_hash(threads: usize, seconds: u64) -> Rate {
    spawn_loop(threads, seconds, |t, total, stop| {
        let mut hdr = [0u8; 80];
        hdr[0] = t as u8;
        let mut n: u64 = 0;
        while !stop.load(Ordering::Relaxed) {
            for _ in 0..50_000 {
                hdr[8..16].copy_from_slice(&n.to_le_bytes());
                let h = blake2b(&[&hdr]);
                hdr[40] ^= h[0];
                n += 1;
            }
            total.fetch_add(50_000, Ordering::Relaxed);
        }
    })
}

/// Parent block bytes: 4 MiB, a full block. Read 0 lands here; it is cached, not read from
/// storage.
const PARENT_BYTES: u64 = 4 << 20;

/// One chained step over a read unit: x_i = BLAKE2b-256(x_{i-1} || unit). With `nohash`, a fold
/// of every word of the unit into x instead: the rate without hashing, so memory alone bounds it.
fn step(x: &[u8; 32], unit: &[u8], nohash: bool) -> [u8; 32] {
    if !nohash {
        return blake2b(&[x, unit]);
    }
    let mut acc = [0u64; 8];
    for (i, w) in unit.chunks_exact(8).enumerate() {
        acc[i % 8] ^= u64::from_le_bytes(w.try_into().unwrap());
    }
    let mut out = *x;
    let folded = acc.iter().fold(u64::from_le_bytes(x[..8].try_into().unwrap()), |a, &w| mix(a ^ w));
    out[..8].copy_from_slice(&folded.to_le_bytes());
    out
}

/// Prefetches the `size` bytes of unit `a`, one request per 64-byte line.
fn prefetch(data: &[u8], a: u64, size: usize) {
    #[cfg(target_arch = "x86_64")]
    for line in (0..size).step_by(64) {
        // SAFETY: the address is inside `data`; a prefetch does not fault.
        unsafe { std::arch::x86_64::_mm_prefetch(data.as_ptr().add(a as usize * size + line) as *const i8, std::arch::x86_64::_MM_HINT_T0) };
    }
}

/// Chained attempts over an in-RAM dataset of `size`-byte read units, `lanes` attempts
/// interleaved per thread: each lane's next unit is prefetched as soon as its position is known,
/// so up to `lanes` reads per thread are in flight while the other lanes hash. Hash-bound unless
/// memory binds.
fn ram_read(data: &[u8], size: usize, reads: usize, lanes: usize, nohash: bool, many: bool, avx512: bool, threads: usize, seconds: u64) -> Rate {
    let n = (data.len() / size) as u64;
    let s = n - (PARENT_BYTES / size as u64).min(n - 1);
    let unit = |a: u64| &data[a as usize * size..(a as usize + 1) * size];
    spawn_loop(threads, seconds, |t, total, stop| {
        let mut hdr = vec![[0u8; 80]; lanes];
        for (l, h) in hdr.iter_mut().enumerate() {
            h[0] = t as u8;
            h[1] = l as u8;
        }
        let mut x = vec![[0u8; 32]; lanes];
        let mut a = vec![0u64; lanes];
        let mut n_nonce: u64 = 0;
        let many = many && !nohash;
        let avx512 = avx512 && !nohash;
        // With `many`: each lane's x || unit, hashed for all lanes together.
        let mut bufs: Vec<Vec<u8>> = if many { (0..lanes).map(|_| vec![0u8; 32 + size]).collect() } else { Vec::new() };
        let mut hdr_bufs: Vec<Vec<u8>> = if many { vec![vec![0u8; 80]; lanes] } else { Vec::new() };
        while !stop.load(Ordering::Relaxed) {
            for _ in 0..256 {
                if many {
                    for l in 0..lanes {
                        hdr[l][8..16].copy_from_slice(&n_nonce.to_le_bytes());
                        hdr_bufs[l].copy_from_slice(&hdr[l]);
                    }
                    blake2b_many(&hdr_bufs, &mut x);
                }
                if avx512 {
                    for l in 0..lanes {
                        hdr[l][8..16].copy_from_slice(&n_nonce.to_le_bytes());
                    }
                    for g in 0..lanes / 8 {
                        let mut out = [[0u8; 32]; 8];
                        b2x8::hash8(None, std::array::from_fn(|k| &hdr[8 * g + k][..]), &mut out);
                        x[8 * g..8 * g + 8].copy_from_slice(&out);
                    }
                }
                for l in 0..lanes {
                    if !many && !avx512 {
                        hdr[l][8..16].copy_from_slice(&n_nonce.to_le_bytes());
                        x[l] = blake2b(&[&hdr[l]]);
                    }
                    a[l] = s + idx(&x[l], n - s);
                    prefetch(data, a[l], size);
                }
                for i in 0..reads {
                    if avx512 {
                        for g in 0..lanes / 8 {
                            let prefix: [[u8; 32]; 8] = std::array::from_fn(|k| x[8 * g + k]);
                            let mut out = [[0u8; 32]; 8];
                            b2x8::hash8(Some(&prefix), std::array::from_fn(|k| unit(a[8 * g + k])), &mut out);
                            x[8 * g..8 * g + 8].copy_from_slice(&out);
                        }
                    }
                    if many {
                        for l in 0..lanes {
                            bufs[l][..32].copy_from_slice(&x[l]);
                            bufs[l][32..].copy_from_slice(unit(a[l]));
                        }
                        blake2b_many(&bufs, &mut x);
                    }
                    for l in 0..lanes {
                        if !many && !avx512 {
                            x[l] = step(&x[l], unit(a[l]), nohash);
                        }
                        if i + 1 < reads {
                            a[l] = idx(&x[l], n);
                            prefetch(data, a[l], size);
                        }
                    }
                }
                for l in 0..lanes {
                    hdr[l][40] ^= x[l][0];
                }
                n_nonce += 1;
            }
            total.fetch_add(256 * lanes as u64, Ordering::Relaxed);
        }
    })
}

/// Chained attempts over `size`-byte read units: read 0 from the parent in RAM, reads 1..k-1
/// from a file with O_DIRECT (page cache bypassed). Units are packed into 4 KiB pages, so each
/// storage read is the one page holding the unit (`size` divides 4096): read-bound at the
/// drive's random-read rate, whatever the hasher's speed.
fn disk_read(path: &str, gib: f64, size: usize, reads: usize, nohash: bool, threads: usize, seconds: u64) -> Rate {
    assert!((size <= PAGE && PAGE % size == 0) || size % PAGE == 0, "--read-bytes must divide 4096 or be a multiple of it");
    // One direct read per chunk: the page holding it, or the chunk's pages for chunks of a page or more.
    let unit = size.max(PAGE);
    let bytes = (gib * (1u64 << 30) as f64) as u64 & !(PAGE as u64 - 1);
    ensure_file(path, bytes, threads);
    let n = bytes / size as u64;
    let s = n - (PARENT_BYTES / size as u64).min(n - 1);
    let mut parent = vec![0u8; (n - s) as usize * size];
    fill(&mut parent, threads);
    #[cfg(target_os = "linux")]
    const O_DIRECT: i32 = 0o40000;
    #[cfg(target_os = "macos")]
    const O_DIRECT: i32 = 0;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new().read(true).custom_flags(O_DIRECT).open(path).expect("open O_DIRECT");
    let parent = &parent;
    spawn_loop(threads, seconds, |t, total, stop| {
        let mut hdr = [0u8; 80];
        hdr[0] = t as u8;
        let mut n_nonce: u64 = 0;
        let mut page = AlignedPage::new(unit);
        while !stop.load(Ordering::Relaxed) {
            for _ in 0..64 {
                hdr[8..16].copy_from_slice(&n_nonce.to_le_bytes());
                let mut x = blake2b(&[&hdr]);
                let mut a = s + idx(&x, n - s);
                for i in 0..reads {
                    x = if a >= s {
                        let at = (a - s) as usize * size;
                        step(&x, &parent[at..at + size], nohash)
                    } else {
                        let off = a * size as u64;
                        let page_off = off & !(unit as u64 - 1);
                        file.read_exact_at(page.as_mut(), page_off).expect("direct read");
                        let at = (off - page_off) as usize;
                        step(&x, &page.as_mut()[at..at + size], nohash)
                    };
                    if i + 1 < reads {
                        a = idx(&x, n);
                    }
                }
                hdr[40] ^= x[0];
                n_nonce += 1;
            }
            total.fetch_add(64, Ordering::Relaxed);
        }
    })
}

/// A buffer of whole pages, page-aligned for O_DIRECT.
struct AlignedPage(*mut u8, usize);
impl AlignedPage {
    fn new(len: usize) -> Self {
        let layout = std::alloc::Layout::from_size_align(len, PAGE).unwrap();
        AlignedPage(unsafe { std::alloc::alloc(layout) }, len)
    }
    fn as_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.0, self.1) }
    }
}
unsafe impl Send for AlignedPage {}
impl Drop for AlignedPage {
    fn drop(&mut self) {
        let layout = std::alloc::Layout::from_size_align(self.1, PAGE).unwrap();
        unsafe { std::alloc::dealloc(self.0, layout) };
    }
}

fn ensure_file(path: &str, bytes: u64, threads: usize) {
    if std::fs::metadata(path).map(|m| m.len()).unwrap_or(0) >= bytes {
        return;
    }
    eprintln!("writing {:.1} GiB test file {path} (once)", bytes as f64 / (1u64 << 30) as f64);
    let file = std::fs::OpenOptions::new().create(true).write(true).open(path).expect("create");
    file.set_len(bytes).expect("set_len");
    let per = bytes.div_ceil(threads as u64);
    std::thread::scope(|s| {
        for t in 0..threads as u64 {
            let file = &file;
            s.spawn(move || {
                let start = t * per;
                let end = (start + per).min(bytes);
                let mut block = vec![0u8; 1 << 20];
                let mut seed = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(t + 1);
                let mut off = start;
                while off < end {
                    for w in block.chunks_exact_mut(8) {
                        seed ^= seed << 13;
                        seed ^= seed >> 7;
                        seed ^= seed << 17;
                        w.copy_from_slice(&seed.to_le_bytes());
                    }
                    let n = block.len().min((end - off) as usize);
                    file.write_all_at(&block[..n], off).expect("write");
                    off += n as u64;
                }
            });
        }
    });
}

fn fill(buf: &mut [u8], threads: usize) {
    let per = buf.len().div_ceil(threads);
    std::thread::scope(|s| {
        for (t, part) in buf.chunks_mut(per).enumerate() {
            s.spawn(move || {
                let mut seed = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(t as u64 + 1);
                for w in part.chunks_mut(8) {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    let b = seed.to_le_bytes();
                    w.copy_from_slice(&b[..w.len()]);
                }
            });
        }
    });
}

fn rate(r: &Rate) -> f64 {
    r.attempts as f64 / r.elapsed
}

fn bench() {
    let threads = threads_arg();
    let reads = arg("--reads", 8.0) as usize;
    let seconds = arg("--seconds", 10.0) as u64;
    let gib = arg("--gib", 4.0);
    let size = arg("--read-bytes", CHUNK as f64) as usize;
    let lanes = arg("--lanes", 1.0) as usize;
    let nohash = arg("--nohash", 0.0) != 0.0;
    assert!(size >= 64 && size.is_power_of_two(), "--read-bytes must be a power of two, at least 64");
    // --hasher blake2 (the `blake2` crate, default), simd (`blake2b_simd`), or many
    // (`blake2b_simd`, the lanes' inputs hashed together; RAM only).
    let hasher = arg_str("--hasher").unwrap_or_else(|| "blake2".into());
    assert!(["blake2", "simd", "many", "avx512"].contains(&hasher.as_str()), "--hasher must be blake2, simd, many or avx512");
    assert!(hasher != "avx512" || (b2x8::available() && lanes % 8 == 0), "--hasher avx512 needs AVX-512 and --lanes a multiple of 8");
    check_hashers();
    HASHER.store(if hasher == "blake2" { 0 } else { 1 }, Ordering::Relaxed);
    let many = hasher == "many";
    let mode = if nohash { "fold, no hashing".to_string() } else { format!("hashed, {hasher}") };

    let pure = pure_hash(threads, 3);
    println!("pure hash (no reads):   {:>12.3e} H/s   {:.1} MH/s  [{threads} threads]", rate(&pure), rate(&pure) / 1e6);

    if let Some(path) = arg_str("--disk") {
        let r = disk_read(&path, gib, size, reads, nohash, threads, seconds);
        let eff = rate(&r);
        println!(
            "disk (k={reads}, {size}-byte reads, {mode}): {:>12.3e} attempts/s   {:.3e} storage reads/s   {:.2} GB/s used   [O_DIRECT, {gib} GiB; read 0 from the parent in RAM]",
            eff,
            eff * (reads - 1) as f64,
            eff * (reads - 1) as f64 * size as f64 / 1e9
        );
    } else {
        let units = ((gib * (1u64 << 30) as f64) as usize / size).max(2);
        let mut data = vec![0u8; units * size];
        fill(&mut data, threads);
        let r = ram_read(&data, size, reads, lanes, nohash, many, hasher == "avx512", threads, seconds);
        let eff = rate(&r);
        println!(
            "RAM (k={reads}, {size}-byte reads, {mode}, {lanes} lanes): {:>12.3e} attempts/s   {:.3e} reads/s   {:.2} GB/s   [{gib} GiB resident]",
            eff,
            eff * reads as f64,
            eff * reads as f64 * size as f64 / 1e9
        );
    }
}

/// splitmix64 finalizer: a nonlinear mix, so the values for `a` and `a + D` are uncorrelated.
fn mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// A miner holding fraction `f` of the chunks (the parent plus, with `--layout random`, a
/// pseudo-random subset of the rest, or with `--layout prefix`, a prefix) that never reads a
/// chunk it lacks. Independent rule: all positions are known from h0, so it checks them
/// and reads only if every chunk is held. Chained rule: it learns each position only from the
/// previous chunk, so a missing chunk found at read i leaves reads 1..i-1 spent. Counts h0
/// hashes and storage reads (reads outside the parent) per completed attempt.
fn partial() {
    let threads = threads_arg();
    let reads = arg("--reads", 8.0) as usize;
    let seconds = arg("--seconds", 3.0) as u64;
    let gib = arg("--gib", 1.0);
    let n_chunks = ((gib * (1u64 << 30) as f64) as usize / CHUNK).max(PARENT_CHUNKS as usize * 2);
    let mut window = vec![0u8; n_chunks * CHUNK];
    fill(&mut window, threads);
    let window = &window;
    let n = n_chunks as u64;
    let s = parent_start(n);
    let full = (reads - 1) as f64;
    let prefix = arg_str("--layout").as_deref() == Some("prefix");

    println!(
        "dataset {n} chunks ({gib} GiB), parent {} chunks, k = {reads}, {} layout, {threads} threads, {seconds} s per row",
        n - s,
        if prefix { "prefix" } else { "random" }
    );
    println!("{:>7} {:>12} {:>10} {:>14} {:>16} {:>14}", "held", "rule", "completed", "h0/completed", "reads/completed", "vs full holder");
    for f in [1.0, 0.99, 0.9, 0.75, 0.5, 0.146] {
        // Held: the parent [s, n), and of [0, s) either the prefix [0, held) or each chunk with
        // probability g = held / s.
        let held = ((f * n as f64) as u64).saturating_sub(n - s).min(s);
        let g = held as f64 / s as f64;
        let thresh = if g >= 1.0 { u64::MAX } else { (g * 2f64.powi(64)) as u64 };
        let is_held = |a: u64| a >= s || if prefix { a < held } else { g >= 1.0 || mix(a) < thresh };
        for chained in [false, true] {
            let storage = AtomicU64::new(0);
            let completed = AtomicU64::new(0);
            let r = spawn_loop(threads, seconds, |t, total, stop| {
                let mut hdr = [0u8; 80];
                hdr[0] = t as u8;
                let mut nonce: u64 = 0;
                let (mut rd, mut done) = (0u64, 0u64);
                while !stop.load(Ordering::Relaxed) {
                    for _ in 0..20_000 {
                        hdr[8..16].copy_from_slice(&nonce.to_le_bytes());
                        nonce += 1;
                        let h0 = blake2b(&[&hdr]);
                        if chained {
                            let fin = attempt(&h0, reads, n, s, |a| {
                                if !is_held(a) {
                                    return None;
                                }
                                rd += (a < s) as u64;
                                Some(chunk_at(window, a))
                            });
                            done += std::hint::black_box(fin).is_some() as u64;
                        } else {
                            let pos: Vec<u64> = (0..reads).map(|i| independent(&h0, i, n, s)).collect();
                            if !pos.iter().all(|&a| is_held(a)) {
                                continue;
                            }
                            let mut buf = Vec::with_capacity(32 + reads * CHUNK);
                            buf.extend_from_slice(&h0);
                            for &a in &pos {
                                rd += (a < s) as u64;
                                buf.extend_from_slice(&chunk_at(window, a));
                            }
                            std::hint::black_box(blake2b(&[&buf]));
                            done += 1;
                        }
                    }
                    total.fetch_add(20_000, Ordering::Relaxed);
                }
                storage.fetch_add(rd, Ordering::Relaxed);
                completed.fetch_add(done, Ordering::Relaxed);
            });
            let done = completed.load(Ordering::Relaxed).max(1) as f64;
            let per = storage.load(Ordering::Relaxed) as f64 / done;
            println!(
                "{:>7.3} {:>12} {:>10} {:>14.3e} {:>16.1} {:>13.2}x",
                (held + n - s) as f64 / n as f64,
                if chained { "chained" } else { "independent" },
                completed.load(Ordering::Relaxed),
                r.attempts as f64 / done,
                per,
                per / full
            );
        }
    }
}

// Merkle mountain range over the dataset chunks, and a proof of one attempt's reads.

fn leaf(chunk: &[u8]) -> [u8; 32] {
    blake2b(&[&[0x00], chunk])
}
fn node(l: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    blake2b(&[&[0x01], l, r])
}

/// Full MMR (every level kept) over `n` leaves, for the small `prove` demo.
struct Mmr {
    levels: Vec<Vec<[u8; 32]>>,
    count: u64,
}
impl Mmr {
    fn build(chunks: &[[u8; CHUNK]]) -> Self {
        let mut levels: Vec<Vec<[u8; 32]>> = vec![chunks.iter().map(|c| leaf(c)).collect()];
        while levels.last().unwrap().len() > 1 {
            let lo = levels.last().unwrap();
            let mut up = Vec::with_capacity(lo.len() / 2);
            let mut i = 0;
            while i + 1 < lo.len() {
                up.push(node(&lo[i], &lo[i + 1]));
                i += 2;
            }
            levels.push(up);
        }
        Mmr { levels, count: chunks.len() as u64 }
    }
    fn peaks(&self) -> Vec<[u8; 32]> {
        let mut peaks = Vec::new();
        for l in (0..64).rev() {
            if (self.count >> l) & 1 == 1 {
                peaks.push(self.levels[l][(self.count >> l) as usize - 1]);
            }
        }
        peaks
    }
    fn path(&self, pos: u64) -> Vec<[u8; 32]> {
        let (level, _) = peak_for(self.count, pos);
        (0..level).map(|l| self.levels[l][((pos >> l) ^ 1) as usize]).collect()
    }
}

/// The peak (level, index in the high-to-low peaks list) covering `pos`.
fn peak_for(count: u64, pos: u64) -> (usize, usize) {
    let mut cum = 0u64;
    let mut idx = 0;
    for l in (0..64).rev() {
        if (count >> l) & 1 == 0 {
            continue;
        }
        let span = 1u64 << l;
        if pos >= cum && pos < cum + span {
            return (l, idx);
        }
        cum += span;
        idx += 1;
    }
    panic!("position out of range")
}

fn fold(mut acc: [u8; 32], pos: u64, path: &[[u8; 32]]) -> [u8; 32] {
    for (l, sib) in path.iter().enumerate() {
        acc = if (pos >> l) & 1 == 1 { node(sib, &acc) } else { node(&acc, sib) };
    }
    acc
}

fn bag(peaks: &[[u8; 32]]) -> [u8; 32] {
    let mut acc = *peaks.last().unwrap();
    for p in peaks.iter().rev().skip(1) {
        acc = node(p, &acc);
    }
    acc
}

/// BLAKE2b-256(0x02 || N u64le || S u64le || bag(peaks)).
fn commit(n: u64, s: u64, peaks: &[[u8; 32]]) -> [u8; 32] {
    blake2b(&[&[0x02], &n.to_le_bytes(), &s.to_le_bytes(), &bag(peaks)])
}

/// Find a solution and prove its reads verify against the committed peaks, no dataset needed.
fn prove() {
    let kib = arg("--kib", 256.0);
    let reads = arg("--reads", 8.0) as usize;
    let bits = arg("--bits", 16.0) as u32;
    let n_chunks = ((kib * 1024.0) as usize / CHUNK).max(reads + 1);
    let mut chunks = vec![[0u8; CHUNK]; n_chunks];
    let mut flat = vec![0u8; n_chunks * CHUNK];
    fill(&mut flat, 8);
    for (i, c) in chunks.iter_mut().enumerate() {
        c.copy_from_slice(&flat[i * CHUNK..(i + 1) * CHUNK]);
    }
    let mmr = Mmr::build(&chunks);
    let peaks = mmr.peaks();
    let n = n_chunks as u64;
    // The demo's parent is its last sixteenth.
    let s = n - (n / 16).max(1);
    let commitment = commit(n, s, &peaks);

    println!("dataset: {n_chunks} chunks ({:.0} KiB), parent from {s}, {} peaks, commitment {}", kib, peaks.len(), hex(&commitment[..6]));

    let mut hdr = [0u8; 80];
    let started = Instant::now();
    let (nonce, h0, fin, pos) = {
        let mut nonce = 0u64;
        loop {
            hdr[8..16].copy_from_slice(&nonce.to_le_bytes());
            let h0 = blake2b(&[&hdr]);
            let mut pos = Vec::with_capacity(reads);
            let fin = attempt(&h0, reads, n, s, |a| {
                pos.push(a);
                Some(chunks[a as usize])
            })
            .unwrap();
            if leading_zero_bits(&fin) >= bits {
                break (nonce, h0, fin, pos);
            }
            nonce += 1;
        }
    };
    println!(
        "solution: nonce {nonce} in {:.2e} attempts ({:.2}s), final {} ({} leading zero bits)",
        nonce as f64 + 1.0,
        started.elapsed().as_secs_f64(),
        hex(&fin[..6]),
        leading_zero_bits(&fin)
    );

    // Proof: per read the chunk and its path. A verifier holds only the commitment.
    let proof: Vec<(u64, [u8; CHUNK], Vec<[u8; 32]>)> = pos.iter().map(|&p| (p, chunks[p as usize], mmr.path(p))).collect();

    // Verify without the dataset: recompute each position from the previous chunk.
    let mut x = h0;
    let mut expect = s + idx(&x, n - s);
    let mut ok = true;
    for (p, chunk, path) in &proof {
        if *p != expect {
            ok = false;
        }
        let (_, peak_idx) = peak_for(n, *p);
        if fold(leaf(chunk), *p, path) != peaks[peak_idx] {
            ok = false;
        }
        x = blake2b(&[&x, chunk]);
        expect = idx(&x, n);
    }
    let bytes: usize = proof.iter().map(|(_, _, path)| CHUNK + path.len() * 32).sum::<usize>() + peaks.len() * 32;
    let commit_ok = commit(n, s, &peaks) == commitment;
    println!(
        "verify (no dataset): commitment {}, final {}, proof {} bytes -> {}",
        if commit_ok { "ok" } else { "BAD" },
        if x == fin { "ok" } else { "BAD" },
        bytes,
        if ok && commit_ok && x == fin { "VALID" } else { "INVALID" }
    );
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("bench") => bench(),
        Some("partial") => partial(),
        Some("prove") => prove(),
        Some("chain") => chain::run(),
        _ => {
            eprintln!("usage: chain-dependent-pow bench [--gib G] [--reads k] [--disk FILE] [--threads N] [--seconds S] [--read-bytes B] [--lanes L] [--nohash 1]");
            eprintln!("       chain-dependent-pow partial [--gib G] [--reads k] [--threads N] [--seconds S] [--layout random|prefix]");
            eprintln!("       chain-dependent-pow prove [--kib K] [--reads k] [--bits B]");
            eprintln!("       chain-dependent-pow chain [--blocks B] [--activation A] [--body-kib K] [--nbits HEX]");
        }
    }
}
