// Packing benchmark for CPUs: the chain in RAM, an honest miner reading a stored packed chunk per
// step against a stuffer forming each packed chunk from raw chunks, generating the ones it can
// regenerate with AES-128 in counter mode (AES-NI). Same attempt and partner rule as
// ddpow_pack_cuda.cu: x_0 = BLAKE2b-256(80-byte header: stream id, nonce, zeros); read i at
// a_i = idx(x_i, N); x_{i+1} = BLAKE2b-256(x_i || P(a_i)); P(a) = chunk(a) XOR the chunks at
// p_r = splitmix64(a * 64 + r) mod N, r = 1..m. Chunk p is regenerable if
// splitmix64(p XOR REGEN_SALT) < s * 2^64; its bytes are AES-128-CTR output under the key
// (splitmix64(2p + KEY_SALT), splitmix64(2p + 1 + KEY_SALT)), counter = 16-byte block index; any
// other chunk's word j is splitmix64(p * 512 + j).
//
// The dataset is filled once (regenerable at the largest s listed), then every configuration runs
// in turn for --seconds on all threads. Prints one JSON line per configuration. Configurations
// "m:s:mode": mode h = hash (the rule), f = fold (XOR the chunk's words, one compression: the
// read limit), g = the stuffer (generate its regenerable inputs).
//
// g++ -O3 -march=native -std=c++17 -pthread -o ddpow_pack_cpu ddpow_pack_cpu.cpp

#include <immintrin.h>
#include <sys/mman.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static constexpr uint64_t GOLDEN = 0x9E3779B97F4A7C15ULL;
static constexpr uint64_t REGEN_SALT = 0xA5A5A5A55A5A5A5AULL;
static constexpr uint64_t KEY_SALT = 0x0123456789ABCDEFULL;
static constexpr int READS = 8;
static constexpr size_t CHUNK = 4096;
static constexpr int W = 512;

