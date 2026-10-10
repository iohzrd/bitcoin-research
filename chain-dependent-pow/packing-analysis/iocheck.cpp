// Block-check read pattern on a drive: per block, 8 rounds of up to 8 random 4 KiB reads issued
// together (O_DIRECT), rounds serial. Mode 1: one checker. Mode 2: P checkers in parallel.
#include <fcntl.h>
#include <unistd.h>
#include <atomic>
#include <barrier>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>
#include <vector>
static constexpr size_t CHUNK = 4096;
int main(int argc, char** argv)
{
    const char* path = argv[1];
    const uint64_t gib = std::strtoull(argv[2], nullptr, 10);
    const int checkers = std::atoi(argv[3]);
    const double seconds = std::atof(argv[4]);
    const int reads_per_round = argc > 5 ? std::atoi(argv[5]) : 8;
    const uint64_t chunks = gib * (1ULL << 30) / CHUNK;
    if (access(path, F_OK) != 0) {
        int fd = open(path, O_WRONLY | O_CREAT, 0644);
        std::vector<char> buf(64 << 20);
        std::mt19937_64 rng(1);
        for (auto& c : buf) c = char(rng());
        for (uint64_t w = 0; w < gib * 16; ++w) if (write(fd, buf.data(), buf.size()) != ssize_t(buf.size())) { perror("write"); return 1; }
        fsync(fd);
        close(fd);
    }
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> blocks{0};
    std::vector<std::thread> pool;
    for (int c = 0; c < checkers; ++c) {
        pool.emplace_back([&, c] {
            const int fd = open(path, O_RDONLY | O_DIRECT);
            if (fd < 0) { perror("open"); exit(1); }
            std::barrier sync(reads_per_round + 1);
            std::vector<uint64_t> pos(reads_per_round);
            std::atomic<bool> done{false};
            std::vector<std::thread> readers;
            for (int r = 0; r < reads_per_round; ++r) {
                readers.emplace_back([&, r] {
                    void* buf;
                    posix_memalign(&buf, CHUNK, CHUNK);
                    while (true) {
                        sync.arrive_and_wait();
                        if (done) break;
                        if (pread(fd, buf, CHUNK, pos[r] * CHUNK) != ssize_t(CHUNK)) { perror("pread"); exit(1); }
                        sync.arrive_and_wait();
                    }
                    free(buf);
                });
            }
            std::mt19937_64 rng(1000 + c);
            uint64_t local = 0;
            while (!stop) {
                for (int round = 0; round < 8; ++round) {
                    for (auto& p : pos) p = rng() % chunks;
                    sync.arrive_and_wait();
                    sync.arrive_and_wait();
                }
                ++local;
            }
            done = true;
            sync.arrive_and_wait();
            for (auto& t : readers) t.join();
            close(fd);
            blocks += local;
        });
    }
    const auto t0 = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
    stop = true;
    for (auto& t : pool) t.join();
    const double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    const double bps = blocks / el;
    printf("{\"checkers\":%d,\"reads_per_round\":%d,\"blocks_per_s\":%.1f,\"ms_per_block_per_checker\":%.3f,\"reads_per_s\":%.3e,\"seconds_per_52560_blocks\":%.1f}\n",
           checkers, reads_per_round, bps, 1000.0 * checkers / bps, bps * 8 * reads_per_round, 52560 / bps);
    return 0;
}
