// Strong data-dependent proof of work benchmark for NVIDIA GPUs (CUDA).
//
// One attempt (bip-strong-ddpow.md, Per attempt, with k = 8): x_0 = BLAKE2b-256 of an 80-byte
// header (zero except bytes 0..8 = stream id, 8..16 = nonce, both little-endian); read 0 at
// S + idx(x_0, N - S) in the parent region, reads 1..7 at idx(x_i, N); x_{i+1} = step(x_i, chunk);
// final = x_8. idx(x, n) = u64le(x[0..8]) mod n.
// Steps: "blake2b": x' = BLAKE2b-256(x || chunk). "mul": per lane L in {0, 1}, keys
// k[L][i] = x[(i + 2L) mod 4] + (i + W*L) * 0x9E3779B97F4A7C15, acc_L = sum over p of
// (w_2p + k[L][2p]) * (w_2p+1 + k[L][2p+1]) mod 2^128, x' = BLAKE2b-256(x || acc_0 || acc_1).
// Data: word j of chunk a is splitmix64(a * W + j), W = chunk bytes / 8. The parent region is
// the last 4 MiB of chunks.
//
// Modes: ceiling (a 256 KiB dataset, L2-resident: the step rate), dev (dataset in GPU memory),
// host (dataset in pinned host memory read over PCIe), peer (dataset split across GPUs, reads
// through peer pointers over NVLink or PCIe). Prints one JSON line per run.

#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define CHECK(call)                                                                                      \
    do {                                                                                                 \
        cudaError_t e_ = (call);                                                                         \
        if (e_ != cudaSuccess) {                                                                         \
            fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #call, cudaGetErrorString(e_));      \
            exit(1);                                                                                     \
        }                                                                                                \
    } while (0)

static constexpr uint64_t GOLDEN = 0x9E3779B97F4A7C15ULL;
static constexpr uint64_t PARENT_BYTES = 4ULL << 20;
static constexpr int READS = 8;

