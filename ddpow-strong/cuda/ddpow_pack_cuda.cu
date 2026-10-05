// Packing benchmark for NVIDIA GPUs (CUDA): an honest miner reading a stored packed chunk per
// step against a stuffer forming each packed chunk from raw chunks, generating the ones it can
// regenerate (bip-strong-ddpow.md, Packing; k = 8, 4,096-byte chunks).
//
// One attempt: x_0 = BLAKE2b-256 of an 80-byte header (zero except bytes 0..8 = stream id, 8..16
// = nonce, little-endian); read i at a_i = idx(x_i, N), i = 0..7 (no parent region);
// x_{i+1} = BLAKE2b-256(x_i || P(a_i)), final = x_8. idx(x, n) = u64le(x[0..8]) mod n.
// P(a) = chunk(a) XOR chunk(p_1) XOR ... XOR chunk(p_m), p_r = splitmix64(a * 64 + r) mod N (a
// stand-in for the partner rule: uniform positions). With m = 0, P(a) = chunk(a): the honest
// miner's read of its stored packed chunk costs one chunk read, the same as this.
//
// Data: chunk p is regenerable if splitmix64(p XOR REGEN_SALT) < s * 2^64. A regenerable chunk is
// ChaCha8 output (key words 2i, 2i+1 = low and high halves of splitmix64(p * 4 + i + KEY_SALT),
// nonce 0, block counter = 64-byte block index); any other chunk's word j is splitmix64(p * W + j).
// The stuffer (--generate 1) generates its regenerable inputs instead of reading them; with
// --generate 0 every input is read. Both compute the same P(a) and so the same finals.
//
// Modes: ceiling (a 256 KiB dataset, cache-resident), dev (one GPU's memory), peer (split across
// GPUs, reads through peer pointers). Prints one JSON line per run.

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
static constexpr uint64_t REGEN_SALT = 0xA5A5A5A55A5A5A5AULL;
static constexpr uint64_t KEY_SALT = 0x0123456789ABCDEFULL;
static constexpr int READS = 8;
static constexpr int W = 512;          // 4,096-byte chunks
static constexpr int SLICES = W / 16;  // 128-byte slices
static constexpr int MAX_INPUTS = 32;  // 1 + partners

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

// ChaCha8

