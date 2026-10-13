#!/bin/bash
# MiniCPM-V 4.7 35B-A3B int4 on 2x RTX 3090 (TP2, NVLink bridge), OpenAI-compatible API on :8016.
# One-time setup:
#   HF_HUB_DISABLE_XET=1 hf download openbmb/MiniCPM-V-4.7-35B-A3B-int4 --local-dir ~/models/MiniCPM-V-4.7-35B-A3B-int4
#   python3 launch/fix_configs.py ~/models/MiniCPM-V-4.7-35B-A3B-int4
#   docker build -t local/vllm-minicpm47:fe4df3d launch/
#   optional DSpark draft (0.78 GB):  HF_HUB_DISABLE_XET=1 hf download openbmb/MiniCPM-V-4.7-35B-A3B-DSpark --local-dir ~/models/MiniCPM-V-4.7-35B-A3B-DSpark
set -e
MODELS=${MODELS:-$HOME/models}
GPUS=${GPUS:-0,1}          # an NVLink-bridged pair
PORT=${PORT:-8016}
CTX=${CTX:-262144}         # native 256K; KV pool on 2x24 GB at gmu 0.90: ~612K tokens plain, ~362K with DSpark
DSPARK=${DSPARK:-1}       # 1 = speculative decoding with the DSpark draft, 7 tokens per step (2.05x median single-stream on real prompts); 0 = plain
SPEC=()
if [ "$DSPARK" = 1 ]; then
  SPEC=(--max-num-seqs 16 --speculative-config '{"method":"dspark","model":"/models/MiniCPM-V-4.7-35B-A3B-DSpark","num_speculative_tokens":7}')
fi
docker rm -f minicpm-v47 >/dev/null 2>&1 || true
docker run -d --name minicpm-v47 --restart unless-stopped --runtime nvidia --ipc=host \
  -e NVIDIA_VISIBLE_DEVICES=all -e CUDA_VISIBLE_DEVICES=$GPUS \
  -e NCCL_P2P_LEVEL=NVL -e NCCL_CUMEM_ENABLE=0 \
  -p $PORT:8000 -v $MODELS:/models:ro \
  local/vllm-minicpm47:fe4df3d \
  --model /models/MiniCPM-V-4.7-35B-A3B-int4 --served-model-name minicpm-v-4.7 \
  --tensor-parallel-size 2 --max-model-len $CTX --gpu-memory-utilization 0.90 \
  --max-num-batched-tokens 8192 --limit-mm-per-prompt '{"image": 8, "video": 1}' \
  "${SPEC[@]}" \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3
echo "started; first boot ~3 min (weights + torch.compile + CUDA graphs). Check: curl localhost:$PORT/v1/models"