static inline uint64_t splitmix64(uint64_t z)
{
    z += GOLDEN;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static inline uint64_t rotr(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

#define G(a, b, c, d, x, y)      \
    do {                         \
        a = a + b + (x);         \
        d = rotr(d ^ a, 32);     \
        c = c + d;               \
        b = rotr(b ^ c, 24);     \
        a = a + b + (y);         \
        d = rotr(d ^ a, 16);     \
        c = c + d;               \
        b = rotr(b ^ c, 63);     \
    } while (0)

static inline void compress(uint64_t h[8], const uint64_t m[16], uint64_t t, bool last)
{
    const uint64_t IV[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                            0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
    uint64_t v[16];
#pragma unroll
    for (int i = 0; i < 8; ++i) {
        v[i] = h[i];
        v[i + 8] = IV[i];
    }
    v[12] ^= t;
    if (last) v[14] = ~v[14];
    G(v[0], v[4], v[8], v[12], m[0], m[1]);
    G(v[1], v[5], v[9], v[13], m[2], m[3]);
    G(v[2], v[6], v[10], v[14], m[4], m[5]);
    G(v[3], v[7], v[11], v[15], m[6], m[7]);
    G(v[0], v[5], v[10], v[15], m[8], m[9]);
    G(v[1], v[6], v[11], v[12], m[10], m[11]);
    G(v[2], v[7], v[8], v[13], m[12], m[13]);
    G(v[3], v[4], v[9], v[14], m[14], m[15]);
    G(v[0], v[4], v[8], v[12], m[14], m[10]);
    G(v[1], v[5], v[9], v[13], m[4], m[8]);
    G(v[2], v[6], v[10], v[14], m[9], m[15]);
    G(v[3], v[7], v[11], v[15], m[13], m[6]);
    G(v[0], v[5], v[10], v[15], m[1], m[12]);
    G(v[1], v[6], v[11], v[12], m[0], m[2]);
    G(v[2], v[7], v[8], v[13], m[11], m[7]);
    G(v[3], v[4], v[9], v[14], m[5], m[3]);
    G(v[0], v[4], v[8], v[12], m[11], m[8]);
    G(v[1], v[5], v[9], v[13], m[12], m[0]);
    G(v[2], v[6], v[10], v[14], m[5], m[2]);
    G(v[3], v[7], v[11], v[15], m[15], m[13]);
    G(v[0], v[5], v[10], v[15], m[10], m[14]);
    G(v[1], v[6], v[11], v[12], m[3], m[6]);
    G(v[2], v[7], v[8], v[13], m[7], m[1]);
    G(v[3], v[4], v[9], v[14], m[9], m[4]);
    G(v[0], v[4], v[8], v[12], m[7], m[9]);
    G(v[1], v[5], v[9], v[13], m[3], m[1]);
    G(v[2], v[6], v[10], v[14], m[13], m[12]);
    G(v[3], v[7], v[11], v[15], m[11], m[14]);
    G(v[0], v[5], v[10], v[15], m[2], m[6]);
    G(v[1], v[6], v[11], v[12], m[5], m[10]);
    G(v[2], v[7], v[8], v[13], m[4], m[0]);
    G(v[3], v[4], v[9], v[14], m[15], m[8]);
    G(v[0], v[4], v[8], v[12], m[9], m[0]);
    G(v[1], v[5], v[9], v[13], m[5], m[7]);
    G(v[2], v[6], v[10], v[14], m[2], m[4]);
    G(v[3], v[7], v[11], v[15], m[10], m[15]);
    G(v[0], v[5], v[10], v[15], m[14], m[1]);
    G(v[1], v[6], v[11], v[12], m[11], m[12]);
    G(v[2], v[7], v[8], v[13], m[6], m[8]);
    G(v[3], v[4], v[9], v[14], m[3], m[13]);
    G(v[0], v[4], v[8], v[12], m[2], m[12]);
    G(v[1], v[5], v[9], v[13], m[6], m[10]);
    G(v[2], v[6], v[10], v[14], m[0], m[11]);
    G(v[3], v[7], v[11], v[15], m[8], m[3]);
    G(v[0], v[5], v[10], v[15], m[4], m[13]);
    G(v[1], v[6], v[11], v[12], m[7], m[5]);
    G(v[2], v[7], v[8], v[13], m[15], m[14]);
    G(v[3], v[4], v[9], v[14], m[1], m[9]);
    G(v[0], v[4], v[8], v[12], m[12], m[5]);
    G(v[1], v[5], v[9], v[13], m[1], m[15]);
    G(v[2], v[6], v[10], v[14], m[14], m[13]);
    G(v[3], v[7], v[11], v[15], m[4], m[10]);
    G(v[0], v[5], v[10], v[15], m[0], m[7]);
    G(v[1], v[6], v[11], v[12], m[6], m[3]);
    G(v[2], v[7], v[8], v[13], m[9], m[2]);
    G(v[3], v[4], v[9], v[14], m[8], m[11]);
    G(v[0], v[4], v[8], v[12], m[13], m[11]);
    G(v[1], v[5], v[9], v[13], m[7], m[14]);
    G(v[2], v[6], v[10], v[14], m[12], m[1]);
    G(v[3], v[7], v[11], v[15], m[3], m[9]);
    G(v[0], v[5], v[10], v[15], m[5], m[0]);
    G(v[1], v[6], v[11], v[12], m[15], m[4]);
    G(v[2], v[7], v[8], v[13], m[8], m[6]);
    G(v[3], v[4], v[9], v[14], m[2], m[10]);
    G(v[0], v[4], v[8], v[12], m[6], m[15]);
    G(v[1], v[5], v[9], v[13], m[14], m[9]);
    G(v[2], v[6], v[10], v[14], m[11], m[3]);
    G(v[3], v[7], v[11], v[15], m[0], m[8]);
    G(v[0], v[5], v[10], v[15], m[12], m[2]);
    G(v[1], v[6], v[11], v[12], m[13], m[7]);
    G(v[2], v[7], v[8], v[13], m[1], m[4]);
    G(v[3], v[4], v[9], v[14], m[10], m[5]);
    G(v[0], v[4], v[8], v[12], m[10], m[2]);
    G(v[1], v[5], v[9], v[13], m[8], m[4]);
    G(v[2], v[6], v[10], v[14], m[7], m[6]);
    G(v[3], v[7], v[11], v[15], m[1], m[5]);
    G(v[0], v[5], v[10], v[15], m[15], m[11]);
    G(v[1], v[6], v[11], v[12], m[9], m[14]);
    G(v[2], v[7], v[8], v[13], m[3], m[12]);
    G(v[3], v[4], v[9], v[14], m[13], m[0]);
    G(v[0], v[4], v[8], v[12], m[0], m[1]);
    G(v[1], v[5], v[9], v[13], m[2], m[3]);
    G(v[2], v[6], v[10], v[14], m[4], m[5]);
    G(v[3], v[7], v[11], v[15], m[6], m[7]);
    G(v[0], v[5], v[10], v[15], m[8], m[9]);
    G(v[1], v[6], v[11], v[12], m[10], m[11]);
    G(v[2], v[7], v[8], v[13], m[12], m[13]);
    G(v[3], v[4], v[9], v[14], m[14], m[15]);
    G(v[0], v[4], v[8], v[12], m[14], m[10]);
    G(v[1], v[5], v[9], v[13], m[4], m[8]);
    G(v[2], v[6], v[10], v[14], m[9], m[15]);
    G(v[3], v[7], v[11], v[15], m[13], m[6]);
    G(v[0], v[5], v[10], v[15], m[1], m[12]);
    G(v[1], v[6], v[11], v[12], m[0], m[2]);
    G(v[2], v[7], v[8], v[13], m[11], m[7]);
    G(v[3], v[4], v[9], v[14], m[5], m[3]);
#pragma unroll
    for (int i = 0; i < 8; ++i) h[i] ^= v[i] ^ v[i + 8];
}


static inline void init256(uint64_t h[8])
{
    h[0] = 0x6a09e667f3bcc908ULL ^ 0x01010020ULL;
    h[1] = 0xbb67ae8584caa73bULL;
    h[2] = 0x3c6ef372fe94f82bULL;
    h[3] = 0xa54ff53a5f1d36f1ULL;
    h[4] = 0x510e527fade682d1ULL;
    h[5] = 0x9b05688c2b3e6c1fULL;
    h[6] = 0x1f83d9abfb41bd6bULL;
    h[7] = 0x5be0cd19137e2179ULL;
}

static inline void header_hash(uint64_t stream, uint64_t nonce, uint64_t x[4])
{
    uint64_t h[8], m[16] = {};
    init256(h);
    m[0] = stream;
    m[1] = nonce;
    compress(h, m, 80, true);
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** x' = BLAKE2b-256(x || chunk), the 4,096-byte chunk read in place. */
static inline void step_hash(uint64_t x[4], const unsigned char* c)
{
    uint64_t h[8], m[16];
    init256(h);
    std::memcpy(m, x, 32);
    std::memcpy(m + 4, c, 96);
    compress(h, m, 128, false);
    for (int b = 1; b < 32; ++b) {
        std::memcpy(m, c + 96 + 128 * (b - 1), 128);
        compress(h, m, 128 * (b + 1), false);
    }
    std::memset(m, 0, sizeof(m));
    std::memcpy(m, c + 96 + 128 * 31, 32);
    compress(h, m, 32 + CHUNK, true);
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** The read limit: XOR of the chunk's words into 4, then one compression. */
static inline void step_fold(uint64_t x[4], const unsigned char* c)
{
    uint64_t f[4] = {0, 0, 0, 0};
    const uint64_t* w = reinterpret_cast<const uint64_t*>(c);
    for (int i = 0; i < W; i += 4) {
        f[0] ^= w[i];
        f[1] ^= w[i + 1];
        f[2] ^= w[i + 2];
        f[3] ^= w[i + 3];
    }
    uint64_t h[8], m[16] = {};
    init256(h);
    for (int j = 0; j < 4; ++j) {
        m[j] = x[j];
        m[4 + j] = f[j];
    }
    compress(h, m, 64, true);
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

// 8-lane BLAKE2b with AVX-512: each register holds one 64-bit word of 8 states; message words
// are gathered from the 8 lanes' chunks.

#ifdef __AVX512F__
#define G8(a, b, c, d, x, y)                                                   \
    do {                                                                       \
        a = _mm512_add_epi64(_mm512_add_epi64(a, b), x);                       \
        d = _mm512_ror_epi64(_mm512_xor_si512(d, a), 32);                      \
        c = _mm512_add_epi64(c, d);                                            \
        b = _mm512_ror_epi64(_mm512_xor_si512(b, c), 24);                      \
        a = _mm512_add_epi64(_mm512_add_epi64(a, b), y);                       \
        d = _mm512_ror_epi64(_mm512_xor_si512(d, a), 16);                      \
        c = _mm512_add_epi64(c, d);                                            \
        b = _mm512_ror_epi64(_mm512_xor_si512(b, c), 63);                      \
    } while (0)

static constexpr uint8_t SIGMA8[12][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3}};

static inline void compress8(__m512i h[8], const __m512i m[16], uint64_t t, bool last)
{
    static const uint64_t IV[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                                   0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
    __m512i v[16];
    for (int i = 0; i < 8; ++i) {
        v[i] = h[i];
        v[i + 8] = _mm512_set1_epi64(int64_t(IV[i]));
    }
    v[12] = _mm512_xor_si512(v[12], _mm512_set1_epi64(int64_t(t)));
    if (last) v[14] = _mm512_xor_si512(v[14], _mm512_set1_epi64(-1));
#pragma GCC unroll 12
    for (int r = 0; r < 12; ++r) {
        const uint8_t* s = SIGMA8[r];
        G8(v[0], v[4], v[8], v[12], m[s[0]], m[s[1]]);
        G8(v[1], v[5], v[9], v[13], m[s[2]], m[s[3]]);
        G8(v[2], v[6], v[10], v[14], m[s[4]], m[s[5]]);
        G8(v[3], v[7], v[11], v[15], m[s[6]], m[s[7]]);
        G8(v[0], v[5], v[10], v[15], m[s[8]], m[s[9]]);
        G8(v[1], v[6], v[11], v[12], m[s[10]], m[s[11]]);
        G8(v[2], v[7], v[8], v[13], m[s[12]], m[s[13]]);
        G8(v[3], v[4], v[9], v[14], m[s[14]], m[s[15]]);
    }
    for (int i = 0; i < 8; ++i) h[i] = _mm512_xor_si512(h[i], _mm512_xor_si512(v[i], v[i + 8]));
}

/** x_l' = BLAKE2b-256(x_l || chunk_l) for 8 lanes. */
static inline void step_hash8(uint64_t x[8][4], const unsigned char* const chunk[8])
{
    static const uint64_t IV0[8] = {0x6a09e667f3bcc908ULL ^ 0x01010020ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                                    0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
    __m512i h[8], m[16];
    for (int i = 0; i < 8; ++i) h[i] = _mm512_set1_epi64(int64_t(IV0[i]));
    const __m512i base = _mm512_set_epi64(int64_t(chunk[7]), int64_t(chunk[6]), int64_t(chunk[5]), int64_t(chunk[4]),
                                          int64_t(chunk[3]), int64_t(chunk[2]), int64_t(chunk[1]), int64_t(chunk[0]));
    const auto gather{[&](int64_t offset) { return _mm512_i64gather_epi64(_mm512_add_epi64(base, _mm512_set1_epi64(offset)), static_cast<const void*>(nullptr), 1); }};
    for (int w = 0; w < 4; ++w) m[w] = _mm512_set_epi64(int64_t(x[7][w]), int64_t(x[6][w]), int64_t(x[5][w]), int64_t(x[4][w]),
                                                       int64_t(x[3][w]), int64_t(x[2][w]), int64_t(x[1][w]), int64_t(x[0][w]));
    for (int w = 4; w < 16; ++w) m[w] = gather(8 * (w - 4));
    compress8(h, m, 128, false);
    for (int b = 1; b < 32; ++b) {
        for (int w = 0; w < 16; ++w) m[w] = gather(96 + 128 * (b - 1) + 8 * w);
        compress8(h, m, 128 * (b + 1), false);
    }
    for (int w = 0; w < 16; ++w) m[w] = w < 4 ? gather(96 + 128 * 31 + 8 * w) : _mm512_setzero_si512();
    compress8(h, m, 32 + CHUNK, true);
    alignas(64) uint64_t out[8];
    for (int w = 0; w < 4; ++w) {
        _mm512_store_si512(reinterpret_cast<__m512i*>(out), h[w]);
        for (int l = 0; l < 8; ++l) x[l][w] = out[l];
    }
}
#endif

// AES-128-CTR (AES-NI)

static inline __m128i key_step(__m128i key, __m128i gen)
{
    gen = _mm_shuffle_epi32(gen, 0xff);
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    return _mm_xor_si128(key, gen);
}

static inline void aes_expand(uint64_t p, __m128i rk[11])
{
    rk[0] = _mm_set_epi64x(int64_t(splitmix64(2 * p + 1 + KEY_SALT)), int64_t(splitmix64(2 * p + KEY_SALT)));
    rk[1] = key_step(rk[0], _mm_aeskeygenassist_si128(rk[0], 0x01));
    rk[2] = key_step(rk[1], _mm_aeskeygenassist_si128(rk[1], 0x02));
    rk[3] = key_step(rk[2], _mm_aeskeygenassist_si128(rk[2], 0x04));
    rk[4] = key_step(rk[3], _mm_aeskeygenassist_si128(rk[3], 0x08));
    rk[5] = key_step(rk[4], _mm_aeskeygenassist_si128(rk[4], 0x10));
    rk[6] = key_step(rk[5], _mm_aeskeygenassist_si128(rk[5], 0x20));
    rk[7] = key_step(rk[6], _mm_aeskeygenassist_si128(rk[6], 0x40));
    rk[8] = key_step(rk[7], _mm_aeskeygenassist_si128(rk[7], 0x80));
    rk[9] = key_step(rk[8], _mm_aeskeygenassist_si128(rk[8], 0x1b));
    rk[10] = key_step(rk[9], _mm_aeskeygenassist_si128(rk[9], 0x36));
}

/** The 4,096 bytes of regenerable chunk p, written to `out` (or XORed into it). */
static inline void aes_chunk(uint64_t p, unsigned char* out, bool xor_into)
{
    __m128i rk[11];
    aes_expand(p, rk);
    __m128i* o = reinterpret_cast<__m128i*>(out);
    for (int i = 0; i < 256; i += 8) {
        __m128i b[8];
        for (int k = 0; k < 8; ++k) b[k] = _mm_xor_si128(_mm_set_epi64x(0, i + k), rk[0]);
        for (int r = 1; r < 10; ++r) {
            for (int k = 0; k < 8; ++k) b[k] = _mm_aesenc_si128(b[k], rk[r]);
        }
        for (int k = 0; k < 8; ++k) {
            b[k] = _mm_aesenclast_si128(b[k], rk[10]);
            _mm_storeu_si128(o + i + k, xor_into ? _mm_xor_si128(_mm_loadu_si128(o + i + k), b[k]) : b[k]);
        }
    }
}

static inline bool regenerable(uint64_t p, uint64_t threshold) { return splitmix64(p ^ REGEN_SALT) < threshold; }

static uint64_t threshold_of(double s) { return s >= 1 ? ~0ULL : uint64_t(s * 18446744073709551616.0); }

struct Config {
    int m;
    double s;
    char mode;  // h, f, g
};

struct Dataset {
    unsigned char* data;
    uint64_t n;
};

/** The chunk hashed at position a: the stored chunk in place, or P(a) formed in `buf`. */
static inline const unsigned char* form_chunk(const Dataset& d, const Config& c, uint64_t threshold, bool generate, uint64_t a,
                                              unsigned char* buf, uint64_t& reads, uint64_t& generated)
{
    if (c.m == 0 && !(generate && regenerable(a, threshold))) {
        ++reads;
        return d.data + a * CHUNK;
    }
    for (int q = 0; q <= c.m; ++q) {
        const uint64_t p{q == 0 ? a : splitmix64(a * 64 + q) % d.n};
        if (generate && regenerable(p, threshold)) {
            aes_chunk(p, buf, q != 0);
            ++generated;
        } else {
            const uint64_t* src = reinterpret_cast<const uint64_t*>(d.data + p * CHUNK);
            uint64_t* dst = reinterpret_cast<uint64_t*>(buf);
            if (q == 0) {
                std::memcpy(dst, src, CHUNK);
            } else {
                for (int i = 0; i < W; ++i) dst[i] ^= src[i];
            }
            ++reads;
        }
    }
    return buf;
}

/** One attempt's final. `generate`: regenerable inputs are generated, else read. */
static void attempt(const Dataset& d, const Config& c, uint64_t threshold, bool generate, uint64_t stream, uint64_t nonce,
                    unsigned char* buf, uint64_t x[4], uint64_t& reads, uint64_t& generated)
{
    header_hash(stream, nonce, x);
    uint64_t a = x[0] % d.n;
    for (int r = 0; r < READS; ++r) {
        const unsigned char* chunk;
        if (c.m == 0 && !(generate && regenerable(a, threshold))) {
            chunk = d.data + a * CHUNK;
            ++reads;
        } else {
            for (int q = 0; q <= c.m; ++q) {
                const uint64_t p{q == 0 ? a : splitmix64(a * 64 + q) % d.n};
                if (generate && regenerable(p, threshold)) {
                    aes_chunk(p, buf, q != 0);
                    ++generated;
                } else {
                    const uint64_t* src = reinterpret_cast<const uint64_t*>(d.data + p * CHUNK);
                    uint64_t* dst = reinterpret_cast<uint64_t*>(buf);
                    if (q == 0) {
                        std::memcpy(dst, src, CHUNK);
                    } else {
                        for (int i = 0; i < W; ++i) dst[i] ^= src[i];
                    }
                    ++reads;
                }
            }
            chunk = buf;
        }
        if (c.mode == 'f') step_fold(x, chunk);
        else step_hash(x, chunk);
        a = x[0] % d.n;
    }
}

int main(int argc, char** argv)
{
    double gib{4}, seconds{10};
    std::string hash{"scalar"};
    unsigned threads{std::thread::hardware_concurrency()};
    std::string configs_arg{"0:0:h,0:0:f,0:0.35:g,7:0.35:g"};
    std::string check_out;
    for (int i = 1; i + 1 < argc; i += 2) {
        const std::string k{argv[i]}, v{argv[i + 1]};
        if (k == "--gib") gib = std::stod(v);
        else if (k == "--seconds") seconds = std::stod(v);
        else if (k == "--threads") threads = unsigned(std::stoul(v));
        else if (k == "--configs") configs_arg = v;
        else if (k == "--check") check_out = v;
        else if (k == "--hash") hash = v;
        else {
            fprintf(stderr, "unknown option %s\n", k.c_str());
            return 2;
        }
    }
    std::vector<Config> configs;
    double s_max{0};
    for (size_t pos = 0; pos < configs_arg.size();) {
        const size_t end{std::min(configs_arg.find(',', pos), configs_arg.size())};
        const std::string item{configs_arg.substr(pos, end - pos)};
        Config c;
        char mode;
        if (sscanf(item.c_str(), "%d:%lf:%c", &c.m, &c.s, &mode) != 3 || (mode != 'h' && mode != 'f' && mode != 'g')) {
            fprintf(stderr, "bad configuration %s\n", item.c_str());
            return 2;
        }
        c.mode = mode;
        configs.push_back(c);
        s_max = std::max(s_max, c.s);
        pos = end + 1;
    }

    const uint64_t n{uint64_t(gib * double(1ULL << 30)) / CHUNK};
    const size_t bytes{n * CHUNK};
    void* mem{mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)};
    if (mem == MAP_FAILED) { perror("mmap"); return 1; }
    madvise(mem, bytes, MADV_HUGEPAGE);
    Dataset d{static_cast<unsigned char*>(mem), n};
    const uint64_t fill_threshold{threshold_of(s_max)};
    const auto fill_start{std::chrono::steady_clock::now()};
    {
        std::vector<std::thread> pool;
        for (unsigned t = 0; t < threads; ++t) {
            pool.emplace_back([&, t] {
                for (uint64_t p = t; p < n; p += threads) {
                    unsigned char* c{d.data + p * CHUNK};
                    if (regenerable(p, fill_threshold)) {
                        aes_chunk(p, c, false);
                    } else {
                        uint64_t* w = reinterpret_cast<uint64_t*>(c);
                        for (int j = 0; j < W; ++j) w[j] = splitmix64(p * W + j);
                    }
                }
            });
        }
        for (auto& th : pool) th.join();
    }
    const double fill_s{std::chrono::duration<double>(std::chrono::steady_clock::now() - fill_start).count()};

    FILE* check{check_out.empty() ? nullptr : fopen(check_out.c_str(), "w")};
    for (const Config& c : configs) {
        const uint64_t threshold{threshold_of(c.s)};
        const bool generate{c.mode == 'g'};
        // Check: 16 attempts with regenerable inputs generated and with every input read agree.
        int agree{0};
        {
            std::vector<unsigned char> buf(CHUNK);
            for (int k = 0; k < 16; ++k) {
                uint64_t xa[4], xb[4], r0 = 0, g0 = 0;
                attempt(d, c, threshold, generate, 1000 + k, 7, buf.data(), xa, r0, g0);
                attempt(d, c, threshold, false, 1000 + k, 7, buf.data(), xb, r0, g0);
                agree += std::equal(xa, xa + 4, xb);
                if (check && c.mode != 'f') {
                    fprintf(check, "%d %.4f %c %d %" PRIu64 " ", c.m, c.s, c.mode, 1000 + k, uint64_t(7));
                    for (int j = 0; j < 4; ++j) {
                        for (int b = 0; b < 8; ++b) fprintf(check, "%02x", unsigned(xa[j] >> (8 * b)) & 0xff);
                    }
                    fprintf(check, "\n");
                }
            }
        }
#ifdef __AVX512F__
        if (hash == "x8" && c.mode != 'f') {
            std::vector<unsigned char> bufs(8 * CHUNK), buf(CHUNK);
            uint64_t x[8][4], a[8], r0 = 0, g0 = 0;
            const unsigned char* chunk[8];
            for (int l = 0; l < 8; ++l) {
                header_hash(2000 + l, 9, x[l]);
                a[l] = x[l][0] % d.n;
            }
            for (int r = 0; r < READS; ++r) {
                for (int l = 0; l < 8; ++l) chunk[l] = form_chunk(d, c, threshold, generate, a[l], bufs.data() + l * CHUNK, r0, g0);
                step_hash8(x, chunk);
                for (int l = 0; l < 8; ++l) a[l] = x[l][0] % d.n;
            }
            for (int l = 0; l < 8; ++l) {
                uint64_t xs[4];
                attempt(d, c, threshold, generate, 2000 + l, 9, buf.data(), xs, r0, g0);
                agree += std::equal(xs, xs + 4, x[l]) ? 0 : -100;
            }
        }
#endif
        std::atomic<bool> stop{false};
        std::atomic<uint64_t> total{0}, reads{0}, generated{0};
        std::vector<std::thread> pool;
        for (unsigned t = 0; t < threads; ++t) {
            pool.emplace_back([&, t] {
                uint64_t local{0}, lr{0}, lg{0}, nonce{0};
                if (hash == "x8" && c.mode != 'f') {
#ifdef __AVX512F__
                    std::vector<unsigned char> bufs(8 * CHUNK);
                    uint64_t x[8][4], a[8];
                    const unsigned char* chunk[8];
                    while (!stop.load(std::memory_order_relaxed)) {
                        for (int l = 0; l < 8; ++l) {
                            header_hash((uint64_t(t) << 40) | 1, nonce++, x[l]);
                            a[l] = x[l][0] % d.n;
                        }
                        for (int r = 0; r < READS; ++r) {
                            for (int l = 0; l < 8; ++l) chunk[l] = form_chunk(d, c, threshold, generate, a[l], bufs.data() + l * CHUNK, lr, lg);
                            step_hash8(x, chunk);
                            for (int l = 0; l < 8; ++l) a[l] = x[l][0] % d.n;
                        }
                        local += 8;
                    }
#endif
                } else {
                    std::vector<unsigned char> buf(CHUNK);
                    uint64_t x[4];
                    while (!stop.load(std::memory_order_relaxed)) {
                        for (int i = 0; i < 16; ++i) attempt(d, c, threshold, generate, (uint64_t(t) << 40) | 1, nonce++, buf.data(), x, lr, lg);
                        local += 16;
                    }
                }
                total += local;
                reads += lr;
                generated += lg;
            });
        }
        const auto t0{std::chrono::steady_clock::now()};
        std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
        stop = true;
        for (auto& th : pool) th.join();
        const double elapsed{std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count()};
        const double rate{double(total.load()) / elapsed};
        printf("{\"hash\":\"%s\",\"m\":%d,\"s\":%.4f,\"mode\":\"%c\",\"threads\":%u,\"gib\":%.1f,\"seconds\":%.2f,\"attempts_per_s\":%.4e,"
               "\"reads_per_step\":%.3f,\"generated_per_step\":%.3f,\"read_GBps\":%.1f,\"check_agree\":%d,\"fill_s\":%.1f}\n",
               hash.c_str(), c.m, c.s, c.mode, threads, gib, elapsed, rate, double(reads.load()) / (double(total.load()) * READS),
               double(generated.load()) / (double(total.load()) * READS), double(reads.load()) * CHUNK / elapsed / 1e9, agree, fill_s);
        fflush(stdout);
    }
    if (check) fclose(check);
    return 0;
}
