#!/usr/bin/env python3
"""Make openbmb/MiniCPM-V-4.7-35B-A3B-int4 load in vLLM without --trust-remote-code.

usage: python3 fix_configs.py /path/to/MiniCPM-V-4.7-35B-A3B-int4

Two problems in the int4 repo's JSON configs (2026-10-12):
  1. auto_map entries (top level AND nested inside processor_config.json's image_processor / video_processor)
     point at remote-code files (processing_minicpmv4_7.py, image_processing_minicpmv4_7.py, ...) that the repo
     does not ship. Transformers then refuses to load ("contains custom code which must be executed").
  2. image_processor_type / video_processor_type say MiniCPMV4_7ImageProcessor / MiniCPMV4_7VideoProcessor.
     Transformers 5.19 has no such classes: its auto mapping for model_type minicpmv4_7 uses the 4.6 processors
     (MiniCPMV4_6ImageProcessor / MiniCPMV4_6VideoProcessor) together with the native MiniCPMV4_7Processor.
The script strips every auto_map and maps the two class names. Originals are kept as *.json.orig. Idempotent.
"""
import json, os, shutil, sys

CLASS_MAP = {"MiniCPMV4_7ImageProcessor": "MiniCPMV4_6ImageProcessor",
             "MiniCPMV4_7VideoProcessor": "MiniCPMV4_6VideoProcessor"}
FILES = ["processor_config.json", "preprocessor_config.json", "tokenizer_config.json", "config.json", "generation_config.json"]


def fix(o):
    if isinstance(o, dict):
        o.pop("auto_map", None)
        for k, v in list(o.items()):
            if k in ("image_processor_type", "video_processor_type") and v in CLASS_MAP:
                o[k] = CLASS_MAP[v]
            else:
                fix(v)
    elif isinstance(o, list):
        for v in o:
            fix(v)


def main(d):
    for f in FILES:
        p = os.path.join(d, f)
        if not os.path.exists(p):
            continue
        data = json.load(open(p))
        before = json.dumps(data, sort_keys=True)
        fix(data)
        if json.dumps(data, sort_keys=True) != before:
            if not os.path.exists(p + ".orig"):
                shutil.copy(p, p + ".orig")
            json.dump(data, open(p, "w"), indent=2)
            print("fixed", f)
        else:
            print("ok   ", f)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
