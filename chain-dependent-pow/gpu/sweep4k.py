#!/usr/bin/env python3
import itertools
import sys

from sweep import run, show, sweep, idle_power


def grid_stream():
    return [dict(impl="stream", tpb=t, bpcu=b) for t, b in itertools.product([64, 128, 256], [2, 4, 8, 16])]


def grid_coop():
    g = [dict(impl="coop", sb=1, tpb=t, bpcu=b) for t, b in itertools.product([32, 64, 128, 256], [2, 4, 8, 16])]
    g += [dict(impl="coop", sb=3, tpb=t, bpcu=b) for t, b in itertools.product([32, 64, 128], [2, 4, 8, 16])]
    return g


def main():
    which = sys.argv[1:] or ["hash", "dev", "host", "probe"]
    print(f"idle power: {idle_power():.1f} W", flush=True)
    if "hash" in which:
        grid = [dict(tpb=t, bpcu=b) for t, b in itertools.product([64, 128, 256], [4, 8, 16, 32])]
        sweep("c4k_step", dict(mode="hash", chunk=4096), grid)
    if "dev" in which:
        sweep("c4k_dev_12gib_stream", dict(mode="dev", chunk=4096, gib=12), grid_stream())
        sweep("c4k_dev_12gib_coop", dict(mode="dev", chunk=4096, gib=12), grid_coop())
    if "host" in which:
        sweep("c4k_host_12gib_stream", dict(mode="host", chunk=4096, gib=12), grid_stream(), sweep_seconds=3.0)
        sweep("c4k_host_12gib_coop", dict(mode="host", chunk=4096, gib=12), grid_coop(), sweep_seconds=3.0)
    if "probe" in which:
        for where in ["host", "dev"]:
            print(f"== c4k_probe_{where}: 4096-byte random reads, no hashing", flush=True)
            for impl, t, b in itertools.product(["stream", "coop"], [64, 256], [2, 8, 32]):
                r = run(mode=where, chunk=4096, gib=12, kernel="probe", impl=impl, tpb=t, bpcu=b, seconds=4)
                if r:
                    print(f"  impl={impl} tpb={t} bpcu={b} reads_per_s={r['reads_per_s']:.4e} bytes_per_s={r['bytes_per_s']:.4e} avg_w={r['avg_w']}", flush=True)
            r = run(mode=where, chunk=64, gib=12, kernel="seq", tpb=256, bpcu=16, seconds=6)
            if r:
                print(f"  sequential: bytes_per_s={r['bytes_per_s']:.4e}", flush=True)


if __name__ == "__main__":
    main()
