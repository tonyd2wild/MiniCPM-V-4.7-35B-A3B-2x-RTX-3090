# MiniCPM-V 4.7 35B-A3B on 2x RTX 3090: 356 tok/s single stream on real prompts with the DSpark draft (2.05x), full 262K context, in vLLM

OpenBMB's first MoE vision model (`openbmb/MiniCPM-V-4.7-35B-A3B-int4`, 22.6 GB) served on two RTX 3090s (48 GB VRAM) joined by an NVLink bridge, tensor parallel 2, with an OpenAI-compatible API, tool calling and images. Deployed the day after vLLM merged support (2026-10-12). Every number below was measured on the box.

| | Result |
|---|---|
| **With the DSpark draft (default since 2026-10-12, 11 PM)** | Real prompts c1: **356.0 tok/s** median decode vs 173.6 plain (**2.05x**), code 397, JSON/HTML ~600 · c6: **274.2 tok/s** per stream vs 125.8, mixed aggregate 657 vs 340 · see [DSpark](#dspark-speculative-decoding) |
| Plain (no draft), single stream (c1) | **172.2 tok/s** end to end, 1.86 s for a 300-number list |
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
# 4. optional speculative-decoding draft (0.78 GB), used by default; DSPARK=0 turns it off
HF_HUB_DISABLE_XET=1 hf download openbmb/MiniCPM-V-4.7-35B-A3B-DSpark --local-dir ~/models/MiniCPM-V-4.7-35B-A3B-DSpark
# 5. serve on GPU 0+1, port 8016
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

## DSpark speculative decoding

OpenBMB ships a matching draft, [`openbmb/MiniCPM-V-4.7-35B-A3B-DSpark`](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-DSpark): 5 layers, 389M params, BF16, 0.78 GB. It reads hidden states from target layers 3/11/19/27/35 and proposes a block of tokens that the big model verifies in one pass. The pinned nightly already supports `method: "dspark"`. No extra patches are needed:

```
--max-num-seqs 16 --speculative-config '{"method":"dspark","model":"/models/MiniCPM-V-4.7-35B-A3B-DSpark","num_speculative_tokens":7}'
```

### Draft length: 7 beats the model card's 15
The card's example uses 15 tokens per step. On our int4 target (the draft was trained against the BF16 model), 15 made structured output fly but made free-form writing *slower* than no draft. Most of the 15 guesses get thrown away on prose, and verifying them costs time. 7 keeps most of the structured-output gain and stops the prose loss.

Real prompts, single stream, decode tok/s (median of 5 per type; [plain](results/speed/categories_minicpm47-2x3090-tp2-nvl_off_c1.json), [15](results/speed/categories_minicpm47-2x3090-tp2-nvl-dspark_off_c1.json), [7](results/speed/categories_minicpm47-2x3090-tp2-nvl-dspark7_off_c1.json), [7 at c6](results/speed/categories_minicpm47-2x3090-tp2-nvl-dspark7_off_c6.json)):

| type | plain c1 | draft 15, c1 | **draft 7, c1** | 7 vs plain | plain c6 / stream | draft 7, c6 / stream |
|---|---|---|---|---|---|---|
| coding | 173.7 | 222.1 | **396.6** | 2.28x | 123.9 | 312.5 |
| reasoning | 173.5 | 656.2 | **564.1** | 3.25x | 148.3 | 404.5 |
| JSON | 173.7 | 832.1 | **614.7** | 3.54x | 117.4 | 371.3 |
| HTML | 173.5 | 727.5 | **598.6** | 3.45x | 129.6 | 394.5 |
| prose | 173.6 | 159.3 | **198.7** | 1.14x | 127.7 | 144.9 |
| narrative | 173.5 | 137.8 | **177.0** | 1.02x | 129.4 | 144.6 |
| summary | 173.9 | 192.9 | **244.6** | 1.41x | 116.6 | 140.1 |
| format (≤20-token answers) | 174.1 | 128.7 | **168.9** | 0.97x | 116.9 | 87.1 |
| **median, all 40** | **173.6** | **247.9** | **356.0** | **2.05x** | **125.8** | **274.2** |

The c6 mixed aggregate went from 340 to **657 tok/s**. Auto-grade was 96.3% plain and 93.2% with the draft (7). The extra misses were one prose answer at 141 words against a 150-200 range and one story with a single line of dialogue. That is the same output-length style of miss as the plain run's. Speculative decoding verifies every token against the big model, so the answers are the big model's own. The small differences come from batch-shape numerics.

### Concurrency sweep with the draft (best case) ([json](results/speed/sweep_minicpm47-2x3090-tp2-nvl-dspark7.json))
This is the same load as the plain sweep, "list the numbers 1 to 300". That task is almost perfectly predictable, so this is the draft's **best case**, not typical speed. Use the real-prompt table above for typical speed.

| c | plain aggregate | **draft 7 aggregate** | per stream | wall median | TTFT |
|---|---|---|---|---|---|
| 1 | 172.2 | **654.9** | 655.2 | 0.49 s | 0.20 s |
| 2 | 287.5 | **1,223.8** | 612.4 | 0.52 s | 0.22 s |
| 3 | 423.2 | **1,689.7** | 563.9 | 0.57 s | 0.34 s |
| 4 | 556.5 | **2,132.9** | 534.0 | 0.60 s | 0.42 s |
| 5 | 677.4 | **2,276.6** | 472.8 | 0.68 s | 0.52 s |
| 6 | 802.6 | **2,584.9** | 432.7 | 0.74 s | 0.59 s |

### What the draft costs
- **KV pool:** 612,385 → 361,656 tokens. The draft's 5 full-attention layers add a lot per token next to a hybrid target that has only 10 full-attention layers, and its CUDA graphs take memory too. A full 262K request still fits (1.38x). vLLM also logs that no KV group was identified as the draft's.
- **Cold prefill** ([json](results/speed/prefill_len_minicpm47-2x3090-tp2-nvl-dspark7.json)): 10.4K tok/s at 14K tokens (plain 17.9K) · 8.8K at 56K (11.6K) · 8.3K at 113K (7.8K) · 5.2K at 220K (4.9K). Short prompts pay the draft's own prefill. Long prompts are a wash.
- **Images:** vLLM warns that the draft does not take the target's multimodal embeddings, so on image prompts it drafts from text only. Acceptance on vision prompts will be lower than the card's MMMU/OCRBench numbers. We have not measured it yet.
- **Rollback:** `DSPARK=0 bash launch/serve.sh`.

## Results (plain, no draft)

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
- Draft: [OpenBMB MiniCPM-V-4.7-35B-A3B-DSpark](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-DSpark), Apache-2.0; method from [arXiv 2607.05147](https://arxiv.org/abs/2607.05147).
- Recipe, fixes, tools and measurements: Tony DeAngelo (Tech2Wild / 2Wild), 2026-10-12.
