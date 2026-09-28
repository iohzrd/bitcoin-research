//! Strong data-dependent proof of work: a chain read on every hash attempt, not only on the
//! rare pre-filtered candidate the weak rule reads on. Every nonce reads k 64-byte chunks at
//! positions its own hash selects, so the read rate, not the hash rate, bounds mining. From
//! disk the effective rate collapses to the disk's random-read rate (a fast ASIC and a slow
//! CPU then mine at the same rate, both read-bound); from RAM it is hash-bound. Either way the
//! miner must hold the chunks. A solution carries a Merkle mountain range proof of its reads,
//! checkable without the dataset.
//!
//! Per attempt on header `hdr` with nonce `n`:
//!   h0    = BLAKE2b-256(hdr || n_le)
//!   a_i   = word_i(h0) mod N            i = 0..k-1     (positions over N chunks)
//!   final = BLAKE2b-256(h0 || chunk(a_0) || ... || chunk(a_{k-1}))
//!   solution if final has >= `bits` leading zero bits
//!
//! Usage:
//!   ddpow-strong bench [--gib 4] [--reads 1] [--threads N] [--seconds 10]
//!   ddpow-strong bench --disk <file> [--gib 16] [--reads 1] [--threads N] [--seconds 20]
//!   ddpow-strong prove [--kib 256] [--reads 8]     (build an MMR, find a low-target
//!                                                   solution, prove and verify its reads)

use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

const CHUNK: usize = 64;
const PAGE: usize = 4096;

