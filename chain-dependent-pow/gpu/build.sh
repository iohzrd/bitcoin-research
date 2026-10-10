#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROCM=${ROCM_PATH:-/opt/rocm}
export ROCM_PATH="$ROCM" HIP_PATH="$ROCM"
ARCH=${GPU_ARCH:-gfx1201}
"$ROCM/bin/hipcc" -O3 -std=c++17 -I"$ROCM/include" --offload-arch="$ARCH" \
  -Rpass-analysis=kernel-resource-usage \
  --save-temps=obj -o ddpow_gpu ddpow_gpu.hip 2> build.log
grep -E "Function Name|VGPRs:|SGPRs:|ScratchSize|Occupancy|LDS Size" build.log | sed 's/^.*remark: //'
