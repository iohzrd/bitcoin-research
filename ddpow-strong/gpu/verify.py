#!/usr/bin/env python3
import hashlib
import struct
import sys

M64 = (1 << 64) - 1


def splitmix64(z):
    z = (z + 0x9E3779B97F4A7C15) & M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def chunk(a, size=64):
    words = size // 8
    return b"".join(struct.pack("<Q", splitmix64(a * words + j)) for j in range(words))


def h(data):
    return hashlib.blake2b(data, digest_size=32).digest()


def idx(x, m):
    return struct.unpack_from("<Q", x)[0] % m


def header(stream, nonce):
    return struct.pack("<QQ", stream, nonce) + bytes(64)


def attempt(stream, nonce, n, s, size=64):
    x = h(header(stream, nonce))
    a = s + idx(x, n - s)
    for i in range(8):
        x = h(x + chunk(a, size))
        if i < 7:
            a = idx(x, n)
    return x


def synthetic_step(x):
    xs = struct.unpack("<4Q", x)
    return h(x + b"".join(struct.pack("<Q", (xs[j & 3] + j) & M64) for j in range(512)))


def step_chain(stream, steps):
    x = h(header(stream, 0))
    for _ in range(steps):
        x = synthetic_step(x)
    return x


def main(path):
    raw = open(path, "rb").read()
    mode, n, s, count = struct.unpack_from("<4Q", raw)
    ok = bad = empty = 0
    for k in range(count):
        stream, nonce, *words = struct.unpack_from("<6Q", raw, 32 + 48 * k)
        got = struct.pack("<4Q", *words)
        if got == bytes(32):
            empty += 1
            continue
        if mode == 0:
            want = h(header(stream, nonce))
        elif mode == 1:
            want = attempt(stream, nonce, n, s)
        elif mode == 2:
            want = attempt(stream, nonce, n, s, 4096)
        else:
            want = step_chain(stream, nonce + 1)
        if got == want:
            ok += 1
        else:
            bad += 1
            if bad <= 5:
                print(f"MISMATCH stream={stream} nonce={nonce} got={got.hex()} want={want.hex()}")
    kind = {0: "header-hash", 1: f"attempt-64 n={n} s={s}", 2: f"attempt-4096 n={n} s={s}", 3: "step-4128-synthetic"}[mode]
    print(f"{path}: {kind} samples={count} match={ok} mismatch={bad} unwritten={empty}")
    sys.exit(0 if bad == 0 and empty == 0 and ok >= 100 else 1)


if __name__ == "__main__":
    main(sys.argv[1])
