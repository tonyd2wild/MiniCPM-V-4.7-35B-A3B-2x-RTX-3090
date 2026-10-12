# MiniCPM-V 4.7 35B-A3B on 2x RTX 3090: 172 tok/s single stream, 803 tok/s at c6, full 262K context, in vLLM

OpenBMB's first MoE vision model (`openbmb/MiniCPM-V-4.7-35B-A3B-int4`, 22.6 GB) served on two RTX 3090s (48 GB VRAM) joined by an NVLink bridge, tensor parallel 2, with an OpenAI-compatible API, tool calling and images. Deployed the day after vLLM merged support (2026-10-12). Every number below was measured on the box.

| | Result |
|---|---|
| Single stream (c1) | **172.2 tok/s** end to end, 1.86 s for a 300-number list |
| Concurrency c1 → c6 | **172 / 288 / 423 / 557 / 677 / 803 tok/s** aggregate, 134 tok/s per stream at c6 |
| TTFT (1.5K-token prompt) | **0.22 s** at c1, 0.27 s at c6 |
| Prefill, cold (new prompt) | **18K tok/s** at 14K tokens · 11.6K at 56K · 7.8K at 113K · 4.9K tok/s at 220K (44.9 s) |
| Real prompts (40: code, reasoning, JSON, HTML, prose, stories, summaries, formatting) | c1: **173.6 tok/s** decode, TTFT 0.04 s, 96.3% auto-graded · c6: 125.8 tok/s per stream, 93.8% |
| Context | **262,144** native, KV pool 612,385 tokens (2.3 full-length requests at once) |
| 69-scenario tool-calling eval | **93.5 / 100** (63 pass, 3 partial, 3 fail), median turn **300 ms** |
| 100-task agency benchmark (private set, LLM judge) | **67 / 100** ([summary](results/agency/SUMMARY.md)) |
| VRAM | 20.7 GB per card at `--gpu-memory-utilization 0.90`, 262K context |

## Run it

```bash
# 1. weights (22.6 GB). Turn xet off: on our boxes the xet transfer stalled silently at 14 GB for 35 minutes.
HF_HUB_DISABLE_XET=1 hf download openbmb/MiniCPM-V-4.7-35B-A3B-int4 --local-dir ~/models/MiniCPM-V-4.7-35B-A3B-int4
# 2. fix the shipped configs (see "Why this needs three fixes")
python3 launch/fix_configs.py ~/models/MiniCPM-V-4.7-35B-A3B-int4
# 3. image: pinned vLLM nightly minus a broken torchcodec
docker build -t local/vllm-minicpm47:fe4df3d launch/
# 4. serve on GPU 0+1, port 8016
GPUS=0,1 PORT=8016 bash launch/serve.sh
```

First boot takes about 3 minutes (weights, torch.compile, CUDA graphs). Endpoint `http://<box>:8016/v1`, model `minicpm-v-4.7`.

```bash
curl -s localhost:8016/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "minicpm-v-4.7",
  "messages": [{"role": "user", "content": [
    {"type": "image_url", "image_url": {"url": "https://huggingface.co/datasets/openbmb/DemoCase/resolve/main/refract.png"}},
    {"type": "text", "text": "What causes this phenomenon?"}]}],
  "chat_template_kwargs": {"enable_thinking": false}}'
```

Tool calling uses vLLM's `qwen3_coder` parser (the model sits on the Qwen3.5 backbone). It returned clean parallel tool calls in our tests. Thinking is on by default; pass `"chat_template_kwargs": {"enable_thinking": false}` for plain answers. Every number on this page was measured with thinking off.

## Why this needs three fixes

On 2026-10-12, none of these worked out of the box:

