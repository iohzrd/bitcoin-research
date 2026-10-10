#!/usr/bin/env python3
"""Recomputes ddpow_pack_cuda's reference samples (a samples file from --samples) in Python with
hashlib.blake2b and a ChaCha8 implementation; prints how many of the 128 agree, and the timed
kernel's agreement with the reference that the benchmark recorded."""

import hashlib
import json
import sys

M64 = (1 << 64) - 1
GOLDEN = 0x9E3779B97F4A7C15
REGEN_SALT = 0xA5A5A5A55A5A5A5A
KEY_SALT = 0x0123456789ABCDEF
W = 512


def splitmix64(z):
    z = (z + GOLDEN) & M64
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def rotl32(x, n):
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def chacha8_block(key, counter):
    s = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574] + key + [counter, 0, 0, 0]
    x = list(s)

    def qr(a, b, c, d):
        x[a] = (x[a] + x[b]) & 0xFFFFFFFF; x[d] = rotl32(x[d] ^ x[a], 16)
        x[c] = (x[c] + x[d]) & 0xFFFFFFFF; x[b] = rotl32(x[b] ^ x[c], 12)
        x[a] = (x[a] + x[b]) & 0xFFFFFFFF; x[d] = rotl32(x[d] ^ x[a], 8)
        x[c] = (x[c] + x[d]) & 0xFFFFFFFF; x[b] = rotl32(x[b] ^ x[c], 7)
    for _ in range(4):
        qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
        qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
    return b"".join(((x[i] + s[i]) & 0xFFFFFFFF).to_bytes(4, "little") for i in range(16))


def chunk(p, threshold):
    if splitmix64(p ^ REGEN_SALT) < threshold:
        key = []
        for i in range(4):
            k = splitmix64((p * 4 + i + KEY_SALT) & M64)
            key += [k & 0xFFFFFFFF, k >> 32]
        return b"".join(chacha8_block(key, c) for c in range(W // 8))
    return b"".join(splitmix64((p * W + j) & M64).to_bytes(8, "little") for j in range(W))


def xor(a, b):
    return (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(len(a), "little")


def attempt(stream, nonce, n, partners, threshold, reads):
    x = hashlib.blake2b(stream.to_bytes(8, "little") + nonce.to_bytes(8, "little") + bytes(64), digest_size=32).digest()
    a = int.from_bytes(x[:8], "little") % n
    for _ in range(reads):
        c = chunk(a, threshold)
        for r in range(1, partners + 1):
            c = xor(c, chunk(splitmix64((a * 64 + r) & M64) % n, threshold))
        x = hashlib.blake2b(x + c, digest_size=32).digest()
        a = int.from_bytes(x[:8], "little") % n
    return x.hex()


def main(path, limit=16):
    lines = open(path).read().split("\n")
    head = json.loads(lines[0])
    rows = [l.split() for l in lines[1:] if l.strip()]
    ok = sum(attempt(int(s), int(no), head["n"], head["partners"], head["regen_threshold"], head["reads"]) == f for s, no, f in rows[:limit])
    print(f"{path}: Python reference agrees on {ok} of {min(limit, len(rows))}; timed kernel equals reference on {head['timed_equals_reference']} of 128")
    return ok == min(limit, len(rows)) and head["timed_equals_reference"] == 128


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 16) else 1)
