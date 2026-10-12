#!/bin/bash
# MiniCPM-V 4.7 35B-A3B int4 on 2x RTX 3090 (TP2, NVLink bridge), OpenAI-compatible API on :8016.
# One-time setup:
#   HF_HUB_DISABLE_XET=1 hf download openbmb/MiniCPM-V-4.7-35B-A3B-int4 --local-dir ~/models/MiniCPM-V-4.7-35B-A3B-int4
#   python3 launch/fix_configs.py ~/models/MiniCPM-V-4.7-35B-A3B-int4
#   docker build -t local/vllm-minicpm47:fe4df3d launch/
set -e
MODELS=${MODELS:-$HOME/models}
GPUS=${GPUS:-0,1}          # an NVLink-bridged pair
PORT=${PORT:-8016}
CTX=${CTX:-262144}         # native 256K; the KV pool on 2x24 GB holds ~612K tokens at gmu 0.90
docker rm -f minicpm-v47 >/dev/null 2>&1 || true
docker run -d --name minicpm-v47 --restart unless-stopped --runtime nvidia --ipc=host \
  -e NVIDIA_VISIBLE_DEVICES=all -e CUDA_VISIBLE_DEVICES=$GPUS \
  -e NCCL_P2P_LEVEL=NVL -e NCCL_CUMEM_ENABLE=0 \
  -p $PORT:8000 -v $MODELS:/models:ro \
  local/vllm-minicpm47:fe4df3d \
  --model /models/MiniCPM-V-4.7-35B-A3B-int4 --served-model-name minicpm-v-4.7 \
  --tensor-parallel-size 2 --max-model-len $CTX --gpu-memory-utilization 0.90 \
  --max-num-batched-tokens 8192 --limit-mm-per-prompt '{"image": 8, "video": 1}' \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3
echo "started; first boot ~3 min (weights + torch.compile + CUDA graphs). Check: curl localhost:$PORT/v1/models"