fn blake2b(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Blake2b::<U32>::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// The i-th read position over `n` chunks, from the i-th 8-byte word of `h0` plus a per-read
/// offset (the weak rule's ChunkIndex, so positions spread and reuse the digest past 4 reads).
fn position(h0: &[u8; 32], i: usize, n: u64) -> u64 {
    let at = 8 * (i % 4);
    let word = u64::from_le_bytes(h0[at..at + 8].try_into().unwrap());
    word.wrapping_add((i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)) % n
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

/// Read k chunks per attempt from an in-RAM dataset: hash-bound unless RAM bandwidth binds.
fn ram_read(window: &[u8], reads: usize, threads: usize, seconds: u64) -> Rate {
    let n = (window.len() / CHUNK) as u64;
    spawn_loop(threads, seconds, |t, total, stop| {
        let mut hdr = [0u8; 80];
        hdr[0] = t as u8;
        let mut n_nonce: u64 = 0;
        let mut buf = vec![0u8; 32 + reads * CHUNK];
        while !stop.load(Ordering::Relaxed) {
            for _ in 0..20_000 {
                hdr[8..16].copy_from_slice(&n_nonce.to_le_bytes());
                let h0 = blake2b(&[&hdr]);
                buf[..32].copy_from_slice(&h0);
                for i in 0..reads {
                    let p = position(&h0, i, n) as usize * CHUNK;
                    buf[32 + i * CHUNK..32 + (i + 1) * CHUNK].copy_from_slice(&window[p..p + CHUNK]);
                }
                let f = blake2b(&[&buf]);
                hdr[40] ^= f[0];
                n_nonce += 1;
            }
            total.fetch_add(20_000, Ordering::Relaxed);
        }
    })
}

/// Read k chunks per attempt from a file with O_DIRECT (one 4 KiB page per chunk, page cache
/// bypassed): read-bound at the drive's random-read rate, whatever the hasher's speed.
fn disk_read(path: &str, gib: f64, reads: usize, threads: usize, seconds: u64) -> Rate {
    let bytes = (gib * (1u64 << 30) as f64) as u64 & !(PAGE as u64 - 1);
    ensure_file(path, bytes, threads);
    let pages = bytes / PAGE as u64;
    #[cfg(target_os = "linux")]
    const O_DIRECT: i32 = 0o40000;
    #[cfg(target_os = "macos")]
    const O_DIRECT: i32 = 0;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new().read(true).custom_flags(O_DIRECT).open(path).expect("open O_DIRECT");
    spawn_loop(threads, seconds, |t, total, stop| {
        let mut hdr = [0u8; 80];
        hdr[0] = t as u8;
        let mut n_nonce: u64 = 0;
        let mut page = AlignedPage::new();
        let mut buf = vec![0u8; 32 + reads * CHUNK];
        while !stop.load(Ordering::Relaxed) {
            for _ in 0..256 {
                hdr[8..16].copy_from_slice(&n_nonce.to_le_bytes());
                let h0 = blake2b(&[&hdr]);
                buf[..32].copy_from_slice(&h0);
                for i in 0..reads {
                    let pg = position(&h0, i, pages);
                    file.read_exact_at(page.as_mut(), pg * PAGE as u64).expect("direct read");
                    buf[32 + i * CHUNK..32 + (i + 1) * CHUNK].copy_from_slice(&page.as_mut()[..CHUNK]);
                }
                let f = blake2b(&[&buf]);
                hdr[40] ^= f[0];
                n_nonce += 1;
            }
            total.fetch_add(256, Ordering::Relaxed);
        }
    })
}

/// A 4 KiB page aligned for O_DIRECT.
struct AlignedPage(*mut u8);
impl AlignedPage {
    fn new() -> Self {
        let layout = std::alloc::Layout::from_size_align(PAGE, PAGE).unwrap();
        AlignedPage(unsafe { std::alloc::alloc(layout) })
    }
    fn as_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.0, PAGE) }
    }
}
unsafe impl Send for AlignedPage {}
impl Drop for AlignedPage {
    fn drop(&mut self) {
        let layout = std::alloc::Layout::from_size_align(PAGE, PAGE).unwrap();
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
    let reads = arg("--reads", 1.0) as usize;
    let seconds = arg("--seconds", 10.0) as u64;
    let gib = arg("--gib", 4.0);

    let pure = pure_hash(threads, 3);
    println!("pure hash (no reads):   {:>12.3e} H/s   {:.1} MH/s  [{threads} threads]", rate(&pure), rate(&pure) / 1e6);

    if let Some(path) = arg_str("--disk") {
        let r = disk_read(&path, gib, reads, threads, seconds);
        let eff = rate(&r);
        println!("disk read/hash (k={reads}): {:>12.3e} H/s   {:.3e} reads/s   [O_DIRECT, {gib} GiB]", eff, eff * reads as f64);
        println!("  effective mining rate is read-bound: a hasher {:.0}x faster mines at the same rate.", rate(&pure) / eff);
    } else {
        let n_chunks = ((gib * (1u64 << 30) as f64) as usize / CHUNK).max(1);
        let mut window = vec![0u8; n_chunks * CHUNK];
        fill(&mut window, threads);
        let r = ram_read(&window, reads, threads, seconds);
        let eff = rate(&r);
        println!("RAM read/hash (k={reads}):  {:>12.3e} H/s   {:.3e} reads/s   [{gib} GiB resident]", eff, eff * reads as f64);
        println!("  effective mining rate is hash-bound ({:.0}% of pure); RAM feeds reads faster than the CPU hashes.", 100.0 * eff / rate(&pure));
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
    let commitment = blake2b(&[&(n_chunks as u64).to_le_bytes(), &bag(&peaks)]);
    let n = n_chunks as u64;

    println!("dataset: {n_chunks} chunks ({:.0} KiB), {} peaks, commitment {}", kib, peaks.len(), hex(&commitment[..6]));

    let mut hdr = [0u8; 80];
    let started = Instant::now();
    let (nonce, h0, fin) = {
        let mut nonce = 0u64;
        loop {
            hdr[8..16].copy_from_slice(&nonce.to_le_bytes());
            let h0 = blake2b(&[&hdr]);
            let mut buf = Vec::with_capacity(32 + reads * CHUNK);
            buf.extend_from_slice(&h0);
            for i in 0..reads {
                buf.extend_from_slice(&chunks[position(&h0, i, n) as usize]);
            }
            let fin = blake2b(&[&buf]);
            if leading_zero_bits(&fin) >= bits {
                break (nonce, h0, fin);
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
    let proof: Vec<(u64, [u8; CHUNK], Vec<[u8; 32]>)> =
        (0..reads).map(|i| { let p = position(&h0, i, n); (p, chunks[p as usize], mmr.path(p)) }).collect();

    // Verify without the dataset.
    let mut buf = Vec::with_capacity(32 + reads * CHUNK);
    buf.extend_from_slice(&h0);
    let mut ok = true;
    for (i, (p, chunk, path)) in proof.iter().enumerate() {
        if *p != position(&h0, i, n) {
            ok = false;
        }
        let (_, peak_idx) = peak_for(n, *p);
        if fold(leaf(chunk), *p, path) != peaks[peak_idx] {
            ok = false;
        }
        buf.extend_from_slice(chunk);
    }
    let recomputed = blake2b(&[&buf]);
    let bytes: usize = proof.iter().map(|(_, _, path)| CHUNK + path.len() * 32).sum::<usize>() + peaks.len() * 32;
    println!(
        "verify (no dataset): commitment {}, final {}, proof {} bytes -> {}",
        if blake2b(&[&n.to_le_bytes(), &bag(&peaks)]) == commitment { "ok" } else { "BAD" },
        if recomputed == fin { "ok" } else { "BAD" },
        bytes,
        if ok && recomputed == fin { "VALID" } else { "INVALID" }
    );
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("bench") => bench(),
        Some("prove") => prove(),
        _ => {
            eprintln!("usage: ddpow-strong bench [--gib G] [--reads k] [--disk FILE] [--threads N] [--seconds S]");
            eprintln!("       ddpow-strong prove [--kib K] [--reads k] [--bits B]");
        }
    }
}
