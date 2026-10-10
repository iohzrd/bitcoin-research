# chain-dependent-pow/cuda: GPU benchmark for NVIDIA

CUDA benchmark of the strong rule's attempt (bip-chain-dependent-pow.md, k = 8) on NVIDIA GPUs, and
`run_lium.sh`, which runs every test on a rented machine (lium.io or any NVIDIA host with
`nvcc`). Data is generated on each GPU: word j of chunk a is splitmix64(a * W + j), W = chunk
bytes / 8. `verify.py` recomputes 128 sampled attempts per run with `hashlib.blake2b` and
Python integers; every run must report 128 of 128.

Steps: `blake2b` (x' = BLAKE2b-256(x || chunk), 33 compressions at 4 KiB, the rule) and `fold`
(XOR of the chunk's words into 4, then one compression: the read limit). `mul` (a multiply-based
step) is kept in the code for the earlier comparison only. Chunk sizes: 64, 256, 1024, 4096 and
8192 bytes.

Modes: `ceiling` (a 256 KiB dataset, cache-resident: the step rate), `dev` (one GPU's memory),
`host` (pinned host memory over PCIe), `peer` (split across GPUs; reads through peer pointers).
Kernels: `stream` (each thread reads its chunk) and `staged` (the block loads each thread's
next 128 bytes into shared memory, eight threads per line).

```
nvcc -O3 -std=c++17 -gencode arch=compute_89,code=sm_89 -o ddpow_cuda ddpow_cuda.cu
./ddpow_cuda --mode dev --gib 4 --step blake2b --kernel staged --seconds 15 --samples s.txt
python3 verify.py s.txt
./run_lium.sh            # everything; results in results/<host>-<time>/
```

On a pod (from this repository's root on the local machine; `<pod>` is the index, name or id
`lium ps` shows):

```
tar czf ddpow-bench.tgz --exclude=target --exclude=testfile.bin --exclude=results chain-dependent-pow
lium up --gpu H200 -c 8 --name h200          # or: lium up --gpu RTX4090 for a first test
lium scp h200 ./ddpow-bench.tgz /root/
lium exec h200 "cd /root && tar xzf ddpow-bench.tgz && cd chain-dependent-pow/cuda && ./run_lium.sh"
lium scp h200 /root/chain-dependent-pow/cuda/results ./ -d
lium rm h200
```

`run_lium.sh` runs the 4 KiB tests and the host CPU benchmark; `run_chunks.sh` runs every
chunk size (ceiling, one GPU, all GPUs; blake2b and fold).

Results: `results/h200x8-swift-wolf-47-20261001/` (8 x H200, 4 KiB, host CPU) and
`results/h200x8-chunks-20261001/` (8 x H200, every chunk size); summary in `../README.md`.

Measured on an RTX 4070 Laptop GPU (8 GB, 2026-10-01, dataset in GPU memory, 2 GiB, 128 x 8
threads per SM; attempts/s):

| chunk | stream, blake2b | staged, blake2b | staged, fold |
| --- | --- | --- | --- |
| 64 B | 1.25e8 | - | - |
| 256 B | - | 4.9e7 | 7.2e7 |
| 1 KiB | - | 1.5e7 | - |
| 4 KiB | 2.4e6 | 3.9e6 to 4.5e6 | 6.7e6 (220 GB/s) |
| 8 KiB | - | 2.0e6 | 3.5e6 (229 GB/s) |

Data in host memory read over PCIe (4 KiB, blake2b): 8.4e4 (stream), 3.0e5 (staged, 9.8 GB/s).
