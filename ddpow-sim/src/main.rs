//! Measures the data stage of the data-dependent proof of work in
//! research/data-dependent-pow.md: for each pre-filtered candidate `c`, `k` pseudo-random
//! 64-byte reads from a window of chain bytes and one final BLAKE2b-256 over `c || chunks`.
//!
//! The window here is pseudo-random bytes: the access pattern, not the content, sets the cost.
//! Reported per configuration: candidates and reads per second, the byte rate a remote data
//! service would have to deliver, and the hashrate one such data stage supports at several
//! pre-filter depths (hashrate = candidates/s x 2^p).
//!
//!   ddpow-sim [--gib 4] [--threads 24] [--k 4] [--seconds 10] [--mib 0]
//!
//! --mib runs a cache-resident window of that size instead of --gib, for comparison.
//! --nohash 1 replaces both hashes with a cheap mix, so the reads alone bound the rate: the
//! ceiling a data stage whose hashing is not the bottleneck could reach from this memory.
//!
//!   ddpow-sim --disk <file> [--gib 16] [--threads 64] [--seconds 20]
//!
//! --disk measures random reads from a file on disk instead of memory: the file is written
//! with pseudo-random bytes (once, if missing or short), then each thread reads random 4 KiB
//! pages with O_DIRECT, bypassing the page cache, so the drive serves every read. This is the
//! rate an archival node's own disk serves the chain reads at, one 64-byte chunk per page.

use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

type Blake2b256 = Blake2b<U32>;

const CHUNK: usize = 64;

