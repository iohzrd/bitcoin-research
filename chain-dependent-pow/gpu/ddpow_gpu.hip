#include <hip/hip_runtime.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <glob.h>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <type_traits>
#include <vector>

typedef uint64_t u64;
typedef uint32_t u32;

#define CHECK(x)                                                                                   \
    do {                                                                                           \
        hipError_t e_ = (x);                                                                       \
        if (e_ != hipSuccess) {                                                                    \
            fprintf(stderr, "%s:%d %s: %s\n", __FILE__, __LINE__, #x, hipGetErrorString(e_));     \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

#define IV0 0x6a09e667f3bcc908ULL
#define IV1 0xbb67ae8584caa73bULL
#define IV2 0x3c6ef372fe94f82bULL
#define IV3 0xa54ff53a5f1d36f1ULL
#define IV4 0x510e527fade682d1ULL
#define IV5 0x9b05688c2b3e6c1fULL
#define IV6 0x1f83d9abfb41bd6bULL
#define IV7 0x5be0cd19137e2179ULL
#define PARAM0 0x01010020ULL

constexpr u64 PARENT_BYTES = 4ULL << 20;

__host__ __device__ constexpr int sig(int r, int i) {
    constexpr unsigned char S[10][16] = {
        {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
        {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
        {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
        {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
        {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
        {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
        {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
        {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
        {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    };
    return S[r % 10][i];
}

template <int R>
__device__ __forceinline__ u64 rotr(u64 x) {
    u32 lo = (u32)x;
    u32 hi = (u32)(x >> 32);
    if constexpr (R == 32) {
        return ((u64)lo << 32) | hi;
    } else if constexpr (R < 32) {
        u32 nlo = __builtin_amdgcn_alignbit(hi, lo, R);
        u32 nhi = __builtin_amdgcn_alignbit(lo, hi, R);
        return ((u64)nhi << 32) | nlo;
    } else {
        u32 nlo = __builtin_amdgcn_alignbit(lo, hi, R - 32);
        u32 nhi = __builtin_amdgcn_alignbit(hi, lo, R - 32);
        return ((u64)nhi << 32) | nlo;
    }
}

__device__ __forceinline__ void G(u64 &a, u64 &b, u64 &c, u64 &d, u64 x, u64 y) {
    a = a + b + x;
    d = rotr<32>(d ^ a);
    c = c + d;
    b = rotr<24>(b ^ c);
    a = a + b + y;
    d = rotr<16>(d ^ a);
    c = c + d;
    b = rotr<63>(b ^ c);
}

template <int R>
__device__ __forceinline__ void round_(u64 v[16], const u64 m[16]) {
    constexpr int s0 = sig(R, 0), s1 = sig(R, 1), s2 = sig(R, 2), s3 = sig(R, 3);
    constexpr int s4 = sig(R, 4), s5 = sig(R, 5), s6 = sig(R, 6), s7 = sig(R, 7);
    constexpr int s8 = sig(R, 8), s9 = sig(R, 9), s10 = sig(R, 10), s11 = sig(R, 11);
    constexpr int s12 = sig(R, 12), s13 = sig(R, 13), s14 = sig(R, 14), s15 = sig(R, 15);
    G(v[0], v[4], v[8], v[12], m[s0], m[s1]);
    G(v[1], v[5], v[9], v[13], m[s2], m[s3]);
    G(v[2], v[6], v[10], v[14], m[s4], m[s5]);
    G(v[3], v[7], v[11], v[15], m[s6], m[s7]);
    G(v[0], v[5], v[10], v[15], m[s8], m[s9]);
    G(v[1], v[6], v[11], v[12], m[s10], m[s11]);
    G(v[2], v[7], v[8], v[13], m[s12], m[s13]);
    G(v[3], v[4], v[9], v[14], m[s14], m[s15]);
}

__device__ __forceinline__ void blake2b256(const u64 m[16], u64 len, u64 out[4]) {
    u64 v[16] = {IV0 ^ PARAM0, IV1, IV2, IV3, IV4, IV5, IV6, IV7,
                 IV0, IV1, IV2, IV3, IV4 ^ len, IV5, ~IV6, IV7};
    round_<0>(v, m);
    round_<1>(v, m);
    round_<2>(v, m);
    round_<3>(v, m);
    round_<4>(v, m);
    round_<5>(v, m);
    round_<6>(v, m);
    round_<7>(v, m);
    round_<8>(v, m);
    round_<9>(v, m);
    round_<10>(v, m);
    round_<11>(v, m);
    out[0] = IV0 ^ PARAM0 ^ v[0] ^ v[8];
    out[1] = IV1 ^ v[1] ^ v[9];
    out[2] = IV2 ^ v[2] ^ v[10];
    out[3] = IV3 ^ v[3] ^ v[11];
}

__device__ __forceinline__ void compress(u64 h[8], const u64 m[16], u64 t, bool last) {
    u64 v[16] = {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                 IV0, IV1, IV2, IV3, IV4 ^ t, IV5, last ? ~IV6 : IV6, IV7};
    round_<0>(v, m);
    round_<1>(v, m);
    round_<2>(v, m);
    round_<3>(v, m);
    round_<4>(v, m);
    round_<5>(v, m);
    round_<6>(v, m);
    round_<7>(v, m);
    round_<8>(v, m);
    round_<9>(v, m);
    round_<10>(v, m);
    round_<11>(v, m);
#pragma unroll
    for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
}

__host__ __device__ inline u64 splitmix64(u64 z) {
    z += 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

__device__ __forceinline__ u64 reduce(u64 x, u64 n, u64 inv) {
    u64 q = __umul64hi(x, inv);
    u64 r = x - q * n;
    if (r >= n) r -= n;
    if (r >= n) r -= n;
    return r;
}

__device__ __forceinline__ u64 opaque(u64 v) {
    asm volatile("" : "+v"(v));
    return v;
}

struct Sample {
    u64 stream;
    u64 nonce;
    u64 final_[4];
};

struct Dataset {
    const uint4 *data;
    u64 n;
    u64 s;
    u64 inv_n;
    u64 ns;
    u64 inv_ns;
};

__device__ __forceinline__ void header_hash(u64 stream, u64 nonce, u64 out[4]) {
    u64 m[16] = {stream, nonce, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    blake2b256(m, 80, out);
}

__device__ __forceinline__ u64 word(uint4 c, int half) {
    return half ? ((u64)c.w << 32) | c.z : ((u64)c.y << 32) | c.x;
}

__device__ __forceinline__ void record(Sample *samples, u64 slot, u64 stream, u64 nonce, const u64 x[4]) {
    Sample &o = samples[slot];
    o.stream = stream;
    o.nonce = nonce;
    o.final_[0] = x[0];
    o.final_[1] = x[1];
    o.final_[2] = x[2];
    o.final_[3] = x[3];
}

__global__ void __launch_bounds__(256) k_fill(u64 *d, u64 words) {
    u64 stride = (u64)gridDim.x * blockDim.x;
    for (u64 i = (u64)blockIdx.x * blockDim.x + threadIdx.x; i < words; i += stride) d[i] = splitmix64(i);
}

__global__ void __launch_bounds__(256) k_hash(u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    bool sampled = samples && (tid % stride == 0);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        u64 nonce = opaque(base + it);
        u64 h[4];
        header_hash(tid, nonce, h);
        acc ^= h[0];
        if (sampled && (it == 0 || it == iters - 1)) record(samples, (tid / stride) * 2 + (it != 0), tid, nonce, h);
    }
    fold[tid] = acc;
}

template <int L, int N, class F>
__device__ __forceinline__ void each(F &&f) {
    if constexpr (L < N) {
        f(std::integral_constant<int, L>{});
        each<L + 1, N>(f);
    }
}

template <int ILP>
__global__ void __launch_bounds__(256) k_attempt(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    bool sampled = samples && (tid % stride == 0);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        u64 nonce = opaque(base + it);
        u64 x[ILP][4];
        u64 a[ILP];
        each<0, ILP>([&](auto l) {
            header_hash(tid * ILP + l, nonce, x[l]);
            a[l] = ds.s + reduce(x[l][0], ds.ns, ds.inv_ns);
        });
#pragma unroll 1
        for (int i = 0; i < 8; i++) {
            uint4 c[ILP][4];
            each<0, ILP>([&](auto l) {
                const uint4 *p = ds.data + a[l] * 4;
                c[l][0] = p[0];
                c[l][1] = p[1];
                c[l][2] = p[2];
                c[l][3] = p[3];
            });
            each<0, ILP>([&](auto l) {
                u64 m[16] = {x[l][0], x[l][1], x[l][2], x[l][3],
                             word(c[l][0], 0), word(c[l][0], 1), word(c[l][1], 0), word(c[l][1], 1),
                             word(c[l][2], 0), word(c[l][2], 1), word(c[l][3], 0), word(c[l][3], 1),
                             0, 0, 0, 0};
                blake2b256(m, 96, x[l]);
                a[l] = reduce(x[l][0], ds.n, ds.inv_n);
            });
        }
        each<0, ILP>([&](auto l) {
            acc ^= x[l][0];
            if (sampled && (it == 0 || it == iters - 1))
                record(samples, ((tid / stride) * ILP + l) * 2 + (it != 0), tid * ILP + l, nonce, x[l]);
        });
    }
    fold[tid] = acc;
}

template <int W>
__global__ void __launch_bounds__(256) k_probe(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *, u32) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    u64 a = reduce(splitmix64(tid ^ (base << 32)), ds.n, ds.inv_n);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        const uint4 *p = ds.data + a * 4;
        uint4 c0 = p[0];
        u64 w = word(c0, 0) ^ word(c0, 1);
        if constexpr (W >= 2) {
            uint4 c1 = p[1];
            w ^= word(c1, 0) ^ word(c1, 1);
        }
        if constexpr (W >= 4) {
            uint4 c2 = p[2];
            uint4 c3 = p[3];
            w ^= word(c2, 0) ^ word(c2, 1) ^ word(c3, 0) ^ word(c3, 1);
        }
        acc ^= w;
        a = reduce(splitmix64(w ^ it ^ (tid << 40)), ds.n, ds.inv_n);
    }
    fold[tid] = acc;
}

__global__ void __launch_bounds__(256) k_seq(Dataset ds, u64, u64 iters, u64 *fold, Sample *, u32) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    u64 stride = (u64)gridDim.x * blockDim.x;
    u64 vecs = ds.n * 4;
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++)
        for (u64 i = tid; i < vecs; i += stride) {
            uint4 c = ds.data[i];
            acc ^= word(c, 0) ^ word(c, 1) ^ it;
        }
    fold[tid] = acc;
}

constexpr int STEP_BLOCKS = 33;
constexpr u64 STEP_BYTES = 32 + 4096;
constexpr int CHUNK_VECS = 256;

__device__ __forceinline__ void h_init(u64 h[8]) {
    h[0] = IV0 ^ PARAM0;
    h[1] = IV1;
    h[2] = IV2;
    h[3] = IV3;
    h[4] = IV4;
    h[5] = IV5;
    h[6] = IV6;
    h[7] = IV7;
}

__device__ __forceinline__ u64 block_counter(int b) {
    return b == STEP_BLOCKS - 1 ? STEP_BYTES : 128ULL * (b + 1);
}

__device__ __forceinline__ void load_block(uint4 q[8], const uint4 *p, int b) {
#pragma unroll
    for (int k = 0; k < 8; k++) {
        int idx = 8 * b - 2 + k;
        q[k] = (idx >= 0 && idx < CHUNK_VECS) ? p[idx] : make_uint4(0, 0, 0, 0);
    }
}

__device__ __forceinline__ void block_message(u64 m[16], const uint4 q[8], const u64 x[4], int b) {
#pragma unroll
    for (int k = 0; k < 8; k++) {
        m[2 * k] = word(q[k], 0);
        m[2 * k + 1] = word(q[k], 1);
    }
    if (b == 0) {
        m[0] = x[0];
        m[1] = x[1];
        m[2] = x[2];
        m[3] = x[3];
    }
}

__device__ __forceinline__ void step4k_stream(u64 x[4], const uint4 *p) {
    u64 h[8];
    h_init(h);
    uint4 q[8];
    load_block(q, p, 0);
#pragma unroll 1
    for (int b = 0; b < STEP_BLOCKS; b++) {
        u64 m[16];
        block_message(m, q, x, b);
        if (b + 1 < STEP_BLOCKS) load_block(q, p, b + 1);
        compress(h, m, block_counter(b), b == STEP_BLOCKS - 1);
    }
    x[0] = h[0];
    x[1] = h[1];
    x[2] = h[2];
    x[3] = h[3];
}

__device__ __forceinline__ void step4k_synthetic(u64 x[4]) {
    u64 h[8];
    h_init(h);
#pragma unroll 1
    for (int b = 0; b < STEP_BLOCKS; b++) {
        u64 m[16];
#pragma unroll
        for (int w = 0; w < 16; w++) {
            long g = 16L * b + w;
            u64 j = (u64)(g - 4);
            m[w] = g < 4 ? x[w] : (g - 4 < 512 ? x[w & 3] + j : 0);
        }
        compress(h, m, block_counter(b), b == STEP_BLOCKS - 1);
    }
    x[0] = h[0];
    x[1] = h[1];
    x[2] = h[2];
    x[3] = h[3];
}

__global__ void __launch_bounds__(256) k_step(Dataset, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    bool sampled = samples && (tid % stride == 0);
    u64 x[4];
    header_hash(tid, opaque(base), x);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        step4k_synthetic(x);
        acc ^= x[0];
        if (sampled && it < 2) record(samples, (tid / stride) * 2 + it, tid, it, x);
    }
    fold[tid] = acc;
}

__global__ void __launch_bounds__(256) k_attempt4k_stream(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    bool sampled = samples && (tid % stride == 0);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        u64 nonce = opaque(base + it);
        u64 x[4];
        header_hash(tid, nonce, x);
        u64 a = ds.s + reduce(x[0], ds.ns, ds.inv_ns);
#pragma unroll 1
        for (int i = 0; i < 8; i++) {
            step4k_stream(x, ds.data + a * CHUNK_VECS);
            a = reduce(x[0], ds.n, ds.inv_n);
        }
        acc ^= x[0];
        if (sampled && (it == 0 || it == iters - 1)) record(samples, (tid / stride) * 2 + (it != 0), tid, nonce, x);
    }
    fold[tid] = acc;
}

template <int SB>
__global__ void __launch_bounds__(256) k_attempt4k_coop(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    extern __shared__ uint4 lds[];
    constexpr int PER = 8 * SB;
    constexpr int PITCH = PER + 1;
    u32 lane = threadIdx.x & 31;
    uint4 *wbuf = lds + (threadIdx.x >> 5) * 32 * PITCH;
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    bool sampled = samples && (tid % stride == 0);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        u64 nonce = opaque(base + it);
        u64 x[4];
        header_hash(tid, nonce, x);
        u64 a = ds.s + reduce(x[0], ds.ns, ds.inv_ns);
#pragma unroll 1
        for (int i = 0; i < 8; i++) {
            u64 h[8];
            h_init(h);
#pragma unroll 1
            for (int b0 = 0; b0 < STEP_BLOCKS; b0 += SB) {
                __syncthreads();
#pragma unroll
                for (int r = 0; r < PER; r++) {
                    int e = lane + 32 * r;
                    int o = e / PER;
                    int off = e % PER;
                    u64 ao = __shfl(a, o, 32);
                    int idx = 8 * b0 - 2 + off;
                    uint4 v = make_uint4(0, 0, 0, 0);
                    if (idx >= 0 && idx < CHUNK_VECS) v = ds.data[ao * CHUNK_VECS + idx];
                    wbuf[o * PITCH + off] = v;
                }
                __syncthreads();
#pragma unroll 1
                for (int k = 0; k < SB; k++) {
                    int b = b0 + k;
                    uint4 q[8];
#pragma unroll
                    for (int j = 0; j < 8; j++) q[j] = wbuf[lane * PITCH + 8 * k + j];
                    u64 m[16];
                    block_message(m, q, x, b);
                    compress(h, m, block_counter(b), b == STEP_BLOCKS - 1);
                }
            }
            x[0] = h[0];
            x[1] = h[1];
            x[2] = h[2];
            x[3] = h[3];
            a = reduce(x[0], ds.n, ds.inv_n);
        }
        acc ^= x[0];
        if (sampled && (it == 0 || it == iters - 1)) record(samples, (tid / stride) * 2 + (it != 0), tid, nonce, x);
    }
    fold[tid] = acc;
}

__global__ void __launch_bounds__(256) k_probe4k(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *, u32) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    u64 a = reduce(splitmix64(tid ^ (base << 32)), ds.n, ds.inv_n);
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        const uint4 *p = ds.data + a * CHUNK_VECS;
        u64 w = 0;
#pragma unroll 16
        for (int k = 0; k < CHUNK_VECS; k++) {
            uint4 c = p[k];
            w ^= word(c, 0) ^ word(c, 1);
        }
        acc ^= w;
        a = reduce(splitmix64(w ^ it ^ (tid << 40)), ds.n, ds.inv_n);
    }
    fold[tid] = acc;
}

__global__ void __launch_bounds__(256) k_probe4k_coop(Dataset ds, u64 base, u64 iters, u64 *fold, Sample *, u32) {
    u64 tid = (u64)blockIdx.x * blockDim.x + threadIdx.x;
    u32 lane = threadIdx.x & 31;
    u64 acc = 0;
#pragma unroll 1
    for (u64 it = 0; it < iters; it++) {
        u64 a = reduce(splitmix64((tid << 24) ^ (base + it)), ds.n, ds.inv_n);
#pragma unroll 1
        for (int o = 0; o < 32; o++) {
            const uint4 *p = ds.data + __shfl(a, o, 32) * CHUNK_VECS;
#pragma unroll
            for (int r = 0; r < CHUNK_VECS / 32; r++) {
                uint4 c = p[lane + 32 * r];
                acc ^= word(c, 0) ^ word(c, 1);
            }
        }
    }
    fold[tid] = acc;
}

struct Args {
    std::string mode = "dev";
    double gib = 4;
    int tpb = 256;
    int bpcu = 4;
    int ilp = 1;
    double seconds = 12;
    double launch_ms = 400;
    std::string samples;
    int coherent = 1;
    int alloc = 0;
    std::string kernel = "attempt";
    int width = 4;
    int chunk = 64;
    std::string impl = "stream";
    int sb = 1;
};

static Args parse(int argc, char **argv) {
    Args a;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--mode") a.mode = v;
        else if (k == "--gib") a.gib = atof(v.c_str());
        else if (k == "--tpb") a.tpb = atoi(v.c_str());
        else if (k == "--bpcu") a.bpcu = atoi(v.c_str());
        else if (k == "--ilp") a.ilp = atoi(v.c_str());
        else if (k == "--seconds") a.seconds = atof(v.c_str());
        else if (k == "--launch-ms") a.launch_ms = atof(v.c_str());
        else if (k == "--samples") a.samples = v;
        else if (k == "--coherent") a.coherent = atoi(v.c_str());
        else if (k == "--alloc") a.alloc = atoi(v.c_str());
        else if (k == "--kernel") a.kernel = v;
        else if (k == "--width") a.width = atoi(v.c_str());
        else if (k == "--chunk") a.chunk = atoi(v.c_str());
        else if (k == "--impl") a.impl = v;
        else if (k == "--sb") a.sb = atoi(v.c_str());
        else {
            fprintf(stderr, "unknown argument %s\n", k.c_str());
            exit(2);
        }
    }
    return a;
}

struct Sensors {
    std::string dir;
    std::atomic<bool> stop{false};
    std::vector<double> watts, sclk, mclk;
    std::thread th;

    static double read_num(const std::string &p) {
        FILE *f = fopen(p.c_str(), "r");
        if (!f) return -1;
        double v = -1;
        if (fscanf(f, "%lf", &v) != 1) v = -1;
        fclose(f);
        return v;
    }

    void start() {
        glob_t g;
        if (glob("/sys/class/drm/card*/device/hwmon/hwmon*/power1_average", 0, nullptr, &g) == 0 && g.gl_pathc > 0) {
            dir = g.gl_pathv[0];
            dir = dir.substr(0, dir.rfind('/'));
        }
        globfree(&g);
        if (dir.empty()) return;
        th = std::thread([this] {
            while (!stop.load()) {
                watts.push_back(read_num(dir + "/power1_average") / 1e6);
                sclk.push_back(read_num(dir + "/freq1_input") / 1e6);
                mclk.push_back(read_num(dir + "/freq2_input") / 1e6);
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
            }
        });
    }

    void finish() {
        stop = true;
        if (th.joinable()) th.join();
    }

    static double mean_tail(const std::vector<double> &v) {
        if (v.size() < 4) return -1;
        double s = 0;
        size_t from = v.size() / 4;
        for (size_t i = from; i < v.size(); i++) s += v[i];
        return s / (v.size() - from);
    }
};

typedef void (*Launcher)(const Args &, const Dataset &, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride);

template <int ILP>
static void launch_attempt(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_attempt<ILP>, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static void launch_hash(const Args &a, const Dataset &, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_hash, dim3(blocks), dim3(a.tpb), 0, 0, base, iters, fold, samples, stride);
}

struct Variant {
    const char *mode;
    int ilp;
    const void *kernel;
    Launcher go;
};

#define AV(L) {"attempt", L, (const void *)k_attempt<L>, launch_attempt<L>}

static const Variant VARIANTS[] = {
    {"hash", 1, (const void *)k_hash, launch_hash},
    AV(1), AV(2), AV(4), AV(8),
};

template <int W>
static void launch_probe(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_probe<W>, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static void launch_seq(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_seq, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static const Variant DIAG[] = {
    {"probe", 1, (const void *)k_probe<1>, launch_probe<1>},
    {"probe", 2, (const void *)k_probe<2>, launch_probe<2>},
    {"probe", 4, (const void *)k_probe<4>, launch_probe<4>},
    {"seq", 4, (const void *)k_seq, launch_seq},
};

static void launch_step(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_step, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static void launch_4k_stream(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_attempt4k_stream, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static size_t coop_lds(const Args &a) {
    return (size_t)a.tpb * (8 * a.sb + 1) * sizeof(uint4);
}

template <int SB>
static void launch_4k_coop(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_attempt4k_coop<SB>, dim3(blocks), dim3(a.tpb), coop_lds(a), 0, ds, base, iters, fold, samples, stride);
}

static void launch_probe4k(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_probe4k, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static void launch_probe4k_coop(const Args &a, const Dataset &ds, int blocks, u64 base, u64 iters, u64 *fold, Sample *samples, u32 stride) {
    hipLaunchKernelGGL(k_probe4k_coop, dim3(blocks), dim3(a.tpb), 0, 0, ds, base, iters, fold, samples, stride);
}

static const Variant CHUNK4K[] = {
    {"step", 1, (const void *)k_step, launch_step},
    {"stream", 1, (const void *)k_attempt4k_stream, launch_4k_stream},
    {"coop", 1, (const void *)k_attempt4k_coop<1>, launch_4k_coop<1>},
    {"coop", 3, (const void *)k_attempt4k_coop<3>, launch_4k_coop<3>},
    {"probe", 1, (const void *)k_probe4k, launch_probe4k},
    {"probe-coop", 1, (const void *)k_probe4k_coop, launch_probe4k_coop},
};

static const Variant &variant4k(const Args &a) {
    const char *want = a.mode == "hash" ? "step" : a.kernel == "probe" ? (a.impl == "coop" ? "probe-coop" : "probe") : a.impl.c_str();
    int sb = strcmp(want, "coop") == 0 ? a.sb : 1;
    for (const Variant &v : CHUNK4K)
        if (strcmp(v.mode, want) == 0 && v.ilp == sb) return v;
    fprintf(stderr, "chunk 4096: kernel attempt (impl stream, coop with sb 1 or 3) or probe (impl stream or coop)\n");
    exit(2);
}

static const Variant &variant(const Args &a) {
    if (a.chunk == 4096) return variant4k(a);
    if (a.kernel != "attempt") {
        for (const Variant &v : DIAG)
            if (a.kernel == v.mode && (a.kernel == "seq" || v.ilp == a.width)) return v;
        fprintf(stderr, "kernel must be attempt, probe (width 1, 2, 4) or seq\n");
        exit(2);
    }
    const char *m = a.mode == "hash" ? "hash" : "attempt";
    for (const Variant &v : VARIANTS)
        if (strcmp(v.mode, m) == 0 && v.ilp == a.ilp) return v;
    fprintf(stderr, "ilp must be 1, 2, 4 or 8\n");
    exit(2);
}

int main(int argc, char **argv) {
    Args a = parse(argc, argv);
    if (a.mode != "hash" && a.mode != "dev" && a.mode != "host") {
        fprintf(stderr, "mode must be hash, dev or host\n");
        return 2;
    }
    if (a.mode == "hash") a.ilp = 1;
    if (a.kernel != "attempt") a.ilp = 1;
    if (a.chunk != 64 && a.chunk != 4096) {
        fprintf(stderr, "chunk must be 64 or 4096\n");
        return 2;
    }
    if (a.chunk == 4096) a.ilp = 1;
    if (a.kernel != "attempt" && a.mode == "hash") {
        fprintf(stderr, "probe and seq kernels need mode dev or host\n");
        return 2;
    }
    const Variant &kv = variant(a);

    hipDeviceProp_t prop;
    CHECK(hipGetDeviceProperties(&prop, 0));
    int cus = prop.multiProcessorCount;
    int blocks = cus * a.bpcu;
    u64 threads = (u64)blocks * a.tpb;
    u64 streams = threads * a.ilp;

    int active = 0;
    size_t lds_bytes = (a.chunk == 4096 && a.impl == "coop" && a.kernel == "attempt" && a.mode != "hash") ? coop_lds(a) : 0;
    CHECK(hipOccupancyMaxActiveBlocksPerMultiprocessor(&active, kv.kernel, a.tpb, lds_bytes));
    hipFuncAttributes attr;
    CHECK(hipFuncGetAttributes(&attr, kv.kernel));

    Dataset ds{};
    void *host_buf = nullptr;
    void *dev_buf = nullptr;
    bool registered = false;
    u64 bytes = 0;
    if (a.mode != "hash") {
        bytes = (u64)(a.gib * (double)(1ULL << 30)) / a.chunk * a.chunk;
        u64 n = bytes / a.chunk;
        u64 *dptr = nullptr;
        if (a.mode == "dev") {
            CHECK(hipMalloc(&dev_buf, bytes));
            dptr = (u64 *)dev_buf;
        } else if (a.alloc == 0) {
            unsigned flags = hipHostMallocMapped | (a.coherent ? hipHostMallocCoherent : hipHostMallocNonCoherent);
            CHECK(hipHostMalloc(&host_buf, bytes, flags));
            CHECK(hipHostGetDevicePointer((void **)&dptr, host_buf, 0));
        } else {
            host_buf = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
            if (host_buf == MAP_FAILED) {
                perror("mmap");
                return 1;
            }
            CHECK(hipHostRegister(host_buf, bytes, hipHostRegisterMapped));
            registered = true;
            CHECK(hipHostGetDevicePointer((void **)&dptr, host_buf, 0));
        }
        hipLaunchKernelGGL(k_fill, dim3(cus * 32), dim3(256), 0, 0, dptr, bytes / 8);
        CHECK(hipDeviceSynchronize());
        ds.data = (const uint4 *)dptr;
        ds.n = n;
        u64 parent = PARENT_BYTES / a.chunk;
        ds.s = n - (parent < n ? parent : n);
        ds.ns = n - ds.s;
        ds.inv_n = ~0ULL / ds.n;
        ds.inv_ns = ~0ULL / ds.ns;
    }

    u64 *fold;
    CHECK(hipMalloc(&fold, threads * 8));
    u32 stride = (u32)(threads / 64);
    if (stride == 0) stride = 1;
    u64 nsamples = ((threads + stride - 1) / stride) * a.ilp * 2;
    Sample *samples;
    CHECK(hipMalloc(&samples, nsamples * sizeof(Sample)));
    CHECK(hipMemset(samples, 0, nsamples * sizeof(Sample)));

    Launcher go = kv.go;
    hipEvent_t e0, e1;
    CHECK(hipEventCreate(&e0));
    CHECK(hipEventCreate(&e1));

    u64 iters = 4;
    float ms = 0;
    for (int rep = 0; rep < 3; rep++) {
        CHECK(hipEventRecord(e0));
        go(a, ds, blocks, 0, iters, fold, nullptr, stride);
        CHECK(hipEventRecord(e1));
        CHECK(hipEventSynchronize(e1));
        CHECK(hipGetLastError());
        CHECK(hipEventElapsedTime(&ms, e0, e1));
        if (ms < a.launch_ms / 8) iters = (u64)(iters * (a.launch_ms / 8) / (ms > 0.01 ? ms : 0.01)) + 1;
    }
    iters = (u64)(iters * a.launch_ms / ms);
    if (iters < 2) iters = 2;

    Sensors sensors;
    sensors.start();
    u64 launches = 0;
    auto wall0 = std::chrono::steady_clock::now();
    CHECK(hipEventRecord(e0));
    do {
        go(a, ds, blocks, launches * iters, iters, fold, launches == 0 ? samples : nullptr, stride);
        launches++;
        CHECK(hipDeviceSynchronize());
    } while (std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count() < a.seconds);
    CHECK(hipEventRecord(e1));
    CHECK(hipEventSynchronize(e1));
    CHECK(hipGetLastError());
    sensors.finish();
    CHECK(hipEventElapsedTime(&ms, e0, e1));

    std::vector<u64> hfold(threads);
    CHECK(hipMemcpy(hfold.data(), fold, threads * 8, hipMemcpyDeviceToHost));
    u64 xr = 0;
    for (u64 v : hfold) xr ^= v;

    std::vector<Sample> hs(nsamples);
    CHECK(hipMemcpy(hs.data(), samples, nsamples * sizeof(Sample), hipMemcpyDeviceToHost));
    if (!a.samples.empty()) {
        FILE *f = fopen(a.samples.c_str(), "wb");
        u64 kind = a.chunk == 64 ? (a.mode == "hash" ? 0ULL : 1ULL) : (a.mode == "hash" ? 3ULL : 2ULL);
        u64 hdr[4] = {kind, ds.n, ds.s, nsamples};
        fwrite(hdr, 8, 4, f);
        fwrite(hs.data(), sizeof(Sample), nsamples, f);
        fclose(f);
    }

    double secs = ms / 1000.0;
    double total = (double)streams * iters * launches;
    double rate = total / secs;
    double reads = a.mode == "hash" ? 0 : a.kernel == "attempt" ? rate * 8 : a.kernel == "probe" ? rate : (double)iters * launches * ds.n / secs;
    double read_bytes = a.chunk == 4096 ? 4096.0 : a.kernel == "probe" ? 16.0 * a.width : 64.0;
    double per_unit = a.kernel != "attempt" ? 0 : a.chunk == 64 ? (a.mode == "hash" ? 1 : 9) : (a.mode == "hash" ? STEP_BLOCKS : 1 + 8 * STEP_BLOCKS);
    printf("gpu=%s cus=%d mode=%s gib=%.2f n=%llu tpb=%d bpcu=%d ilp=%d blocks=%d threads=%llu streams=%llu "
           "vgpr_regs=%d occ_blocks_per_cu=%d iters=%llu launches=%llu seconds=%.3f attempts=%.0f "
           "rate=%.4e reads_per_s=%.4e bytes_per_s=%.4e avg_w=%.1f avg_sclk_mhz=%.0f avg_mclk_mhz=%.0f fold=%016llx "
           "samples=%llu coherent=%d alloc=%d scratch=%zu kernel=%s width=%d chunk=%d impl=%s sb=%d lds=%zu compress_per_s=%.4e\n",
           prop.name, cus, a.mode.c_str(), a.gib, (unsigned long long)ds.n, a.tpb, a.bpcu, a.ilp, blocks,
           (unsigned long long)threads, (unsigned long long)streams, attr.numRegs, active, (unsigned long long)iters,
           (unsigned long long)launches, secs, total, rate, reads, reads * read_bytes, Sensors::mean_tail(sensors.watts),
           Sensors::mean_tail(sensors.sclk), Sensors::mean_tail(sensors.mclk), (unsigned long long)xr,
           (unsigned long long)nsamples, a.coherent, a.alloc, (size_t)attr.localSizeBytes, a.kernel.c_str(), a.width, a.chunk, a.impl.c_str(), a.sb, lds_bytes, rate * per_unit);

    if (dev_buf) CHECK(hipFree(dev_buf));
    if (host_buf && !registered) CHECK(hipHostFree(host_buf));
    if (registered) {
        CHECK(hipHostUnregister(host_buf));
        munmap(host_buf, bytes);
    }
    return 0;
}
