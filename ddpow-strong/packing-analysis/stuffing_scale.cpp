// Stuffing analysis at the real chain's scale (packing, BIP rule). Chunk counts of existing
// blocks from sampled sizes; future blocks: honest of HONEST_BYTES, stuffer blocks (probability h)
// of 977 regenerable chunks. Partners: m distinct positions in [0, first_b) from the 8-byte words
// of BLAKE2b-256(0x03 || id_b || LE32(u) || LE32(t)), reduced mod first_b, repeats skipped (all if
// first_b <= m). Prints the stuffer's speedup: single tier, and a fast tier of N/4 chunks at read
// cost c holding raw chunks (oldest first or most used by its regenerable chunks first) and
// packed chunks.
// g++ -O3 -march=native -std=c++17 -pthread -o scale scale.cpp
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static inline uint64_t splitmix64(uint64_t z)
{
    z += 0x9E3779B97F4A7C15ULL;
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

/** BLAKE2b-256(0x03 || id || LE32(u) || LE32(t)): 41 bytes, one compression. */
static inline void draw_hash(const uint64_t id[4], uint32_t u, uint32_t t, uint64_t out[4])
{
    unsigned char in[128] = {};
    in[0] = 0x03;
    std::memcpy(in + 1, id, 32);
    std::memcpy(in + 33, &u, 4);
    std::memcpy(in + 37, &t, 4);
    uint64_t m[16];
    std::memcpy(m, in, 128);
    uint64_t h[8];
    init256(h);
    compress(h, m, 41, true);
    for (int i = 0; i < 4; ++i) out[i] = h[i];
}

static int partners(const uint64_t id[4], uint32_t u, uint64_t first, int m, uint64_t* out)
{
    if (first == 0 || m == 0) return 0;
    if (first <= uint64_t(m)) {
        for (uint64_t p = 0; p < first; ++p) out[p] = p;
        return int(first);
    }
    int n = 0;
    for (uint32_t t = 0; n < m; ++t) {
        uint64_t e[4];
        draw_hash(id, u, t, e);
        for (int w = 0; w < 4 && n < m; ++w) {
            const uint64_t c = e[w] % first;
            bool dup = false;
            for (int k = 0; k < n; ++k) dup |= out[k] == c;
            if (!dup) out[n++] = c;
        }
    }
    return n;
}

struct Chain {
    std::vector<uint64_t> first;  // per block
    std::vector<uint32_t> count;
    std::vector<uint8_t> stuffer;
    uint64_t n{0};
    std::vector<uint64_t> regen_bits;
    bool regen(uint64_t p) const { return (regen_bits[p >> 6] >> (p & 63)) & 1; }
    void id(size_t b, uint64_t out[4]) const { for (int i = 0; i < 4; ++i) out[i] = splitmix64(b * 4 + i + 0x1D1D); }
};

struct Bits {
    std::vector<uint64_t> w;
    explicit Bits(uint64_t n) : w((n + 63) / 64) {}
    bool get(uint64_t p) const { return (w[p >> 6] >> (p & 63)) & 1; }
    void set(uint64_t p) { w[p >> 6] |= 1ULL << (p & 63); }
};

template <typename F>
static void parallel_blocks(const Chain& c, unsigned threads, F f)
{
    std::vector<std::thread> pool;
    std::atomic<size_t> next{0};
    for (unsigned t = 0; t < threads; ++t) {
        pool.emplace_back([&] {
            for (;;) {
                const size_t b0 = next.fetch_add(512);
                if (b0 >= c.first.size()) break;
                for (size_t b = b0; b < std::min(c.first.size(), b0 + 512); ++b) f(b);
            }
        });
    }
    for (auto& th : pool) th.join();
}

int main(int argc, char** argv)
{
    if (argc == 7 && std::string(argv[1]) == "test") {
        // test <id hex> <u> <first> <m> <unused>: the partner rule on a given id.
        uint64_t id[4];
        unsigned char bytes[32];
        for (int i = 0; i < 32; ++i) sscanf(argv[2] + 2 * i, "%2hhx", &bytes[i]);
        std::memcpy(id, bytes, 32);
        uint64_t part[64];
        const int k = partners(id, uint32_t(std::atoi(argv[3])), std::strtoull(argv[4], nullptr, 10), std::atoi(argv[5]), part);
        for (int i = 0; i < k; ++i) printf("%lu ", part[i]);
        printf("\n");
        return 0;
    }
    // scale <sizes file> <h> <years> <m> [honest bytes] [tip height]
    const char* sizes_path = argv[1];
    const double h = std::atof(argv[2]);
    const double years = std::atof(argv[3]);
    const int m = std::atoi(argv[4]);
    const double honest_bytes = argc > 5 ? std::atof(argv[5]) : 96273;
    const unsigned threads = std::thread::hardware_concurrency();

    std::vector<std::pair<uint64_t, uint64_t>> samples;
    FILE* f = fopen(sizes_path, "r");
    uint64_t hh, sz;
    while (fscanf(f, "%lu %lu", &hh, &sz) == 2) samples.emplace_back(hh, sz);
    fclose(f);
    std::sort(samples.begin(), samples.end());
    const uint64_t tip = argc > 6 ? std::strtoull(argv[6], nullptr, 10) : samples.back().first + 199;
    Chain c;
    size_t si = 0;
    for (uint64_t b = 0; b <= tip; ++b) {
        while (si + 1 < samples.size() && samples[si + 1].first <= b) ++si;
        const uint64_t bytes = std::max<uint64_t>(samples[si].second, 81);
        c.first.push_back(c.n);
        c.count.push_back(uint32_t((bytes + 4095) / 4096));
        c.stuffer.push_back(0);
        c.n += c.count.back();
    }
    const uint64_t existing_chunks = c.n;
    const uint64_t future = uint64_t(years * 52560);
    const uint32_t honest_chunks = uint32_t(std::ceil(honest_bytes / 4096));
    for (uint64_t i = 0; i < future; ++i) {
        const bool st = double(splitmix64(i ^ 0xBEEF) >> 11) / double(1ULL << 53) < h;
        c.first.push_back(c.n);
        c.count.push_back(st ? 977 : honest_chunks);
        c.stuffer.push_back(st);
        c.n += c.count.back();
    }
    c.regen_bits.assign((c.n + 63) / 64, 0);
    uint64_t regen_total = 0;
    for (size_t b = 0; b < c.first.size(); ++b) {
        if (!c.stuffer[b]) continue;
        for (uint32_t u = 0; u < c.count[b]; ++u) {
            const uint64_t p = c.first[b] + u;
            c.regen_bits[p >> 6] |= 1ULL << (p & 63);
        }
        regen_total += c.count[b];
    }
    const uint64_t N = c.n, H = N / 4;
    fprintf(stderr, "blocks %zu (existing %lu), chunks %lu (existing %lu), regenerable %lu (%.4f), m %d, h %.2f, years %.1f\n",
            c.first.size(), tip + 1, N, existing_chunks, regen_total, double(regen_total) / N, m, h, years);

    // Usage of non-regenerable chunks as partners of regenerable chunks (most-used strategy).
    std::vector<uint16_t> usage(N, 0);
    std::atomic<uint64_t> free_single{0};
    parallel_blocks(c, threads, [&](size_t b) {
        if (!c.stuffer[b]) return;
        uint64_t id[4], part[64];
        c.id(b, id);
        uint64_t local_free = 0;
        for (uint32_t u = 0; u < c.count[b]; ++u) {
            const int k = partners(id, u, c.first[b], m, part);
            bool all = true;
            for (int i = 0; i < k; ++i) {
                if (!c.regen(part[i])) {
                    all = false;
                    // Racy increments are tolerable for a ranking; saturate at 65535.
                    uint16_t& x = usage[part[i]];
                    if (x < 65535) ++x;
                }
            }
            local_free += all;
        }
        free_single += local_free;
    });
    printf("{\"h\":%.2f,\"years\":%.1f,\"m\":%d,\"chunks\":%lu,\"existing_chunks\":%lu,\"regen_share\":%.4f,\"single_tier\":%.6f",
           h, years, m, N, existing_chunks, double(regen_total) / N, double(N) / double(N - free_single.load()));
    fflush(stdout);

    // Non-regenerable positions, oldest first and most used first.
    std::vector<uint64_t> nonregen;
    nonregen.reserve(N - regen_total);
    for (uint64_t p = 0; p < N; ++p) if (!c.regen(p)) nonregen.push_back(p);
    std::vector<uint64_t> by_use(nonregen);
    std::stable_sort(by_use.begin(), by_use.end(), [&](uint64_t a, uint64_t b) { return usage[a] > usage[b]; });

    const double costs[3] = {0.0, 0.07, 0.15};
    double best[3] = {1e300, 1e300, 1e300};
    for (int strategy = 0; strategy < 2; ++strategy) {
        for (double frac : {0.0, 0.5, 1.0}) {
            if (strategy == 1 && frac == 0.0) continue;
            const uint64_t h1 = std::min<uint64_t>(uint64_t(H * frac), nonregen.size());
            Bits cached(N);
            const auto& order = strategy == 0 ? nonregen : by_use;
            for (uint64_t i = 0; i < h1; ++i) cached.set(order[i]);
            // Positions formable from regenerable and cached chunks, by number of cached reads.
            std::vector<std::atomic<uint64_t>> hist(66);
            parallel_blocks(c, threads, [&](size_t b) {
                uint64_t id[4], part[64];
                c.id(b, id);
                uint64_t local[66] = {};
                for (uint32_t u = 0; u < c.count[b]; ++u) {
                    const uint64_t p = c.first[b] + u;
                    const bool self_ok = c.regen(p) || cached.get(p);
                    if (!self_ok) { ++local[65]; continue; }
                    const int k = partners(id, u, c.first[b], m, part);
                    int reads = c.regen(p) ? 0 : 1;
                    bool ok = true;
                    for (int i = 0; i < k && ok; ++i) {
                        if (c.regen(part[i])) continue;
                        if (cached.get(part[i])) ++reads; else ok = false;
                    }
                    ++local[ok ? reads : 65];
                }
                for (int i = 0; i < 66; ++i) if (local[i]) hist[i] += local[i];
            });
            for (int ci = 0; ci < 3; ++ci) {
                const double cf = costs[ci];
                // Cost: formable positions at min(1, reads * c); the rest read packed, from the fast
                // tier's remaining H - h1 slots first (saving 1 - c each), then from storage.
                double cost = 0;
                uint64_t slow = hist[65].load();
                for (int r = 0; r <= 64; ++r) {
                    const double each = std::min(1.0, r * cf);
                    if (each >= 1.0) slow += hist[r].load(); else cost += each * double(hist[r].load());
                }
                const uint64_t fast = std::min<uint64_t>(slow, H - h1);
                cost += double(fast) * cf + double(slow - fast);
                best[ci] = std::min(best[ci], cost);
            }
        }
    }
    for (int ci = 0; ci < 3; ++ci) {
        const double honest = double(H) * costs[ci] + double(N - H);
        printf(",\"c=%.2f\":%.6f", costs[ci], honest / best[ci]);
    }
    printf("}\n");
    return 0;
}
