#!/usr/bin/env python3
import itertools
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "ddpow_gpu")
OUT = os.path.join(HERE, "results")
os.makedirs(OUT, exist_ok=True)
LOG = os.path.join(OUT, "runs.jsonl")


def run(**kw):
    cmd = [BIN]
    for k, v in kw.items():
        cmd += ["--" + k.replace("_", "-"), str(v)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print("FAILED", " ".join(cmd), p.stderr.strip(), flush=True)
        return None
    line = p.stdout.strip().splitlines()[-1]
    r = {}
    for tok in line.split(" "):
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                r[k] = float(v) if any(c in v for c in ".e") and k not in ("fold", "gpu") else int(v)
            except ValueError:
                r[k] = v
    r["cmd"] = " ".join(cmd[1:])
    with open(LOG, "a") as f:
        f.write(json.dumps(r) + "\n")
    return r


def show(r):
    keys = ["mode", "chunk", "impl", "sb", "gib", "ilp", "tpb", "bpcu", "vgpr_regs", "occ_blocks_per_cu", "rate", "reads_per_s", "avg_w", "avg_sclk_mhz", "avg_mclk_mhz", "seconds", "compress_per_s", "bytes_per_s"]
    print("  " + " ".join(f"{k}={r.get(k)}" for k in keys), flush=True)


def idle_power(seconds=4):
    import glob
    paths = glob.glob("/sys/class/drm/card*/device/hwmon/hwmon*/power1_average")
    if not paths:
        return None
    vals = []
    for _ in range(int(seconds / 0.25)):
        vals.append(int(open(paths[0]).read()) / 1e6)
        time.sleep(0.25)
    return sum(vals) / len(vals)


def sweep(label, base, grid, sweep_seconds=2.0, final_seconds=12.0):
    print(f"== {label}: sweep", flush=True)
    best = None
    for combo in grid:
        r = run(**base, **combo, seconds=sweep_seconds, launch_ms=250)
        if r is None:
            continue
        show(r)
        if best is None or r["rate"] > best["rate"]:
            best = r
            best_combo = combo
    print(f"== {label}: final run with {best_combo}", flush=True)
    samples = os.path.join(OUT, f"samples_{label}.bin")
    if os.path.exists(samples):
        os.remove(samples)
    r = run(**base, **best_combo, seconds=final_seconds, samples=samples)
    if r is None:
        print(f"  final run failed for {label}", flush=True)
        return None
    show(r)
    v = subprocess.run([sys.executable, os.path.join(HERE, "verify.py"), samples], capture_output=True, text=True)
    print("  verify: " + v.stdout.strip().split(": ", 1)[-1], flush=True)
    r["label"] = label
    r["verify"] = v.stdout.strip().split(": ", 1)[-1]
    r["verify_ok"] = v.returncode == 0
    with open(os.path.join(OUT, "final.jsonl"), "a") as f:
        f.write(json.dumps(r) + "\n")
    return r


def main():
    which = sys.argv[1:] or ["hash", "dev", "host"]
    print(f"idle power: {idle_power():.1f} W", flush=True)
    if "hash" in which:
        grid = [dict(tpb=t, bpcu=b) for t, b in itertools.product([64, 128, 256], [4, 8, 16, 32])]
        sweep("hash", dict(mode="hash"), grid)
    if "dev" in which:
        for gib in [0.03125, 1, 4, 12]:
            grid = [dict(ilp=i, tpb=t, bpcu=b) for i, t, b in itertools.product([1, 2, 4, 8], [64, 128, 256], [2, 4, 8, 16])]
            sweep(f"dev_{gib:g}gib", dict(mode="dev", gib=gib), grid)
    if "host" in which:
        grid = [dict(ilp=i, tpb=t, bpcu=b) for i, t, b in itertools.product([1, 2, 4, 8], [64, 256], [2, 4, 8, 16])]
        r = sweep("host_12gib", dict(mode="host", gib=12), grid, sweep_seconds=3.0)
        print("== host_12gib: non-coherent allocation at the same configuration", flush=True)
        nc = run(mode="host", gib=12, ilp=r["ilp"], tpb=r["tpb"], bpcu=r["bpcu"], seconds=12, coherent=0)
        show(nc)


if __name__ == "__main__":
    main()
