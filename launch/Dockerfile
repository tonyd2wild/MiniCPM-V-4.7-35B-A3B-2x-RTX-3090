# vLLM nightly that contains MiniCPM-V 4.7 support (vllm-project/vllm PR #58674, merged 2026-10-11).
# No tagged release had it on 2026-10-12, so the image is pinned to the exact nightly build.
FROM vllm/vllm-openai:cu129-nightly-fe4df3df0eb703862c686b256e9fe44fa94c8945
# torchcodec 0.17 in this cu129 image is linked against CUDA 13 (libcudart.so.13, libnvrtc.so.13).
# Importing it raises OSError, which vLLM's audio/video import guard (ImportError, RuntimeError) does not catch,
# so the server dies before loading the model. Removing it makes the guard fall back cleanly.
RUN pip uninstall -y torchcodec
