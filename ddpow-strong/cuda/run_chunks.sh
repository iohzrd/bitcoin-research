#!/usr/bin/env bash
# Chunk-size sweep on an NVIDIA machine: for 64, 256, 1024, 4096 and 8192-byte chunks, the
# blake2b step ceiling, one GPU's memory (blake2b and fold), and with 2 or more GPUs the
# dataset split across all GPUs (blake2b and fold). fold costs one compression per read, so it
# gives the read limit. Writes results/<host>-chunks-<time>/. Run from ddpow-strong/cuda.
# Options (environment): SECONDS_PER_RUN (default 12), PEER_FILL (default 0.75), CUDA_ARCHS.
set -euo pipefail
cd "$(dirname "$0")"
RUN=${SECONDS_PER_RUN:-12}
PEER_FILL=${PEER_FILL:-0.75}
OUT=results/$(hostname)-chunks-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

nvidia-smi --query-gpu=index,name,memory.total,power.limit --format=csv | tee "$OUT/gpus.csv"
nvidia-smi topo -m > "$OUT/topo.txt" || true
NVCC=$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)
GPUS=$(nvidia-smi --list-gpus | wc -l)
FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sort -n | head -1)
DEV_GIB=$(( FREE_MIB / 1024 - 4 ))
PEER_GIB=$(python3 -c "print(int(${FREE_MIB}/1024*${PEER_FILL}))")
PER_SIZE=$(( 3 + (GPUS > 1 ? 2 : 0) ))
echo "== plan: $GPUS GPUs, dev ${DEV_GIB} GiB, peer ${PEER_GIB} GiB per GPU; $(( PER_SIZE * 5 )) runs of ${RUN} s: about $(( PER_SIZE * 5 * (RUN + 6) / 60 + 1 )) minutes (estimate)"

ARCHS=""
for a in ${CUDA_ARCHS:-80 86 89 90 100 120}; do
    if "$NVCC" --list-gpu-arch 2>/dev/null | grep -q "compute_$a"; then ARCHS="$ARCHS -gencode arch=compute_$a,code=sm_$a"; fi
done
"$NVCC" -O3 -std=c++17 $ARCHS -o ddpow_cuda ddpow_cuda.cu
for i in $(seq 0 $((GPUS - 1))); do
    ./ddpow_cuda --mode ceiling --device "$i" --seconds 0.2 >/dev/null || { echo "CUDA does not start on GPU $i: stopping"; exit 3; }
done

run() {
    local name=$1; shift
    nvidia-smi --query-gpu=index,power.draw --format=csv,noheader,nounits -lms 1000 > "$OUT/power-$name.csv" &
    local sampler=$!
    ./ddpow_cuda "$@" --seconds "$RUN" --samples "$OUT/samples-$name.txt" | tee -a "$OUT/results.jsonl"
    kill $sampler; wait $sampler 2>/dev/null || true
    python3 -c "
import json, sys, collections
w = collections.defaultdict(list)
for line in open('$OUT/power-$name.csv'):
    try:
        i, p = line.split(','); w[int(i)].append(float(p))
    except ValueError:
        pass
print(json.dumps({'run': '$name', 'power_w_total': round(sum(sum(v) / len(v) for v in w.values() if v), 1)}))" | tee -a "$OUT/results.jsonl"
    python3 verify.py "$OUT/samples-$name.txt"
}

for chunk in 64 256 1024 4096 8192; do
    kernel=staged
    [ "$chunk" -lt 256 ] && kernel=stream
    echo "== $chunk-byte chunks ($kernel kernel)"
    run ceiling-$chunk --mode ceiling --chunk "$chunk" --step blake2b --kernel stream
    for step in blake2b fold; do run dev-$chunk-$step --mode dev --gib "$DEV_GIB" --chunk "$chunk" --step $step --kernel $kernel; done
    if [ "$GPUS" -gt 1 ]; then
        for step in blake2b fold; do run peer-$chunk-$step --mode peer --gpus "$GPUS" --gib-per-gpu "$PEER_GIB" --chunk "$chunk" --step $step --kernel $kernel; done
    fi
done
echo "== done: $OUT"
