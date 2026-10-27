# Example per-model profile.
#
# Copy this file to <model-name-without-.gguf>.sh and edit it.
# Profiles are loaded by `llm launch <model>` and `llm serve --model <model>`
# after config.local.sh, so they override global settings for that model.
#
# CONTEXT_SIZE=32768
# NGL=99
# DEVICE="CUDA0,CUDA1"
# SPLIT_MODE="layer"
# TENSOR_SPLIT="3,1"
# THREADS=8
# FLASH_ATTN="on"
# TEMP=0.2
# TOP_P=0.9
#
# EXTRA_ARGS is a bash array here, so quoting works:
# EXTRA_ARGS=(--repeat-penalty 1.1 --no-mmap)