__host__ __device__ __forceinline__ uint32_t rotl32(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

#define QR(a, b, c, d)                    \
    do {                                  \
        a += b; d ^= a; d = rotl32(d, 16); \
        c += d; b ^= c; b = rotl32(b, 12); \
        a += b; d ^= a; d = rotl32(d, 8);  \
        c += d; b ^= c; b = rotl32(b, 7);  \
    } while (0)

__host__ __device__ __forceinline__ void chacha8_key(uint64_t p, uint32_t key[8])
{
    for (int i = 0; i < 4; ++i) {
        const uint64_t k{splitmix64(p * 4 + i + KEY_SALT)};
        key[2 * i] = uint32_t(k);
        key[2 * i + 1] = uint32_t(k >> 32);
    }
}

/** 64 bytes of ChaCha8 (8 rounds) at block `counter`, as 8 little-endian 64-bit words. */
__host__ __device__ __forceinline__ void chacha8_block(const uint32_t key[8], uint32_t counter, uint64_t out[8])
{
    uint32_t s[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574, key[0], key[1], key[2], key[3],
                      key[4], key[5], key[6], key[7], counter, 0, 0, 0};
    uint32_t x[16];
    for (int i = 0; i < 16; ++i) x[i] = s[i];
    for (int r = 0; r < 4; ++r) {
        QR(x[0], x[4], x[8], x[12]);
        QR(x[1], x[5], x[9], x[13]);
        QR(x[2], x[6], x[10], x[14]);
        QR(x[3], x[7], x[11], x[15]);
        QR(x[0], x[5], x[10], x[15]);
        QR(x[1], x[6], x[11], x[12]);
        QR(x[2], x[7], x[8], x[13]);
        QR(x[3], x[4], x[9], x[14]);
    }
    for (int i = 0; i < 8; ++i) out[i] = uint64_t(x[2 * i] + s[2 * i]) | (uint64_t(x[2 * i + 1] + s[2 * i + 1]) << 32);
}

// Data

struct Data {
    const uint64_t* const* shards;
    uint64_t shard_chunks;
    uint64_t n;
    unsigned partners;
    uint64_t regen_threshold;  // chunk p is regenerable if splitmix64(p ^ REGEN_SALT) < this
    bool generate;             // the stuffer: generate regenerable inputs instead of reading them
    uint64_t* trace{nullptr};
    uint64_t trace_stride{1};
};

__host__ __device__ __forceinline__ bool regenerable(uint64_t p, uint64_t threshold)
{
    return splitmix64(p ^ REGEN_SALT) < threshold;
}

__device__ __forceinline__ const uint64_t* chunk_at(const Data& d, uint64_t a)
{
    return d.shards[a / d.shard_chunks] + (a % d.shard_chunks) * W;
}

/** Inputs of P(a): a, then its partners. */
__device__ __forceinline__ uint64_t input_position(const Data& d, uint64_t a, unsigned r)
{
    return r == 0 ? a : splitmix64(a * 64 + r) % d.n;
}

__device__ __forceinline__ void record(const Data& d, uint64_t tid, int it, const uint64_t x[4])
{
    if (d.trace && it == 0 && tid % d.trace_stride == 0 && tid / d.trace_stride < 128) {
        for (int j = 0; j < 4; ++j) d.trace[4 * (tid / d.trace_stride) + j] = x[j];
    }
}

/** Staged kernel: per step and 128-byte slice, the block loads every thread's read inputs a line
 *  at a time into shared memory (eight threads per line); each thread XORs its inputs' slices,
 *  generated or loaded, and compresses. */
__global__ void staged_kernel(Data d, uint64_t stream_base, uint64_t nonce_base, int iters, uint64_t* sink, unsigned long long* counts)
{
    extern __shared__ uint64_t smem[];
    uint64_t* slices = smem;                                                    // blockDim.x x 16 words
    const uint64_t** ptrs = reinterpret_cast<const uint64_t**>(smem + blockDim.x * 16);
    const int t = threadIdx.x;
    const uint64_t tid = uint64_t(blockIdx.x) * blockDim.x + t;
    const unsigned inputs = 1 + d.partners;
    uint64_t acc_out = 0;
    unsigned long long reads = 0, generated = 0;
    for (int it = 0; it < iters; ++it) {
        uint64_t x[4];
        header_hash(stream_base + tid, nonce_base + it, x);
        uint64_t a = x[0] % d.n;
        for (int r = 0; r < READS; ++r) {
            uint64_t h[8], m[16], prev[4] = {0, 0, 0, 0};
            init256(h);
            uint32_t gen_mask = 0;
            for (unsigned q = 0; q < inputs; ++q) {
                const uint64_t p{input_position(d, a, q)};
                if (d.generate && regenerable(p, d.regen_threshold)) gen_mask |= 1u << q;
            }
            reads += inputs - __popc(gen_mask);
            generated += __popc(gen_mask);
#pragma unroll 1
            for (int j = 0; j < SLICES; ++j) {
                uint64_t acc[16];
#pragma unroll
                for (int k = 0; k < 16; ++k) acc[k] = 0;
#pragma unroll 1
                for (unsigned q = 0; q < inputs; ++q) {
                    const uint64_t p{input_position(d, a, q)};
                    const bool gen{((gen_mask >> q) & 1) != 0};
                    __syncthreads();
                    ptrs[t] = gen ? nullptr : chunk_at(d, p);
                    __syncthreads();
                    for (int i = t; i < int(blockDim.x) * 8; i += blockDim.x) {
                        const int owner = i >> 3, part = i & 7;
                        const uint64_t* src = ptrs[owner];
                        if (src) {
                            const ulonglong2 v = reinterpret_cast<const ulonglong2*>(src + 16 * j)[part];
                            slices[owner * 16 + 2 * part] = v.x;
                            slices[owner * 16 + 2 * part + 1] = v.y;
                        }
                    }
                    __syncthreads();
                    if (gen) {
                        uint32_t key[8];
                        chacha8_key(p, key);
                        uint64_t blk[8];
                        chacha8_block(key, uint32_t(2 * j), blk);
#pragma unroll
                        for (int k = 0; k < 8; ++k) acc[k] ^= blk[k];
                        chacha8_block(key, uint32_t(2 * j + 1), blk);
#pragma unroll
                        for (int k = 0; k < 8; ++k) acc[8 + k] ^= blk[k];
                    } else {
                        const uint64_t* sl = slices + t * 16;
#pragma unroll
                        for (int k = 0; k < 16; ++k) acc[k] ^= sl[k];
                    }
                }
#pragma unroll
                for (int k = 0; k < 4; ++k) m[k] = j == 0 ? x[k] : prev[k];
#pragma unroll
                for (int k = 0; k < 12; ++k) m[4 + k] = acc[k];
#pragma unroll
                for (int k = 0; k < 4; ++k) prev[k] = acc[12 + k];
                compress(h, m, uint64_t(128 * (j + 1)), false);
            }
#pragma unroll
            for (int k = 0; k < 16; ++k) m[k] = k < 4 ? prev[k] : 0;
            compress(h, m, uint64_t(32 + 8 * W), true);
#pragma unroll
            for (int k = 0; k < 4; ++k) x[k] = h[k];
            a = x[0] % d.n;
        }
        record(d, tid, it, x);
        acc_out ^= x[0];
    }
    sink[tid] ^= acc_out;
    atomicAdd(&counts[0], reads);
    atomicAdd(&counts[1], generated);
}

/** Fused kernel: each step, the block's table holds every thread's read inputs (null if
 *  generated); per 128-byte slice, each loader thread XORs the 16 bytes it owns from all read
 *  inputs of one owner (all loads in flight together), then each owner XORs its generated inputs
 *  and compresses. One barrier pair per slice. */
__global__ void fused_kernel(Data d, uint64_t stream_base, uint64_t nonce_base, int iters, uint64_t* sink, unsigned long long* counts)
{
    extern __shared__ uint64_t smem[];
    uint64_t* slices = smem;                                                    // blockDim.x x 16 words
    const uint64_t** table = reinterpret_cast<const uint64_t**>(smem + blockDim.x * 16);  // blockDim.x x MAX_INPUTS
    const int t = threadIdx.x;
    const uint64_t tid = uint64_t(blockIdx.x) * blockDim.x + t;
    const unsigned inputs = 1 + d.partners;
    uint64_t acc_out = 0;
    unsigned long long reads = 0, generated = 0;
    for (int it = 0; it < iters; ++it) {
        uint64_t x[4];
        header_hash(stream_base + tid, nonce_base + it, x);
        uint64_t a = x[0] % d.n;
        for (int r = 0; r < READS; ++r) {
            uint64_t h[8], m[16], prev[4] = {0, 0, 0, 0};
            init256(h);
            uint32_t gen_mask = 0;
            uint64_t gen_pos[MAX_INPUTS];
            for (unsigned q = 0; q < inputs; ++q) {
                const uint64_t p{input_position(d, a, q)};
                const bool gen{d.generate && regenerable(p, d.regen_threshold)};
                if (gen) {
                    gen_mask |= 1u << q;
                    gen_pos[q] = p;
                }
                table[t * MAX_INPUTS + q] = gen ? nullptr : chunk_at(d, p);
            }
            reads += inputs - __popc(gen_mask);
            generated += __popc(gen_mask);
#pragma unroll 1
            for (int j = 0; j < SLICES; ++j) {
                __syncthreads();
                for (int i = t; i < int(blockDim.x) * 8; i += blockDim.x) {
                    const int owner = i >> 3, part = i & 7;
                    ulonglong2 v{0, 0};
                    for (unsigned q = 0; q < inputs; ++q) {
                        const uint64_t* src = table[owner * MAX_INPUTS + q];
                        if (src) {
                            const ulonglong2 w = reinterpret_cast<const ulonglong2*>(src + 16 * j)[part];
                            v.x ^= w.x;
                            v.y ^= w.y;
                        }
                    }
                    slices[owner * 16 + 2 * part] = v.x;
                    slices[owner * 16 + 2 * part + 1] = v.y;
                }
                __syncthreads();
                uint64_t acc[16];
                const uint64_t* sl = slices + t * 16;
#pragma unroll
                for (int k = 0; k < 16; ++k) acc[k] = sl[k];
                for (unsigned q = 0; q < inputs; ++q) {
                    if (!((gen_mask >> q) & 1)) continue;
                    uint32_t key[8];
                    chacha8_key(gen_pos[q], key);
                    uint64_t blk[8];
                    chacha8_block(key, uint32_t(2 * j), blk);
#pragma unroll
                    for (int k = 0; k < 8; ++k) acc[k] ^= blk[k];
                    chacha8_block(key, uint32_t(2 * j + 1), blk);
#pragma unroll
                    for (int k = 0; k < 8; ++k) acc[8 + k] ^= blk[k];
                }
#pragma unroll
                for (int k = 0; k < 4; ++k) m[k] = j == 0 ? x[k] : prev[k];
#pragma unroll
                for (int k = 0; k < 12; ++k) m[4 + k] = acc[k];
#pragma unroll
                for (int k = 0; k < 4; ++k) prev[k] = acc[12 + k];
                compress(h, m, uint64_t(128 * (j + 1)), false);
            }
            __syncthreads();
#pragma unroll
            for (int k = 0; k < 16; ++k) m[k] = k < 4 ? prev[k] : 0;
            compress(h, m, uint64_t(32 + 8 * W), true);
#pragma unroll
            for (int k = 0; k < 4; ++k) x[k] = h[k];
            a = x[0] % d.n;
        }
        record(d, tid, it, x);
        acc_out ^= x[0];
    }
    sink[tid] ^= acc_out;
    atomicAdd(&counts[0], reads);
    atomicAdd(&counts[1], generated);
}

/** The reference: every input read from the dataset, one thread per attempt, no shared memory. */
__global__ void sample_kernel(Data d, const uint64_t* streams, const uint64_t* nonces, int count, uint64_t* finals)
{
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;
    uint64_t x[4];
    header_hash(streams[i], nonces[i], x);
    uint64_t a = x[0] % d.n;
    for (int r = 0; r < READS; ++r) {
        uint64_t h[8], m[16], prev[4] = {0, 0, 0, 0};
        init256(h);
        for (int j = 0; j < SLICES; ++j) {
            uint64_t acc[16] = {};
            for (unsigned q = 0; q <= d.partners; ++q) {
                const uint64_t* c = chunk_at(d, input_position(d, a, q)) + 16 * j;
                for (int k = 0; k < 16; ++k) acc[k] ^= c[k];
            }
            for (int k = 0; k < 4; ++k) m[k] = j == 0 ? x[k] : prev[k];
            for (int k = 0; k < 12; ++k) m[4 + k] = acc[k];
            for (int k = 0; k < 4; ++k) prev[k] = acc[12 + k];
            compress(h, m, uint64_t(128 * (j + 1)), false);
        }
        for (int k = 0; k < 16; ++k) m[k] = k < 4 ? prev[k] : 0;
        compress(h, m, uint64_t(32 + 8 * W), true);
        for (int k = 0; k < 4; ++k) x[k] = h[k];
        a = x[0] % d.n;
    }
    for (int j = 0; j < 4; ++j) finals[4 * i + j] = x[j];
}

/** Chunks [first, first + chunks): ChaCha8 output if regenerable, else splitmix64 words. */
__global__ void fill_kernel(uint64_t* out, uint64_t first, uint64_t chunks, uint64_t threshold)
{
    const uint64_t words{chunks * W};
    for (uint64_t i = uint64_t(blockIdx.x) * blockDim.x + threadIdx.x; i < words / 8; i += uint64_t(gridDim.x) * blockDim.x) {
        const uint64_t word{i * 8};
        const uint64_t p{first + word / W};
        const uint64_t off{word % W};
        if (regenerable(p, threshold)) {
            uint32_t key[8];
            chacha8_key(p, key);
            uint64_t blk[8];
            chacha8_block(key, uint32_t(off / 8), blk);
            for (int k = 0; k < 8; ++k) out[word + k] = blk[k];
        } else {
            for (int k = 0; k < 8; ++k) out[word + k] = splitmix64(p * W + off + k);
        }
    }
}

// Host

struct Args {
    std::string mode{"dev"}, samples, list, kernel{"staged"};
    int gpus{0}, tpb{128}, bpsm{4}, device{0}, partners{0}, generate{0};
    double gib{1}, seconds{15}, regen{0};
};

static Args parse(int argc, char** argv)
{
    Args a;
    for (int i = 1; i + 1 < argc; i += 2) {
        const std::string k{argv[i]}, v{argv[i + 1]};
        if (k == "--mode") a.mode = v;
        else if (k == "--gib" || k == "--gib-per-gpu") a.gib = std::stod(v);
        else if (k == "--gpus") a.gpus = std::stoi(v);
        else if (k == "--tpb") a.tpb = std::stoi(v);
        else if (k == "--bpsm") a.bpsm = std::stoi(v);
        else if (k == "--seconds") a.seconds = std::stod(v);
        else if (k == "--samples") a.samples = v;
        else if (k == "--device") a.device = std::stoi(v);
        else if (k == "--partners") a.partners = std::stoi(v);
        else if (k == "--regen") a.regen = std::stod(v);
        else if (k == "--generate") a.generate = std::stoi(v);
        else if (k == "--list") a.list = v;
        else if (k == "--kernel") a.kernel = v;
        else {
            fprintf(stderr, "unknown option %s\n", k.c_str());
            exit(2);
        }
    }
    if (a.partners < 0 || a.partners + 1 > MAX_INPUTS) { fprintf(stderr, "--partners must be 0..%d\n", MAX_INPUTS - 1); exit(2); }
    if (a.regen < 0 || a.regen > 1) { fprintf(stderr, "--regen must be 0..1\n"); exit(2); }
    return a;
}

struct Gpu {
    int device;
    Data data;
    const uint64_t** shard_table{nullptr};
    uint64_t* sink{nullptr};
    unsigned long long* counts{nullptr};
    int blocks{0};
};

int main(int argc, char** argv)
{
    const Args args{parse(argc, argv)};
    int available;
    CHECK(cudaGetDeviceCount(&available));
    const bool peer{args.mode == "peer"};
    const int count{peer ? (args.gpus ? args.gpus : available) : 1};
    if (count > available) { fprintf(stderr, "%d GPUs requested, %d present\n", count, available); return 2; }
    std::vector<int> devices;
    for (int i = 0; i < count; ++i) devices.push_back(peer ? i : args.device);

    const uint64_t chunk_bytes{W * 8};
    const uint64_t shard_chunks{args.mode == "ceiling" ? (256ULL << 10) / chunk_bytes : uint64_t(args.gib * double(1ULL << 30)) / chunk_bytes};
    const uint64_t n{shard_chunks * count};
    const uint64_t threshold{args.regen >= 1 ? ~0ULL : uint64_t(args.regen * 18446744073709551616.0)};

    const auto fill_start{std::chrono::steady_clock::now()};
    std::vector<uint64_t*> shards(count);
    for (int i = 0; i < count; ++i) {
        CHECK(cudaSetDevice(devices[i]));
        CHECK(cudaMalloc(&shards[i], shard_chunks * chunk_bytes));
        fill_kernel<<<4096, 256>>>(shards[i], uint64_t(i) * shard_chunks, shard_chunks, threshold);
        CHECK(cudaGetLastError());
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
        cudaDeviceProp p;
        CHECK(cudaGetDeviceProperties(&p, g.device));
        g.blocks = p.multiProcessorCount * args.bpsm;
        CHECK(cudaMalloc(&g.sink, uint64_t(g.blocks) * args.tpb * sizeof(uint64_t)));
        CHECK(cudaMemset(g.sink, 0, uint64_t(g.blocks) * args.tpb * sizeof(uint64_t)));
        CHECK(cudaMalloc(&g.counts, 2 * sizeof(unsigned long long)));
        CHECK(cudaMemset(g.counts, 0, 2 * sizeof(unsigned long long)));
        g.data = Data{g.shard_table, shard_chunks, n, unsigned(args.partners), threshold, args.generate != 0};
        CHECK(cudaDeviceSynchronize());
    }
    const bool fused{args.kernel == "fused"};
    const size_t shared{fused ? size_t(args.tpb) * (16 * 8 + MAX_INPUTS * 8) : size_t(args.tpb) * (16 * 8 + 8)};
    if (fused) {
        for (const auto& g : gpus) {
            CHECK(cudaSetDevice(g.device));
            CHECK(cudaFuncSetAttribute(fused_kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, int(shared)));
        }
    }
    const auto launch{[&](const Gpu& g, uint64_t sb, uint64_t nb, int it) {
        if (fused) fused_kernel<<<g.blocks, args.tpb, shared>>>(g.data, sb, nb, it, g.sink, g.counts);
        else staged_kernel<<<g.blocks, args.tpb, shared>>>(g.data, sb, nb, it, g.sink, g.counts);
    }};

    using clock = std::chrono::steady_clock;
    const auto run_round{[&](int iters, uint64_t round) {
        for (int i = 0; i < count; ++i) {
            CHECK(cudaSetDevice(gpus[i].device));
            launch(gpus[i], uint64_t(i) << 40, round * 1'000'000ULL, iters);
            CHECK(cudaGetLastError());
        }
        for (int i = 0; i < count; ++i) {
            CHECK(cudaSetDevice(gpus[i].device));
            CHECK(cudaDeviceSynchronize());
        }
    }};
    std::vector<std::pair<int, int>> runs;
    if (args.list.empty()) {
        runs.emplace_back(args.partners, args.generate);
    } else {
        for (size_t pos = 0; pos < args.list.size();) {
            const size_t end{std::min(args.list.find(',', pos), args.list.size())};
            int m, gen;
            if (sscanf(args.list.substr(pos, end - pos).c_str(), "%d:%d", &m, &gen) != 2 || m < 0 || m + 1 > MAX_INPUTS) {
                fprintf(stderr, "bad --list item\n");
                return 2;
            }
            runs.emplace_back(m, gen);
            pos = end + 1;
        }
    }
    for (const auto& [run_m, run_gen] : runs) {
    for (auto& g : gpus) {
        g.data.partners = unsigned(run_m);
        g.data.generate = run_gen != 0;
    }
    int iters{1};
    {
        const auto t0{clock::now()};
        run_round(iters, 0);
        const double dt{std::chrono::duration<double>(clock::now() - t0).count()};
        iters = std::max(1, int(0.25 / std::max(dt, 1e-6)));
    }
    for (auto& g : gpus) {
        CHECK(cudaSetDevice(g.device));
        CHECK(cudaMemset(g.counts, 0, 2 * sizeof(unsigned long long)));
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
    unsigned long long reads{0}, generated{0};
    for (const auto& g : gpus) {
        CHECK(cudaSetDevice(g.device));
        unsigned long long c[2];
        CHECK(cudaMemcpy(c, g.counts, sizeof(c), cudaMemcpyDeviceToHost));
        reads += c[0];
        generated += c[1];
    }
    const double rate{double(total) / elapsed};
    printf("{\"kernel\":\"%s\",\"mode\":\"%s\",\"gpu\":\"%s\",\"gpus\":%d,\"partners\":%d,\"regen\":%.4f,\"generate\":%d,\"gib_per_gpu\":%.3f,"
           "\"chunks\":%" PRIu64 ",\"tpb\":%d,\"bpsm\":%d,\"seconds\":%.2f,\"attempts_per_s\":%.4e,\"chunk_reads_per_s\":%.4e,"
           "\"read_GBps\":%.1f,\"chunks_generated_per_s\":%.4e,\"reads_per_step\":%.3f,\"generated_per_step\":%.3f,\"fill_s\":%.2f}\n",
           args.kernel.c_str(), args.mode.c_str(), prop.name, count, run_m, args.regen, run_gen, double(shard_chunks * chunk_bytes) / double(1ULL << 30),
           n, args.tpb, args.bpsm, elapsed, rate, double(reads) / elapsed, double(reads) / elapsed * chunk_bytes / 1e9, double(generated) / elapsed,
           double(reads) / (double(total) * READS), double(generated) / (double(total) * READS), fill_s);
    fflush(stdout);

    if (!args.samples.empty()) {
        const std::string samples_path{runs.size() > 1 ? args.samples + "-m" + std::to_string(run_m) + "-g" + std::to_string(run_gen) : args.samples};
        // The timed kernel's output on the first GPU (tracing on) and the reference kernel's on the
        // same streams and nonces must agree; verify_pack.py recomputes the reference in Python.
        Gpu& g{gpus[0]};
        CHECK(cudaSetDevice(g.device));
        uint64_t* dtrace;
        CHECK(cudaMalloc(&dtrace, 128 * 32));
        const uint64_t threads{uint64_t(g.blocks) * args.tpb};
        const uint64_t stride{std::max<uint64_t>(1, threads / 128)};
        g.data.trace = dtrace;
        g.data.trace_stride = stride;
        const uint64_t nonce{round * 1'000'000ULL};
        launch(g, 0, nonce, 1);
        CHECK(cudaGetLastError());
        CHECK(cudaDeviceSynchronize());
        std::vector<uint64_t> traced(128 * 4), ref(128 * 4), st(128), no(128, nonce);
        CHECK(cudaMemcpy(traced.data(), dtrace, 128 * 32, cudaMemcpyDeviceToHost));
        for (int k = 0; k < 128; ++k) st[k] = uint64_t(k) * stride;
        uint64_t *dst, *dno, *dfin;
        CHECK(cudaMalloc(&dst, 128 * 8));
        CHECK(cudaMalloc(&dno, 128 * 8));
        CHECK(cudaMalloc(&dfin, 128 * 32));
        CHECK(cudaMemcpy(dst, st.data(), 128 * 8, cudaMemcpyHostToDevice));
        CHECK(cudaMemcpy(dno, no.data(), 128 * 8, cudaMemcpyHostToDevice));
        Data rd{g.data};
        rd.trace = nullptr;
        sample_kernel<<<2, 64>>>(rd, dst, dno, 128, dfin);
        CHECK(cudaGetLastError());
        CHECK(cudaDeviceSynchronize());
        CHECK(cudaMemcpy(ref.data(), dfin, 128 * 32, cudaMemcpyDeviceToHost));
        int agree{0};
        for (int k = 0; k < 128; ++k) agree += std::equal(&traced[4 * k], &traced[4 * k + 4], &ref[4 * k]);
        FILE* f{fopen(samples_path.c_str(), "w")};
        fprintf(f, "{\"n\":%" PRIu64 ",\"partners\":%d,\"regen_threshold\":%" PRIu64 ",\"reads\":%d,\"timed_equals_reference\":%d}\n",
                n, run_m, threshold, READS, agree);
        for (int k = 0; k < 128; ++k) {
            fprintf(f, "%" PRIu64 " %" PRIu64 " ", st[k], nonce);
            for (int j = 0; j < 4; ++j) {
                for (int b = 0; b < 8; ++b) fprintf(f, "%02x", unsigned(ref[4 * k + j] >> (8 * b)) & 0xff);
            }
            fprintf(f, "\n");
        }
        fclose(f);
        fprintf(stderr, "samples: timed kernel equals reference on %d of 128\n", agree);
    }
    }
    return 0;
}
