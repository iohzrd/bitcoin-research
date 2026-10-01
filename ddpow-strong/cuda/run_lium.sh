#!/usr/bin/env bash
# Runs the strong data-dependent proof of work benchmarks on an NVIDIA machine (a rented pod):
# GPU step ceilings, the dataset in one GPU's memory, the dataset split across all GPUs with
# peer reads (NVLink), and the CPU benchmark on the host. Writes JSON lines and logs to
# results/<host>-<time>/. Run from ddpow-strong/cuda.
#
# Options (environment): SECONDS_PER_RUN (default 15), PEER_FILL (fraction of each GPU's memory
# for the peer dataset, default 0.75), CPU_GIB (host dataset, default min(256, 60% of RAM)),
# CUDA_ARCHS (compute capabilities to build, default "80 86 89 90 100 120").
set -euo pipefail
cd "$(dirname "$0")"
RUN=${SECONDS_PER_RUN:-15}
PEER_FILL=${PEER_FILL:-0.75}
OUT=results/$(hostname)-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
LOG=$OUT/run.log
exec > >(tee -a "$LOG") 2>&1

echo "== machine"
nvidia-smi --query-gpu=index,name,memory.total,power.limit,pcie.link.gen.current,pcie.link.width.current --format=csv | tee "$OUT/gpus.csv"
nvidia-smi topo -m | tee "$OUT/topo.txt" || true
nvidia-smi nvlink -s 2>/dev/null | head -40 | tee "$OUT/nvlink.txt" || true
nvidia-smi | head -5 || true
lscpu | grep -E "Model name|^CPU\(s\)|Socket|NUMA node\(s\)" | tee "$OUT/cpu.txt"
free -g | tee "$OUT/ram.txt"
(dmidecode -t memory 2>/dev/null | grep -E "^\s+(Type|Speed|Configured Memory Speed|Size):" | sort | uniq -c | tee "$OUT/dimms.txt") || true
NVCC=$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)
"$NVCC" --version | tail -2 || true

GPUS=$(nvidia-smi --list-gpus | wc -l)
FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sort -n | head -1)
DEV_GIB=$(( FREE_MIB / 1024 - 4 ))
PEER_GIB=$(python3 -c "print(int(${FREE_MIB}/1024*${PEER_FILL}))")
RAM_GIB=$(free -g | awk '/^Mem:/ {print $2}')
CPU_GIB=${CPU_GIB:-$(python3 -c "print(min(256, int(${RAM_GIB}*0.6)))")}
RUNS_GPU=$(( 4 + 4 + (GPUS > 1 ? 4 : 0) ))
echo "== plan: $GPUS GPUs, dev dataset ${DEV_GIB} GiB, peer ${PEER_GIB} GiB per GPU, CPU ${CPU_GIB} GiB"
echo "   $RUNS_GPU GPU runs and 2 CPU runs of ${RUN} s, plus builds: about $(( (RUNS_GPU + 2) * (RUN + 10) / 60 + 4 )) minutes (estimate)"

echo "== build"
ARCHS=""
for a in ${CUDA_ARCHS:-80 86 89 90 100 120}; do
    if "$NVCC" --list-gpu-arch 2>/dev/null | grep -q "compute_$a"; then ARCHS="$ARCHS -gencode arch=compute_$a,code=sm_$a"; fi
done
"$NVCC" -O3 -std=c++17 $ARCHS -Xptxas -v -o ddpow_cuda ddpow_cuda.cu 2>&1 | grep -E "error|spill" | sort | uniq -c || true
# Every GPU must take a CUDA context, else stop before anything long runs.
for i in $(seq 0 $((GPUS - 1))); do
    ./ddpow_cuda --mode ceiling --device "$i" --seconds 0.2 >/dev/null || { echo "CUDA does not start on GPU $i: stopping"; exit 3; }
done
echo "CUDA starts on all $GPUS GPUs"
if ! command -v cargo >/dev/null; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null
    . "$HOME/.cargo/env"
fi
(cd .. && cargo build --release -q)

# One GPU run with power sampling and sample verification.
gpu_run() {
    local name=$1; shift
    nvidia-smi --query-gpu=index,power.draw --format=csv,noheader,nounits -lms 1000 > "$OUT/power-$name.csv" &
    local sampler=$!
    ./ddpow_cuda "$@" --seconds "$RUN" --samples "$OUT/samples-$name.txt" | tee -a "$OUT/results.jsonl"
    kill $sampler; wait $sampler 2>/dev/null || true
    python3 - "$OUT/power-$name.csv" <<'PY' | tee -a "$OUT/results.jsonl"
import sys, collections
watts = collections.defaultdict(list)
for line in open(sys.argv[1]):
    try:
        i, w = line.split(",")
        watts[int(i)].append(float(w))
    except ValueError:
        pass
import json
print(json.dumps({"power_w_per_gpu": {str(i): round(sum(v) / len(v), 1) for i, v in sorted(watts.items()) if v}}))
PY
    python3 verify.py "$OUT/samples-$name.txt"
}

echo "== GPU step ceilings (dataset in cache)"
for step in blake2b mul; do gpu_run ceiling-$step --mode ceiling --step $step --kernel stream; done

echo "== dataset in one GPU's memory (${DEV_GIB} GiB)"
for kernel in stream staged; do
    for step in blake2b mul; do gpu_run dev-$kernel-$step --mode dev --gib "$DEV_GIB" --step $step --kernel $kernel; done
done

if [ "$GPUS" -gt 1 ]; then
    echo "== dataset split across $GPUS GPUs (${PEER_GIB} GiB each), reads through peer pointers"
    for kernel in staged stream; do
        for step in blake2b mul; do gpu_run peer-$kernel-$step --mode peer --gpus "$GPUS" --gib-per-gpu "$PEER_GIB" --step $step --kernel $kernel; done
    done
fi

echo "== CPU on the host (${CPU_GIB} GiB, all threads, 8 lanes, 4 KiB reads)"
(cd .. && ./target/release/ddpow-strong bench --read-bytes 4096 --lanes 8 --gib "$CPU_GIB" --seconds "$RUN") | tee -a "$OUT/cpu-bench.txt"
(cd .. && ./target/release/ddpow-strong bench --read-bytes 4096 --lanes 8 --gib "$CPU_GIB" --seconds "$RUN" --nohash 1) | tee -a "$OUT/cpu-bench.txt"

echo "== done: $OUT"
