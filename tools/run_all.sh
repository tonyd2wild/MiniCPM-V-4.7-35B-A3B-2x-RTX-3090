#!/bin/bash
B=http://localhost:8016; M=minicpm-v-4.7; L=minicpm47-2x3090-tp2-nvl
echo "== start $(date)"; date +%s > results/bench_window_start
python3 -u tools/bench_sweep.py $B $M $L --rounds 3 --max-c 6 --out results/sweep_$L.json
python3 -u tools/bench_prefill_len.py $B $M $L --sizes 8000,16000,32000,64000,128000,250000 --reps 3
python3 -u tools/bench_categories.py $B $M $L --concurrency 1
python3 -u tools/bench_categories.py $B $M $L --concurrency 6
date +%s > results/bench_window_end; echo "== done $(date)"