fn arg(name: &str, default: u64) -> u64 {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Fills `buf` with pseudo-random bytes in parallel (xorshift64*), so no page is zero or
/// shared and every read reaches memory the way real block bytes would.
fn fill(buf: &mut [u8], threads: usize) {
    let per = buf.len().div_ceil(threads);
    std::thread::scope(|s| {
        for (i, part) in buf.chunks_mut(per).enumerate() {
            s.spawn(move || {
                let mut x: u64 = 0x9E37_79B9_7F4A_7C15 ^ (i as u64 + 1);
                for word in part.chunks_mut(8) {
                    x ^= x >> 12;
                    x ^= x << 25;
                    x ^= x >> 27;
                    let v = x.wrapping_mul(0x2545_F491_4F6C_DD1D).to_le_bytes();
                    word.copy_from_slice(&v[..word.len()]);
                }
            });
        }
    });
}

struct Result {
    candidates: u64,
    reads: u64,
    elapsed: Duration,
}

fn run(window: &[u8], threads: usize, k: usize, seconds: u64, nohash: bool) -> Result {
    let n_chunks = (window.len() / CHUNK) as u64;
    let stop = Arc::new(AtomicBool::new(false));
    let total = Arc::new(AtomicU64::new(0));
    let sink = Arc::new(AtomicU64::new(0));
    let started = Instant::now();
    std::thread::scope(|s| {
        for t in 0..threads {
            let stop = Arc::clone(&stop);
            let total = Arc::clone(&total);
            let sink = Arc::clone(&sink);
            s.spawn(move || {
                let mut counter: u64 = 0;
                let mut local: u64 = 0;
                let mut acc: u64 = 0;
                let mut chunks = vec![0u8; k * CHUNK];
                while !stop.load(Ordering::Relaxed) {
                    for _ in 0..256 {
                        // Stage 3 output: the pre-filtered candidate. Without hashing, a
                        // cheap mix stands in for it so the reads alone bound the loop.
                        let c: [u8; 32] = if nohash {
                            let mut x = (t as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ counter.wrapping_mul(0xD6E8_FEB8_6659_FD93);
                            let mut out = [0u8; 32];
                            for w in out.chunks_mut(8) {
                                x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
                                w.copy_from_slice(&x.wrapping_mul(0x2545_F491_4F6C_DD1D).to_le_bytes());
                            }
                            out
                        } else {
                            let mut h = Blake2b256::new();
                            h.update((t as u64).to_le_bytes());
                            h.update(counter.to_le_bytes());
                            h.finalize().into()
                        };
                        counter += 1;
                        // Stage 4: k reads at positions the candidate selects.
                        for i in 0..k {
                            let word = u64::from_le_bytes(c[(i * 8) % 32..(i * 8) % 32 + 8].try_into().unwrap())
                                .wrapping_add(i as u64 * 0x9E37_79B9_7F4A_7C15);
                            let a = (word % n_chunks) as usize * CHUNK;
                            chunks[i * CHUNK..(i + 1) * CHUNK].copy_from_slice(&window[a..a + CHUNK]);
                        }
                        if nohash {
                            for w in chunks.chunks(8) {
                                acc ^= u64::from_le_bytes(w.try_into().unwrap());
                            }
                        } else {
                            let mut f = Blake2b256::new();
                            f.update(c);
                            f.update(&chunks);
                            let fin = f.finalize();
                            acc ^= u64::from_le_bytes(fin[..8].try_into().unwrap());
                        }
                        local += 1;
                    }
                }
                total.fetch_add(local, Ordering::Relaxed);
                sink.fetch_xor(acc, Ordering::Relaxed);
            });
        }
        std::thread::sleep(Duration::from_secs(seconds));
        stop.store(true, Ordering::Relaxed);
    });
    let elapsed = started.elapsed();
    let candidates = total.load(Ordering::Relaxed);
    let _ = sink.load(Ordering::Relaxed);
    Result { candidates, reads: candidates * k as u64, elapsed }
}

fn report(label: &str, r: &Result, k: usize) {
    let secs = r.elapsed.as_secs_f64();
    let cps = r.candidates as f64 / secs;
    let rps = r.reads as f64 / secs;
    println!("{label}");
    println!("  threads x k reads: k = {k}");
    println!("  candidates/s: {:.3e}   reads/s: {:.3e}   data rate: {:.2} GB/s", cps, rps, rps * CHUNK as f64 / 1e9);
    for p in [8u32, 12, 16, 20, 24] {
        let h = cps * 2f64.powi(p as i32);
        let unit = if h >= 1e15 { ("PH/s", 1e15) } else if h >= 1e12 { ("TH/s", 1e12) } else { ("GH/s", 1e9) };
        println!("  p = {p:>2}: one data stage supports {:.2} {}", h / unit.1, unit.0);
    }
}

fn arg_str(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

#[cfg(target_arch = "x86_64")]
const O_DIRECT: i32 = 0o40000;
#[cfg(target_arch = "aarch64")]
const O_DIRECT: i32 = 0o200000;

const PAGE: usize = 4096;

/// Random 4 KiB O_DIRECT reads from `path` (`gib` GiB), by `threads` threads for `seconds`.
fn disk(path: &str, gib: u64, threads: usize, seconds: u64) {
    use std::io::Write;
    use std::os::unix::fs::{FileExt, OpenOptionsExt};
    let bytes = gib * (1 << 30);
    if std::fs::metadata(path).map_or(true, |m| m.len() < bytes) {
        let t = Instant::now();
        let mut f = std::fs::File::create(path).expect("create the test file");
        let mut block = vec![0u8; 64 << 20];
        for i in 0..bytes / block.len() as u64 {
            fill(&mut block, threads.min(16));
            block[..8].copy_from_slice(&i.to_le_bytes());
            f.write_all(&block).expect("write the test file");
        }
        f.sync_all().expect("sync the test file");
        println!("wrote {gib} GiB in {:.1} s", t.elapsed().as_secs_f64());
    }
    let file = std::fs::OpenOptions::new().read(true).custom_flags(O_DIRECT).open(path).expect("open with O_DIRECT");
    let pages = bytes / PAGE as u64;
    let stop = AtomicBool::new(false);
    let total = AtomicU64::new(0);
    let started = Instant::now();
    std::thread::scope(|s| {
        for t in 0..threads {
            let (file, stop, total) = (&file, &stop, &total);
            s.spawn(move || {
                let layout = std::alloc::Layout::from_size_align(PAGE, PAGE).expect("layout");
                // SAFETY: a PAGE-sized, PAGE-aligned allocation, freed below.
                let ptr = unsafe { std::alloc::alloc(layout) };
                let buf = unsafe { std::slice::from_raw_parts_mut(ptr, PAGE) };
                let mut x: u64 = 0x9E37_79B9_7F4A_7C15 ^ (t as u64 + 1);
                let mut local = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    x ^= x >> 12;
                    x ^= x << 25;
                    x ^= x >> 27;
                    let page = x.wrapping_mul(0x2545_F491_4F6C_DD1D) % pages;
                    file.read_exact_at(buf, page * PAGE as u64).expect("direct read");
                    local += 1;
                }
                unsafe { std::alloc::dealloc(ptr, layout) };
                total.fetch_add(local, Ordering::Relaxed);
            });
        }
        std::thread::sleep(Duration::from_secs(seconds));
        stop.store(true, Ordering::Relaxed);
    });
    let rps = total.load(Ordering::Relaxed) as f64 / started.elapsed().as_secs_f64();
    println!("disk {path}: {gib} GiB, {threads} threads, {seconds} s, 4 KiB O_DIRECT random reads");
    println!("  reads/s: {rps:.3e}   ({:.2} GB/s of pages)", rps * PAGE as f64 / 1e9);
    // With eight reads per candidate, the first lands in the parent block (in memory), so
    // seven reach the disk.
    for p in [24u32, 28, 32, 36] {
        let h = rps / 7.0 * 2f64.powi(p as i32);
        let unit = if h >= 1e15 { ("PH/s", 1e15) } else if h >= 1e12 { ("TH/s", 1e12) } else { ("GH/s", 1e9) };
        println!("  p = {p:>2}: this disk serves {:.2} {}", h / unit.1, unit.0);
    }
}

fn main() {
    if let Some(path) = arg_str("--disk") {
        let threads = arg("--threads", 64) as usize;
        disk(&path, arg("--gib", 16), threads, arg("--seconds", 20));
        return;
    }
    let gib = arg("--gib", 4);
    let mib = arg("--mib", 0);
    let threads = arg("--threads", std::thread::available_parallelism().map_or(8, |n| n.get() as u64)) as usize;
    let k = arg("--k", 4) as usize;
    let seconds = arg("--seconds", 10);
    let nohash = arg("--nohash", 0) != 0;
    let bytes = if mib > 0 { mib as usize * 1024 * 1024 } else { gib as usize * 1024 * 1024 * 1024 };
    println!("window {:.2} GiB, {threads} threads, k = {k}, {seconds} s", bytes as f64 / (1u64 << 30) as f64);
    let t = Instant::now();
    let mut window = vec![0u8; bytes];
    fill(&mut window, threads);
    println!("filled in {:.1} s", t.elapsed().as_secs_f64());
    let r = run(&window, threads, k, seconds, nohash);
    report(&format!("window of {:.2} GiB{}", bytes as f64 / (1u64 << 30) as f64, if nohash { ", reads only (no hashing)" } else { "" }), &r, k);
    if !nohash {
        let r0 = run(&window, threads, 0, seconds.min(5), false);
        report("compute only (k = 0): the hashing without the reads", &r0, 0);
    }
}