1. **No released vLLM knows the model.** Support landed in [vllm-project/vllm#58674](https://github.com/vllm-project/vllm/pull/58674) on 2026-10-11, after v0.31.0. v0.27.1 lists `MiniCPMV4_6ForConditionalGeneration` but not 4.7. The [Dockerfile](launch/Dockerfile) pins the nightly `vllm/vllm-openai:cu129-nightly-fe4df3df…` (built 2026-10-12, 15 commits after the merge).
2. **That nightly's torchcodec is built for the wrong CUDA.** torchcodec 0.17 in the cu129 image links `libcudart.so.13` / `libnvrtc.so.13`. Importing it raises `OSError: Could not load this library`, and vLLM's guard only catches `ImportError` and `RuntimeError`, so the server dies at startup. The Dockerfile uninstalls torchcodec; vLLM then falls back cleanly. Images are unaffected. Video goes through vLLM's other decoders; we have not benchmarked video.
3. **The int4 repo's configs point at code it does not ship.**
   - `processor_config.json`, `preprocessor_config.json` and `tokenizer_config.json` carry `auto_map` entries for `processing_minicpmv4_7.py` and friends, including entries nested inside `image_processor` / `video_processor`. Transformers then refuses to load without remote code that isn't there.
   - They also name `MiniCPMV4_7ImageProcessor` / `MiniCPMV4_7VideoProcessor`. Transformers 5.19 has no such classes: its auto map sends model_type `minicpmv4_7` to the 4.6 image/video processors plus the native `MiniCPMV4_7Processor`.
   - [`fix_configs.py`](launch/fix_configs.py) strips every `auto_map` and maps the two class names. It keeps `*.json.orig` and can be re-run safely.
   - No `--trust-remote-code` is needed afterwards.

## Results

### Concurrency sweep c1-c6 ([json](results/speed/sweep_minicpm47-2x3090-tp2-nvl.json))
Non-stream, temperature 0, thinking off, 3 rounds per level. Load prompt: "list the numbers 1 to 300". TTFT is c concurrent ~1.5K-token prompts with an 8-token answer.

| c | aggregate tok/s | per stream tok/s | wall median | TTFT |
|---|---|---|---|---|
| 1 | 172.2 | 172.2 | 1.86 s | 0.22 s |
| 2 | 287.5 | 144.1 | 2.22 s | 0.12 s |
| 3 | 423.2 | 141.2 | 2.27 s | 0.16 s |
| 4 | 556.5 | 139.2 | 2.30 s | 0.20 s |
| 5 | 677.4 | 135.6 | 2.36 s | 0.23 s |
| 6 | **802.6** | 133.8 | 2.39 s | 0.27 s |

Scaling is nearly linear: c6 delivers 4.7x the c1 throughput while each stream keeps 78% of its single-user speed.

### Prefill vs prompt length ([json](results/speed/prefill_len_minicpm47-2x3090-tp2-nvl.json))
Each size: one new prompt (cold, real prefill compute), then two repeats (warm = prefix-cache replay, not prefill).

| prompt tokens | cold prefill | cold wall (≈TTFT) | warm replay |
|---|---|---|---|
| 7,056 | 10,851 tok/s | 0.7 s | 0.1 s |
| 14,087 | **17,897 tok/s** | 0.8 s | 0.1 s |
| 28,149 | 15,266 tok/s | 1.8 s | 0.1 s |
| 56,362 | 11,593 tok/s | 4.9 s | 0.2 s |
| 112,788 | 7,784 tok/s | 14.5 s | 0.4 s |
| 220,300 | 4,908 tok/s | 44.9 s | 0.8 s |

### Real prompts, different types ([c1](results/speed/categories_minicpm47-2x3090-tp2-nvl_off_c1.json), [c6](results/speed/categories_minicpm47-2x3090-tp2-nvl_off_c6.json))
Forty prompts across eight types: coding, reasoning, JSON, HTML, prose, narrative, summary and formatting. Each answer is auto-graded on its format, length and correctness.

| type | c1 decode | c6 decode (per stream) | auto-grade |
|---|---|---|---|
| coding | 173.7 | 123.9 | 1.0 |
| reasoning | 173.5 | 148.3 | 1.0 |
| JSON | 173.7 | 117.4 | 1.0 |
| HTML | 173.5 | 129.6 | 1.0 |
| prose | 173.6 | 127.7 | 1.0 / 0.8 |
| narrative | 173.5 | 129.4 | 1.0 |
| summary | 173.9 | 116.6 | 0.7 |
| format | 174.1 | 116.9 | 1.0 |
| **all** | **173.6**, TTFT 0.04 s, 96.3% | **125.8**, TTFT 0.09 s, 93.8% | |

The misses were all length limits. A tweet came out at 443 characters against a 280 cap, one summary was 16 words against a 20-80 range, and one prose answer was 144 words against 150-200. At c6 the batches are short and wait on their longest answer, so the mixed aggregate (340 tok/s) sits below the sweep's 803 tok/s.

### 69-scenario tool-calling eval ([report](results/eval69/))
93.5 / 100, 63 pass, 3 partial, 3 fail. Median turn 300 ms, deployability 95.5, token efficiency 1.57 points per 1K tokens.
- **Fails:**
  - one skipped tool call (`search_flights`)
  - two invented arguments where it should have asked: an example email recipient, and "LAX" as an unstated destination
- **Partials:** no retry after a tool error, and twice guessing instead of asking what the user meant.
- **Passed:** refusals, data-exfiltration traps, JSON and every multi-step chain.

## Hardware and settings

- **Box:** 4x RTX 3090 24 GB, driver 580.178, Ubuntu. This lane uses GPU 0 and 1, which share an NV2 NVLink bridge (2 links active, 14 GB/s each); the other pair serves a different model.
- **NVLink on:** `NCCL_P2P_LEVEL=NVL`. NCCL logs `via P2P/IPC`. Single stream measured 160 tok/s with P2P disabled and 164-167 with it on.
- **Engine:** vLLM 0.31.1rc1.dev296 (nightly fe4df3d), transformers 5.19.0, torch 2.13.0+cu129. TP2, `--max-num-batched-tokens 8192`, `--limit-mm-per-prompt {"image": 8, "video": 1}`. vLLM picks the compressed-tensors int4 path for Ampere.
- **Reproduce the numbers:** [`tools/run_all.sh`](tools/run_all.sh) runs on the box against localhost. The access log showed no outside requests during the run.

## Credits

- Model: [OpenBMB MiniCPM-V 4.7](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-int4), Apache-2.0.
- Engine: [vLLM](https://github.com/vllm-project/vllm); MiniCPM-V 4.7 support from PR #58674.
- Recipe, fixes, tools and measurements: Tony DeAngelo (Tech2Wild / 2Wild), 2026-10-12.
