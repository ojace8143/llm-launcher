# Example per-model profile.
#
# Copy this file to <model-name-without-.gguf>.sh and edit it, or use:
#   llm models config <model>
#
# Profiles are loaded by `llm launch`, `llm serve`, and router mode after
# config.local.sh, so they override global settings for that model only.
#
# Small model: one GPU, smaller context.
# CONTEXT_SIZE=32768
# NGL=99
# DEVICE="CUDA0"
#
# Large model: two GPUs, 40/60 tensor split, large context.
# CONTEXT_SIZE=262144
# NGL=99
# DEVICE="CUDA0,Vulkan1"
# SPLIT_MODE="layer"
# TENSOR_SPLIT="40,60"
#
# CPU only for one model:
# DEVICE="none"
#
# Splitting is ignored automatically when DEVICE names a single device.
# Available keys:
#   CONTEXT_SIZE NGL THREADS THREADS_BATCH FLASH_ATTN PARALLEL
#   TEMP TOP_P EXTRA_ARGS DEVICE SPLIT_MODE TENSOR_SPLIT MAIN_GPU FIT
#
# EXTRA_ARGS can be a string or a bash array:
# EXTRA_ARGS="-ctk q4_0 -ctv q4_0"
# EXTRA_ARGS=(--repeat-penalty 1.1 --no-mmap)
