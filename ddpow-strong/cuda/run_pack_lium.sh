#!/usr/bin/env bash
# Packing benchmark on a rented multi-GPU machine (ddpow_pack_cuda.cu): an honest miner reading a
# stored packed chunk per step against a stuffer forming packed chunks from raw chunks and the
# chunks it generates. Writes JSON lines, samples and checks to results/<host>-pack-<time>/.
# Run from ddpow-strong/cuda.
#
# Options (environment): SECONDS_PER_RUN (default 12), GIB_PER_GPU (default 104), BPSM (blocks
# per SM, default 8), CUDA_ARCHS (default "80 86 89 90 100 120").
set -euo pipefail
cd "$(dirname "$0")"
RUN=${SECONDS_PER_RUN:-12}
GIB=${GIB_PER_GPU:-104}
BPSM=${BPSM:-8}
OUT=results/$(hostname)-pack-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

echo "== machine"
nvidia-smi --query-gpu=index,name,memory.total,power.limit --format=csv | tee "$OUT/gpus.csv"
nvidia-smi topo -m | tee "$OUT/topo.txt" || true
NVCC=$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)
"$NVCC" --version | tail -2 || true
GPUS=$(nvidia-smi --list-gpus | wc -l)

echo "== build"
ARCHS=""
for a in ${CUDA_ARCHS:-80 86 89 90 100 120}; do
    if "$NVCC" --list-gpu-arch 2>/dev/null | grep -q "compute_$a"; then ARCHS="$ARCHS -gencode arch=compute_$a,code=sm_$a"; fi
done
"$NVCC" -O3 -std=c++17 $ARCHS -Xptxas -v -o ddpow_pack_cuda ddpow_pack_cuda.cu 2>&1 | grep -E "error|spill" | sort | uniq -c || true
"$NVCC" -O3 -std=c++17 $ARCHS -o ddpow_cuda ddpow_cuda.cu 2>&1 | grep -E "error" || true
for i in $(seq 0 $((GPUS - 1))); do
    ./ddpow_pack_cuda --mode ceiling --device "$i" --seconds 0.2 >/dev/null || { echo "CUDA does not start on GPU $i: stopping"; exit 3; }
done
echo "CUDA starts on all $GPUS GPUs; $RUN s per run, $GIB GiB per GPU, $BPSM blocks per SM"

run() {
    local name=$1; shift
    ./ddpow_pack_cuda "$@" --bpsm "$BPSM" --seconds "$RUN" --samples "$OUT/samples-$name.txt" | sed "s/^{/{\"name\":\"$name\",/" | tee -a "$OUT/results.jsonl"
    python3 verify_pack.py "$OUT/samples-$name.txt" 2 | tee -a "$OUT/verify.txt"
}

echo "== reference: the strong-rule benchmark's staged kernel, all GPUs"
./ddpow_cuda --mode peer --gpus "$GPUS" --gib-per-gpu "$GIB" --step blake2b --kernel staged --seconds "$RUN" | tee -a "$OUT/reference.jsonl"

echo "== generation cost (one GPU, cache-resident dataset): every chunk read, every chunk generated"
run ceiling-read --mode ceiling --regen 0 --generate 1
run ceiling-gen --mode ceiling --regen 1 --generate 1

echo "== all $GPUS GPUs: honest (one packed chunk per step), stuffer (s regenerable, m partners)"
run honest-$GPUS --mode peer --gpus "$GPUS" --gib-per-gpu "$GIB"
for s in 0.35 0.51 0.675; do
    for m in 0 7 11 15; do
        run stuff-$GPUS-s$s-m$m --mode peer --gpus "$GPUS" --gib-per-gpu "$GIB" --partners "$m" --regen "$s" --generate 1
    done
done

echo "== fewer GPUs: the stuffer holds the (1 - s) of the chain it cannot regenerate"
for pair in "0.35 6" "0.51 4" "0.675 3"; do
    set -- $pair
    s=$1; g=$2
    [ "$g" -le "$GPUS" ] || continue
    run honest-$g --mode peer --gpus "$g" --gib-per-gpu "$GIB"
    for m in 0 7 15; do
        run stuff-$g-s$s-m$m --mode peer --gpus "$g" --gib-per-gpu "$GIB" --partners "$m" --regen "$s" --generate 1
    done
done

echo "== done: $OUT"
grep -c "agrees on 2 of 2; timed kernel equals reference on 128 of 128" "$OUT/verify.txt" | sed 's/^/runs verified: /'
