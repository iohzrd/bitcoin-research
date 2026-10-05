//! BLAKE2b-256 of 8 inputs at once with AVX-512 (x86_64): each 512-bit register holds one
//! 64-bit state or message word of all 8 inputs, and rotations use `vprorq`. An input is an
//! optional 32-byte prefix followed by a body; the 8 bodies have one length, so the 8 inputs
//! have the same blocks. Bodies are read in place (no copy) except for a block that holds the
//! prefix or the zero padding.

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

const IV: [u64; 8] = [
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
];

const SIGMA: [[usize; 16]; 10] = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];

/// Whether this CPU can run `hash8`.
pub fn available() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        is_x86_feature_detected!("avx512f")
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        false
    }
}

/// BLAKE2b-256 of `prefix[i] || bodies[i]` for i in 0..8 (no prefix if `prefix` is None).
/// Every body has the same length. Panics unless `available()`.
pub fn hash8(prefix: Option<&[[u8; 32]; 8]>, bodies: [&[u8]; 8], out: &mut [[u8; 32]; 8]) {
    assert!(available(), "AVX-512 not available");
    let len = bodies[0].len();
    assert!(bodies.iter().all(|b| b.len() == len), "bodies differ in length");
    #[cfg(target_arch = "x86_64")]
    // SAFETY: avx512f was detected above.
    unsafe {
        hash8_avx512(prefix, bodies, out)
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f")]
unsafe fn transpose8(r: [__m512i; 8]) -> [__m512i; 8] {
    // Rows: 8 words of one input. Columns: word j of all 8 inputs.
    let t0 = _mm512_unpacklo_epi64(r[0], r[1]);
    let t1 = _mm512_unpackhi_epi64(r[0], r[1]);
    let t2 = _mm512_unpacklo_epi64(r[2], r[3]);
    let t3 = _mm512_unpackhi_epi64(r[2], r[3]);
    let t4 = _mm512_unpacklo_epi64(r[4], r[5]);
    let t5 = _mm512_unpackhi_epi64(r[4], r[5]);
    let t6 = _mm512_unpacklo_epi64(r[6], r[7]);
    let t7 = _mm512_unpackhi_epi64(r[6], r[7]);
    let u0 = _mm512_shuffle_i64x2::<0x88>(t0, t2);
    let u1 = _mm512_shuffle_i64x2::<0xDD>(t0, t2);
    let u2 = _mm512_shuffle_i64x2::<0x88>(t4, t6);
    let u3 = _mm512_shuffle_i64x2::<0xDD>(t4, t6);
    let v0 = _mm512_shuffle_i64x2::<0x88>(t1, t3);
    let v1 = _mm512_shuffle_i64x2::<0xDD>(t1, t3);
    let v2 = _mm512_shuffle_i64x2::<0x88>(t5, t7);
    let v3 = _mm512_shuffle_i64x2::<0xDD>(t5, t7);
    [
        _mm512_shuffle_i64x2::<0x88>(u0, u2),
        _mm512_shuffle_i64x2::<0x88>(v0, v2),
        _mm512_shuffle_i64x2::<0x88>(u1, u3),
        _mm512_shuffle_i64x2::<0x88>(v1, v3),
        _mm512_shuffle_i64x2::<0xDD>(u0, u2),
        _mm512_shuffle_i64x2::<0xDD>(v0, v2),
        _mm512_shuffle_i64x2::<0xDD>(u1, u3),
        _mm512_shuffle_i64x2::<0xDD>(v1, v3),
    ]
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f")]
unsafe fn compress(h: &mut [__m512i; 8], m: &[__m512i; 16], t: u64, last: bool) {
    let mut v = [_mm512_setzero_si512(); 16];
    for i in 0..8 {
        v[i] = h[i];
        v[i + 8] = _mm512_set1_epi64(IV[i] as i64);
    }
    v[12] = _mm512_xor_si512(v[12], _mm512_set1_epi64(t as i64));
    if last {
        v[14] = _mm512_xor_si512(v[14], _mm512_set1_epi64(-1));
    }
    macro_rules! g {
        ($a:expr, $b:expr, $c:expr, $d:expr, $x:expr, $y:expr) => {
            v[$a] = _mm512_add_epi64(_mm512_add_epi64(v[$a], v[$b]), $x);
            v[$d] = _mm512_ror_epi64::<32>(_mm512_xor_si512(v[$d], v[$a]));
            v[$c] = _mm512_add_epi64(v[$c], v[$d]);
            v[$b] = _mm512_ror_epi64::<24>(_mm512_xor_si512(v[$b], v[$c]));
            v[$a] = _mm512_add_epi64(_mm512_add_epi64(v[$a], v[$b]), $y);
            v[$d] = _mm512_ror_epi64::<16>(_mm512_xor_si512(v[$d], v[$a]));
            v[$c] = _mm512_add_epi64(v[$c], v[$d]);
            v[$b] = _mm512_ror_epi64::<63>(_mm512_xor_si512(v[$b], v[$c]));
        };
    }
    for r in 0..12 {
        let s = &SIGMA[r % 10];
        g!(0, 4, 8, 12, m[s[0]], m[s[1]]);
        g!(1, 5, 9, 13, m[s[2]], m[s[3]]);
        g!(2, 6, 10, 14, m[s[4]], m[s[5]]);
        g!(3, 7, 11, 15, m[s[6]], m[s[7]]);
        g!(0, 5, 10, 15, m[s[8]], m[s[9]]);
        g!(1, 6, 11, 12, m[s[10]], m[s[11]]);
        g!(2, 7, 8, 13, m[s[12]], m[s[13]]);
        g!(3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for i in 0..8 {
        h[i] = _mm512_xor_si512(h[i], _mm512_xor_si512(v[i], v[i + 8]));
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f")]
unsafe fn hash8_avx512(prefix: Option<&[[u8; 32]; 8]>, bodies: [&[u8]; 8], out: &mut [[u8; 32]; 8]) {
    let p = if prefix.is_some() { 32 } else { 0 };
    let total = p + bodies[0].len();
    let blocks = total.div_ceil(128).max(1);
    let mut h = [_mm512_setzero_si512(); 8];
    for i in 0..8 {
        h[i] = _mm512_set1_epi64(IV[i] as i64);
    }
    h[0] = _mm512_xor_si512(h[0], _mm512_set1_epi64(0x0101_0020));
    let mut temp = [[0u8; 128]; 8];
    for b in 0..blocks {
        let start = 128 * b;
        let end = (start + 128).min(total);
        let mut rows_lo = [_mm512_setzero_si512(); 8];
        let mut rows_hi = [_mm512_setzero_si512(); 8];
        for l in 0..8 {
            // A full block inside the body is read in place; else it is assembled in `temp`.
            let ptr = if start >= p && end - start == 128 {
                unsafe { bodies[l].as_ptr().add(start - p) }
            } else {
                let tb = &mut temp[l];
                tb.fill(0);
                if start < p {
                    let n = p.min(end) - start;
                    tb[..n].copy_from_slice(&prefix.unwrap()[l][start..start + n]);
                }
                let from = start.max(p);
                if end > from {
                    tb[from - start..end - start].copy_from_slice(&bodies[l][from - p..end - p]);
                }
                tb.as_ptr()
            };
            rows_lo[l] = unsafe { _mm512_loadu_si512(ptr as *const _) };
            rows_hi[l] = unsafe { _mm512_loadu_si512(ptr.add(64) as *const _) };
        }
        let lo = unsafe { transpose8(rows_lo) };
        let hi = unsafe { transpose8(rows_hi) };
        let mut m = [_mm512_setzero_si512(); 16];
        m[..8].copy_from_slice(&lo);
        m[8..].copy_from_slice(&hi);
        unsafe { compress(&mut h, &m, end as u64, b == blocks - 1) };
    }
    for i in 0..4 {
        let mut words = [0u64; 8];
        unsafe { _mm512_storeu_si512(words.as_mut_ptr() as *mut _, h[i]) };
        for l in 0..8 {
            out[l][8 * i..8 * i + 8].copy_from_slice(&words[l].to_le_bytes());
        }
    }
}
