#!/usr/bin/env python3
"""Checks ddpow_cuda samples (--samples FILE) against an independent implementation:
hashlib.blake2b for BLAKE2b-256, Python integers for the multiply step, and splitmix64 for the
data. Prints 'N of N match' and exits non-zero on any mismatch."""
import hashlib
import json
import sys

GOLDEN = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def splitmix64(z):
    z = (z + GOLDEN) & M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def b2(data):
    return hashlib.blake2b(data, digest_size=32).digest()


def chunk_words(a, w):
    return [splitmix64(a * w + j) for j in range(w)]


def words_bytes(ws):
    return b"".join(x.to_bytes(8, "little") for x in ws)


def step(x, a, w, kind):
    c = chunk_words(a, w)
    if kind == "blake2b":
        return b2(x + words_bytes(c))
    if kind == "fold":
        f = [0, 0, 0, 0]
        for i, v in enumerate(c):
            f[i & 3] ^= v
        return b2(x + words_bytes(f))
    xw = [int.from_bytes(x[8 * i:8 * i + 8], "little") for i in range(4)]
    acc = []
    for lane in range(2):
        s = 0
        for p in range(w // 2):
            i0, i1 = 2 * p, 2 * p + 1
            k0 = (xw[(i0 + 2 * lane) & 3] + (i0 + w * lane) * GOLDEN) & M64
            k1 = (xw[(i1 + 2 * lane) & 3] + (i1 + w * lane) * GOLDEN) & M64
            s += ((c[i0] + k0) & M64) * ((c[i1] + k1) & M64)
        acc.append(s % (1 << 128))
    return b2(x + acc[0].to_bytes(16, "little") + acc[1].to_bytes(16, "little"))


def attempt(stream, nonce, n, s, w, kind, reads):
    x = b2(stream.to_bytes(8, "little") + nonce.to_bytes(8, "little") + bytes(64))
    a = s + int.from_bytes(x[:8], "little") % (n - s)
    for _ in range(reads):
        x = step(x, a, w, kind)
        a = int.from_bytes(x[:8], "little") % n
    return x


def main(path):
    with open(path) as f:
        meta = json.loads(f.readline())
        rows = [line.split() for line in f if line.strip()]
    w = meta["chunk"] // 8
    bad = 0
    for stream, nonce, final in rows:
        got = attempt(int(stream), int(nonce), meta["n"], meta["s"], w, meta["step"], meta["reads"]).hex()
        if got != final:
            bad += 1
    print(f"{len(rows) - bad} of {len(rows)} match ({path})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main(sys.argv[1])