__host__ __device__ inline uint64_t splitmix64(uint64_t z)
{
    z += GOLDEN;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

__device__ __forceinline__ uint64_t rotr(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

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

__device__ __forceinline__ void compress(uint64_t h[8], const uint64_t m[16], uint64_t t, bool last)
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

__device__ __forceinline__ void init256(uint64_t h[8])
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

/** BLAKE2b-256 of the 80-byte header: stream id, nonce, then zeros. */
__device__ __forceinline__ void header_hash(uint64_t stream, uint64_t nonce, uint64_t x[4])
{
    uint64_t h[8], m[16] = {};
    init256(h);
    m[0] = stream;
    m[1] = nonce;
    compress(h, m, 80, true);
#pragma unroll
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** x' = BLAKE2b-256(x || chunk), the chunk W words at c. */
template <int W>
__device__ __forceinline__ void step_blake2b(uint64_t x[4], const uint64_t* __restrict__ c)
{
    constexpr int T = 4 + W;                // message words
    constexpr int BLOCKS = (T + 15) / 16;
    uint64_t h[8], m[16];
    init256(h);
#pragma unroll
    for (int j = 0; j < 4; ++j) m[j] = x[j];
#pragma unroll
    for (int j = 4; j < 16; ++j) m[j] = j - 4 < W ? c[j - 4] : 0;
    compress(h, m, uint64_t(8 * min(T, 16)), BLOCKS == 1);
#pragma unroll 1
    for (int b = 1; b < BLOCKS; ++b) {
        const ulonglong2* p = reinterpret_cast<const ulonglong2*>(c + b * 16 - 4);
        const int words = min(16, T - b * 16);
        if (words == 16) {
#pragma unroll
            for (int j = 0; j < 8; ++j) {
                const ulonglong2 q = p[j];
                m[2 * j] = q.x;
                m[2 * j + 1] = q.y;
            }
        } else {
#pragma unroll
            for (int j = 0; j < 16; ++j) m[j] = j < words ? c[b * 16 - 4 + j] : 0;
        }
        compress(h, m, uint64_t(8 * min(T, (b + 1) * 16)), b == BLOCKS - 1);
    }
#pragma unroll
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** The multiply step: two 128-bit sums of 64x64 products keyed by x, then one compression. */
template <int W>
__device__ __forceinline__ void step_mul(uint64_t x[4], const uint64_t* __restrict__ c)
{
    uint64_t lo[2] = {0, 0}, hi[2] = {0, 0};
    const ulonglong2* p = reinterpret_cast<const ulonglong2*>(c);
#pragma unroll 4
    for (int q = 0; q < W / 2; ++q) {
        const ulonglong2 w = p[q];
#pragma unroll
        for (int L = 0; L < 2; ++L) {
            const uint64_t i0 = 2 * q, i1 = 2 * q + 1;
            const uint64_t a = w.x + x[(i0 + 2 * L) & 3] + (i0 + uint64_t(W) * L) * GOLDEN;
            const uint64_t b = w.y + x[(i1 + 2 * L) & 3] + (i1 + uint64_t(W) * L) * GOLDEN;
            const uint64_t plo = a * b, phi = __umul64hi(a, b);
            const uint64_t s = lo[L] + plo;
            hi[L] += phi + (s < plo);
            lo[L] = s;
        }
    }
    uint64_t h[8], m[16] = {};
    init256(h);
#pragma unroll
    for (int j = 0; j < 4; ++j) m[j] = x[j];
    m[4] = lo[0];
    m[5] = hi[0];
    m[6] = lo[1];
    m[7] = hi[1];
    compress(h, m, 64, true);
#pragma unroll
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** The fold step (memory limit): m_j = XOR of the chunk's words i with i mod 4 = j, then
 *  x' = BLAKE2b-256(x || m). One compression per read, so reads, not hashing, set the rate. */
template <int W>
__device__ __forceinline__ void step_fold(uint64_t x[4], const uint64_t* __restrict__ c)
{
    uint64_t f[4] = {0, 0, 0, 0};
    const ulonglong2* p = reinterpret_cast<const ulonglong2*>(c);
#pragma unroll 8
    for (int q = 0; q < W / 2; ++q) {
        const ulonglong2 w = p[q];
        f[(2 * q) & 3] ^= w.x;
        f[(2 * q + 1) & 3] ^= w.y;
    }
    uint64_t h[8], m[16] = {};
    init256(h);
#pragma unroll
    for (int j = 0; j < 4; ++j) {
        m[j] = x[j];
        m[4 + j] = f[j];
    }
    compress(h, m, 64, true);
#pragma unroll
    for (int i = 0; i < 4; ++i) x[i] = h[i];
}

/** Where chunks are: shards of `shard_chunks` chunks each, and a local copy of the parent
 *  region [s, n). */
struct Data {
    const uint64_t* const* shards;
    uint64_t shard_chunks;
    const uint64_t* parent;
    uint64_t n;
    uint64_t s;
};

template <int W>
__device__ __forceinline__ const uint64_t* chunk_at(const Data& d, uint64_t a)
{
    if (a >= d.s) return d.parent + (a - d.s) * W;
    return d.shards[a / d.shard_chunks] + (a % d.shard_chunks) * W;
}

template <int W, int STEP>
__device__ __forceinline__ void attempt(const Data& d, uint64_t stream, uint64_t nonce, uint64_t x[4])
{
    header_hash(stream, nonce, x);
    uint64_t a = d.s + x[0] % (d.n - d.s);
#pragma unroll 1
    for (int i = 0; i < READS; ++i) {
        const uint64_t* c = chunk_at<W>(d, a);
        if (STEP == 0) {
            step_blake2b<W>(x, c);
        } else if (STEP == 1) {
            step_mul<W>(x, c);
        } else {
            step_fold<W>(x, c);
        }
        a = x[0] % d.n;
    }
}

template <int W, int STEP>
__global__ void attempts_kernel(Data d, uint64_t stream_base, uint64_t nonce_base, int iters, uint64_t* sink)
{
    const uint64_t tid = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x;
    uint64_t acc = 0, x[4];
    for (int it = 0; it < iters; ++it) {
        attempt<W, STEP>(d, stream_base + tid, nonce_base + it, x);
        acc ^= x[0];
    }
    sink[tid] ^= acc;
}

/** The staged kernel (chunks of 256 bytes or more): each step, the block loads every thread's
 *  chunk 128 bytes at a time into shared memory, eight threads per 128-byte line so the loads
 *  are whole lines, and each thread hashes (or multiplies) its slice from there. */
template <int W, int STEP>
__global__ void staged_kernel(Data d, uint64_t stream_base, uint64_t nonce_base, int iters, uint64_t* sink)
{
    constexpr int SLICES = W / 16;
    extern __shared__ uint64_t smem[];
    uint64_t* slices = smem;                                                      // blockDim.x x 16 words
    const uint64_t** ptrs = reinterpret_cast<const uint64_t**>(smem + blockDim.x * 16);
    const int t = threadIdx.x;
    const uint64_t tid = uint64_t(blockIdx.x) * blockDim.x + t;
    uint64_t acc = 0;
    for (int it = 0; it < iters; ++it) {
        uint64_t x[4];
        header_hash(stream_base + tid, nonce_base + it, x);
        uint64_t a = d.s + x[0] % (d.n - d.s);
        for (int r = 0; r < READS; ++r) {
            ptrs[t] = chunk_at<W>(d, a);
            uint64_t h[8], m[16], prev[4] = {0, 0, 0, 0}, lo[2] = {0, 0}, hi[2] = {0, 0};
            init256(h);
#pragma unroll 1
            for (int j = 0; j < SLICES; ++j) {
                __syncthreads();
                for (int i = t; i < int(blockDim.x) * 8; i += blockDim.x) {
                    const int owner = i >> 3, part = i & 7;
                    const ulonglong2 q = reinterpret_cast<const ulonglong2*>(ptrs[owner] + 16 * j)[part];
                    slices[owner * 16 + 2 * part] = q.x;
                    slices[owner * 16 + 2 * part + 1] = q.y;
                }
                __syncthreads();
                const uint64_t* sl = slices + t * 16;
                if (STEP == 0) {
#pragma unroll
                    for (int k = 0; k < 4; ++k) m[k] = j == 0 ? x[k] : prev[k];
#pragma unroll
                    for (int k = 0; k < 12; ++k) m[4 + k] = sl[k];
#pragma unroll
                    for (int k = 0; k < 4; ++k) prev[k] = sl[12 + k];
                    compress(h, m, uint64_t(128 * (j + 1)), false);
                } else if (STEP == 2) {
#pragma unroll
                    for (int k = 0; k < 16; ++k) prev[k & 3] ^= sl[k];
                } else {
#pragma unroll
                    for (int k = 0; k < 16; k += 2) {
#pragma unroll
                        for (int L = 0; L < 2; ++L) {
                            const uint64_t i0 = 16 * j + k, i1 = i0 + 1;
                            const uint64_t aa = sl[k] + x[(i0 + 2 * L) & 3] + (i0 + uint64_t(W) * L) * GOLDEN;
                            const uint64_t bb = sl[k + 1] + x[(i1 + 2 * L) & 3] + (i1 + uint64_t(W) * L) * GOLDEN;
                            const uint64_t plo = aa * bb, phi = __umul64hi(aa, bb);
                            const uint64_t sum = lo[L] + plo;
                            hi[L] += phi + (sum < plo);
                            lo[L] = sum;
                        }
                    }
                }
            }
            if (STEP == 0) {
#pragma unroll
                for (int k = 0; k < 16; ++k) m[k] = k < 4 ? prev[k] : 0;
                compress(h, m, uint64_t(32 + 8 * W), true);
            } else if (STEP == 2) {
#pragma unroll
                for (int k = 0; k < 16; ++k) m[k] = 0;
#pragma unroll
                for (int k = 0; k < 4; ++k) {
                    m[k] = x[k];
                    m[4 + k] = prev[k];
                }
                compress(h, m, 64, true);
            } else {
#pragma unroll
                for (int k = 0; k < 16; ++k) m[k] = 0;
#pragma unroll
                for (int k = 0; k < 4; ++k) m[k] = x[k];
                m[4] = lo[0];
                m[5] = hi[0];
                m[6] = lo[1];
                m[7] = hi[1];
                compress(h, m, 64, true);
            }
#pragma unroll
            for (int k = 0; k < 4; ++k) x[k] = h[k];
            a = x[0] % d.n;
        }
        acc ^= x[0];
    }
    sink[tid] ^= acc;
}

template <int W, int STEP>
__global__ void sample_kernel(Data d, const uint64_t* streams, const uint64_t* nonces, int count, uint64_t* finals)
{
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;
    uint64_t x[4];
    attempt<W, STEP>(d, streams[i], nonces[i], x);
    for (int j = 0; j < 4; ++j) finals[4 * i + j] = x[j];
}

__global__ void fill_kernel(uint64_t* out, uint64_t first_word, uint64_t words)
{
    for (uint64_t i = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x; i < words; i += uint64_t(gridDim.x) * blockDim.x) {
        out[i] = splitmix64(first_word + i);
    }
}

// Host

struct Args {
    std::string mode{"dev"}, step{"blake2b"}, samples, kernel{"stream"};
    int chunk{4096}, gpus{0}, tpb{128}, bpsm{8}, device{0};
    double gib{1}, seconds{15};
};

static Args parse(int argc, char** argv)
{
    Args a;
    for (int i = 1; i + 1 < argc; i += 2) {
        const std::string k{argv[i]}, v{argv[i + 1]};
        if (k == "--mode") a.mode = v;
        else if (k == "--step") a.step = v;
        else if (k == "--chunk") a.chunk = std::stoi(v);
        else if (k == "--gib" || k == "--gib-per-gpu") a.gib = std::stod(v);
        else if (k == "--gpus") a.gpus = std::stoi(v);
        else if (k == "--tpb") a.tpb = std::stoi(v);
        else if (k == "--bpsm") a.bpsm = std::stoi(v);
        else if (k == "--seconds") a.seconds = std::stod(v);
        else if (k == "--samples") a.samples = v;
        else if (k == "--device") a.device = std::stoi(v);
        else if (k == "--kernel") a.kernel = v;
        else {
            fprintf(stderr, "unknown option %s\n", k.c_str());
            exit(2);
        }
    }
    if (a.chunk != 64 && a.chunk != 256 && a.chunk != 1024 && a.chunk != 4096 && a.chunk != 8192) {
        fprintf(stderr, "--chunk must be 64, 256, 1024, 4096 or 8192\n");
        exit(2);
    }
    if (a.step != "blake2b" && a.step != "mul" && a.step != "fold") { fprintf(stderr, "--step must be blake2b, mul or fold\n"); exit(2); }
    if (a.kernel != "stream" && a.kernel != "staged") { fprintf(stderr, "--kernel must be stream or staged\n"); exit(2); }
    if (a.kernel == "staged" && a.chunk < 256) { fprintf(stderr, "--kernel staged needs --chunk 256 or more\n"); exit(2); }
    return a;
}

/** One GPU's view of the dataset, on that GPU. */
struct Gpu {
    int device;
    Data data;
    const uint64_t** shard_table{nullptr};
    uint64_t* parent{nullptr};
    uint64_t* sink{nullptr};
    int blocks{0};
    cudaEvent_t done;
};

static void fill(uint64_t* p, uint64_t first_word, uint64_t words)
{
    fill_kernel<<<4096, 256>>>(p, first_word, words);
    CHECK(cudaGetLastError());
}

template <int W, int STEP>
static void launch(const Gpu& g, int tpb, uint64_t stream_base, uint64_t nonce_base, int iters)
{
    attempts_kernel<W, STEP><<<g.blocks, tpb>>>(g.data, stream_base, nonce_base, iters, g.sink);
}

static bool g_staged{false};

template <int W, int STEP>
static void run_kernel(const Gpu& g, int tpb, uint64_t sb, uint64_t nb, int iters)
{
    if constexpr (W >= 32) {
        if (g_staged) {
            const size_t shared{size_t(tpb) * (16 * 8 + 8)};
            staged_kernel<W, STEP><<<g.blocks, tpb, shared>>>(g.data, sb, nb, iters, g.sink);
            return;
        }
    }
    launch<W, STEP>(g, tpb, sb, nb, iters);
}

template <int STEP>
static void dispatch_w(int W, const Gpu& g, int tpb, uint64_t sb, uint64_t nb, int iters)
{
    switch (W) {
    case 8: run_kernel<8, STEP>(g, tpb, sb, nb, iters); break;
    case 32: run_kernel<32, STEP>(g, tpb, sb, nb, iters); break;
    case 128: run_kernel<128, STEP>(g, tpb, sb, nb, iters); break;
    case 512: run_kernel<512, STEP>(g, tpb, sb, nb, iters); break;
    case 1024: run_kernel<1024, STEP>(g, tpb, sb, nb, iters); break;
    }
}

static void dispatch(int W, int step, const Gpu& g, int tpb, uint64_t sb, uint64_t nb, int iters)
{
    if (step == 0) dispatch_w<0>(W, g, tpb, sb, nb, iters);
    else if (step == 1) dispatch_w<1>(W, g, tpb, sb, nb, iters);
    else dispatch_w<2>(W, g, tpb, sb, nb, iters);
    CHECK(cudaGetLastError());
}

template <int W>
static void samples_w(int step, const Data& d, const uint64_t* st, const uint64_t* no, int count, uint64_t* out)
{
    const int b = (count + 63) / 64;
    if (step == 0) sample_kernel<W, 0><<<b, 64>>>(d, st, no, count, out);
    else if (step == 1) sample_kernel<W, 1><<<b, 64>>>(d, st, no, count, out);
    else sample_kernel<W, 2><<<b, 64>>>(d, st, no, count, out);
}

static void dispatch_samples(int W, int step, const Data& d, const uint64_t* st, const uint64_t* no, int count, uint64_t* out)
{
    switch (W) {
    case 8: samples_w<8>(step, d, st, no, count, out); break;
    case 32: samples_w<32>(step, d, st, no, count, out); break;
    case 128: samples_w<128>(step, d, st, no, count, out); break;
    case 512: samples_w<512>(step, d, st, no, count, out); break;
    case 1024: samples_w<1024>(step, d, st, no, count, out); break;
    }
    CHECK(cudaGetLastError());
}

int main(int argc, char** argv)
{
    const Args args{parse(argc, argv)};
    g_staged = args.kernel == "staged";
    const int W{args.chunk / 8};
    const int step{args.step == "mul" ? 1 : args.step == "fold" ? 2 : 0};
    int available;
    CHECK(cudaGetDeviceCount(&available));
    const bool peer{args.mode == "peer"};
    const int count{peer ? (args.gpus ? args.gpus : available) : 1};
    if (count > available) { fprintf(stderr, "%d GPUs requested, %d present\n", count, available); return 2; }
    std::vector<int> devices;
    for (int i = 0; i < count; ++i) devices.push_back(peer ? i : args.device);

    // Dataset size in chunks.
    const uint64_t chunk_bytes{uint64_t(args.chunk)};
    uint64_t shard_chunks;
    if (args.mode == "ceiling") shard_chunks = (256ULL << 10) / chunk_bytes;
    else shard_chunks = uint64_t(args.gib * double(1ULL << 30)) / chunk_bytes;
    const uint64_t n{shard_chunks * count};
    const uint64_t parent_chunks{std::min<uint64_t>(PARENT_BYTES / chunk_bytes, n)};
    const uint64_t s{n - parent_chunks};

    // Shards: one per GPU (peer), else one, in GPU or pinned host memory.
    const auto fill_start{std::chrono::steady_clock::now()};
    std::vector<uint64_t*> shards(count);
    for (int i = 0; i < count; ++i) {
        CHECK(cudaSetDevice(devices[i]));
        const uint64_t bytes{shard_chunks * chunk_bytes};
        if (args.mode == "host") {
            void* hp;
            CHECK(cudaHostAlloc(&hp, bytes, cudaHostAllocMapped));
            void* dp;
            CHECK(cudaHostGetDevicePointer(&dp, hp, 0));
            shards[i] = static_cast<uint64_t*>(dp);
        } else {
            CHECK(cudaMalloc(&shards[i], bytes));
        }
        fill(shards[i], uint64_t(i) * shard_chunks * W, shard_chunks * W);
        CHECK(cudaDeviceSynchronize());
    }
    const double fill_s{std::chrono::duration<double>(std::chrono::steady_clock::now() - fill_start).count()};
    if (peer) {
        for (int i = 0; i < count; ++i) {
            CHECK(cudaSetDevice(devices[i]));
            for (int j = 0; j < count; ++j) {
                if (i == j) continue;
                int can;
                CHECK(cudaDeviceCanAccessPeer(&can, devices[i], devices[j]));
                if (!can) { fprintf(stderr, "GPU %d cannot access GPU %d as a peer\n", devices[i], devices[j]); return 3; }
                const cudaError_t e{cudaDeviceEnablePeerAccess(devices[j], 0)};
                if (e != cudaSuccess && e != cudaErrorPeerAccessAlreadyEnabled) CHECK(e);
            }
        }
    }
    cudaDeviceProp prop;
    CHECK(cudaGetDeviceProperties(&prop, devices[0]));
    std::vector<Gpu> gpus(count);
    for (int i = 0; i < count; ++i) {
        Gpu& g{gpus[i]};
        g.device = devices[i];
        CHECK(cudaSetDevice(g.device));
        CHECK(cudaMalloc(&g.shard_table, count * sizeof(uint64_t*)));
        CHECK(cudaMemcpy(g.shard_table, shards.data(), count * sizeof(uint64_t*), cudaMemcpyHostToDevice));
        // The parent region, local to every GPU.
        CHECK(cudaMalloc(&g.parent, parent_chunks * chunk_bytes));
        fill(g.parent, s * W, parent_chunks * W);
        cudaDeviceProp p;
        CHECK(cudaGetDeviceProperties(&p, g.device));
        g.blocks = p.multiProcessorCount * args.bpsm;
        CHECK(cudaMalloc(&g.sink, uint64_t(g.blocks) * args.tpb * sizeof(uint64_t)));
        CHECK(cudaMemset(g.sink, 0, uint64_t(g.blocks) * args.tpb * sizeof(uint64_t)));
        g.data = Data{g.shard_table, shard_chunks, g.parent, n, s};
        CHECK(cudaEventCreate(&g.done));
        CHECK(cudaDeviceSynchronize());
    }

    // Timed runs: launches of `iters` attempts per thread on every GPU, until `seconds` pass.
    using clock = std::chrono::steady_clock;
    const auto run_round{[&](int iters, uint64_t round) {
        for (int i = 0; i < count; ++i) {
            CHECK(cudaSetDevice(gpus[i].device));
            const uint64_t threads{uint64_t(gpus[i].blocks) * args.tpb};
            dispatch(W, step, gpus[i], args.tpb, (uint64_t(i) << 40) + 0, round * 1'000'000ULL, iters);
            (void)threads;
        }
        for (int i = 0; i < count; ++i) {
            CHECK(cudaSetDevice(gpus[i].device));
            CHECK(cudaDeviceSynchronize());
        }
    }};
    int iters{1};
    {
        const auto t0{clock::now()};
        run_round(iters, 0);
        const double dt{std::chrono::duration<double>(clock::now() - t0).count()};
        iters = std::max(1, int(0.25 / std::max(dt, 1e-6)));
    }
    uint64_t total{0};
    uint64_t round{1};
    const auto t0{clock::now()};
    double elapsed{0};
    while (elapsed < args.seconds) {
        run_round(iters, round++);
        for (const auto& g : gpus) total += uint64_t(g.blocks) * args.tpb * iters;
        elapsed = std::chrono::duration<double>(clock::now() - t0).count();
    }
    const double rate{double(total) / elapsed};
    const double reads{rate * READS};
    const double remote{peer ? double(count - 1) / count * double(s) / double(n) * (READS - 1) / READS : 0};
    printf("{\"kernel\":\"%s\",\"mode\":\"%s\",\"gpu\":\"%s\",\"gpus\":%d,\"chunk\":%d,\"step\":\"%s\",\"gib_per_gpu\":%.3f,"
           "\"chunks\":%" PRIu64 ",\"tpb\":%d,\"bpsm\":%d,\"seconds\":%.2f,\"attempts_per_s\":%.4e,\"reads_per_s\":%.4e,"
           "\"read_GBps\":%.1f,\"remote_read_fraction\":%.3f,\"fill_s\":%.2f}\n",
           args.kernel.c_str(), args.mode.c_str(), prop.name, count, args.chunk, args.step.c_str(), double(shard_chunks * chunk_bytes) / double(1ULL << 30),
           n, args.tpb, args.bpsm, elapsed, rate, reads, reads * chunk_bytes / 1e9, remote, fill_s);
    fflush(stdout);

    // Samples, computed on the first GPU (in peer mode through peer pointers) for verify.py.
    if (!args.samples.empty()) {
        CHECK(cudaSetDevice(gpus[0].device));
        const int sc{128};
        std::vector<uint64_t> st(sc), no(sc), fin(4 * sc);
        for (int i = 0; i < sc; ++i) {
            st[i] = splitmix64(1000 + i) >> 16;
            no[i] = splitmix64(2000 + i) >> 16;
        }
        uint64_t *dst, *dno, *dfin;
        CHECK(cudaMalloc(&dst, sc * 8));
        CHECK(cudaMalloc(&dno, sc * 8));
        CHECK(cudaMalloc(&dfin, sc * 32));
        CHECK(cudaMemcpy(dst, st.data(), sc * 8, cudaMemcpyHostToDevice));
        CHECK(cudaMemcpy(dno, no.data(), sc * 8, cudaMemcpyHostToDevice));
        dispatch_samples(W, step, gpus[0].data, dst, dno, sc, dfin);
        CHECK(cudaDeviceSynchronize());
        CHECK(cudaMemcpy(fin.data(), dfin, sc * 32, cudaMemcpyDeviceToHost));
        FILE* f{fopen(args.samples.c_str(), "w")};
        fprintf(f, "{\"chunk\":%d,\"step\":\"%s\",\"n\":%" PRIu64 ",\"s\":%" PRIu64 ",\"reads\":%d}\n", args.chunk, args.step.c_str(), n, s, READS);
        for (int i = 0; i < sc; ++i) {
            fprintf(f, "%" PRIu64 " %" PRIu64 " ", st[i], no[i]);
            for (int j = 0; j < 4; ++j) {
                for (int b = 0; b < 8; ++b) fprintf(f, "%02x", unsigned(fin[4 * i + j] >> (8 * b)) & 0xff);
            }
            fprintf(f, "\n");
        }
        fclose(f);
    }
    return 0;
}
