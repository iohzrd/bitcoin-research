#!/usr/bin/env bash
# Second packing run on a rented multi-GPU machine: a stuffer with partner counts 0 to 7 on the
# GPUs it would rent to hold the (1 - s) of the chain it cannot regenerate (ddpow_pack_cuda.cu),
# then the CPU packing benchmark on the host (ddpow_pack_cpu.cpp). Writes JSON lines, samples and
# checks to results/<host>-pack2-<time>/. Run from ddpow-strong/cuda.
#
# Options (environment): SECONDS_PER_RUN (default 8), GIB_PER_GPU (default 104), BPSM (default
# 8), CPU_GIB (host dataset, default 128), CPU_SECONDS (default 10), CUDA_ARCH (default 90).
set -euo pipefail
cd "$(dirname "$0")"
RUN=${SECONDS_PER_RUN:-8}
GIB=${GIB_PER_GPU:-104}
BPSM=${BPSM:-8}
CPU_GIB=${CPU_GIB:-128}
CPU_RUN=${CPU_SECONDS:-10}
ARCH=${CUDA_ARCH:-90}
OUT=results/$(hostname)-pack2-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

echo "== machine"
nvidia-smi --query-gpu=index,name,memory.total,power.limit --format=csv | tee "$OUT/gpus.csv"
lscpu | grep -E "Model name|^CPU\(s\)|Socket|NUMA node\(s\)" | tee "$OUT/cpu.txt"
free -g | tee "$OUT/ram.txt"
# Without persistence mode every process initializes its GPUs from scratch.
nvidia-smi -pm 1 >/dev/null 2>&1 || true
NVCC=$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)

echo "== build"
"$NVCC" -O3 -std=c++17 -gencode arch=compute_$ARCH,code=sm_$ARCH -o ddpow_pack_cuda ddpow_pack_cuda.cu
g++ -O3 -march=native -std=c++17 -pthread -o ddpow_pack_cpu ddpow_pack_cpu.cpp

echo "== GPUs that start within 90 s"
GOOD=""
for i in $(seq 0 $(( $(nvidia-smi --list-gpus | wc -l) - 1 ))); do
    if timeout 90 ./ddpow_pack_cuda --mode ceiling --device "$i" --seconds 0.2 >/dev/null; then GOOD="$GOOD,$i"; else echo "GPU $i does not start: left out"; fi
done
export CUDA_VISIBLE_DEVICES=${GOOD#,}
G=$(echo "$CUDA_VISIBLE_DEVICES" | tr ',' '\n' | wc -l)
echo "using GPUs $CUDA_VISIBLE_DEVICES ($G); $RUN s per run, $GIB GiB per GPU"

gpu() {
    local name=$1; shift
    ./ddpow_pack_cuda "$@" --bpsm "$BPSM" --seconds "$RUN" --samples "$OUT/samples-$name" | sed "s/^{/{\"name\":\"$name\",/" | tee -a "$OUT/results.jsonl"
}

echo "== honest, all $G GPUs"
gpu all --mode peer --gpus "$G" --gib-per-gpu "$GIB" --list 0:0
for s in 0.35 0.51 0.675; do
    g=$(python3 -c "import math; print(max(1, math.ceil((1 - $s) * $G)))")
    echo "== s = $s on $g GPUs: honest, then the stuffer with 0 to 7 partners"
    gpu s$s-g$g --mode peer --gpus "$g" --gib-per-gpu "$GIB" --regen "$s" --list "0:0,0:1,1:1,2:1,3:1,4:1,5:1,6:1,7:1"
done

echo "== CPU on the host (${CPU_GIB} GiB, all threads)"
./ddpow_pack_cpu --gib "$CPU_GIB" --seconds "$CPU_RUN" --check "$OUT/cpu-check.txt" \
    --configs "0:0:h,0:0:f,0:0.35:g,3:0.35:g,7:0.35:g,15:0.35:g,0:0.51:g,3:0.51:g,7:0.51:g,15:0.51:g,0:0.675:g,3:0.675:g,7:0.675:g,11:0.675:g,15:0.675:g" \
    | tee "$OUT/cpu.jsonl"

echo "== verify GPU samples"
for f in "$OUT"/samples-*; do python3 verify_pack.py "$f" 1; done | tee "$OUT/verify.txt"
echo "== done: $OUT"
