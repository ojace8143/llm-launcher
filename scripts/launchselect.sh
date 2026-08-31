#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

MODEL="$(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' |
    fzf --prompt="Choose a model to launch. " --height=40% --border)"

[[ -z "$MODEL" ]] && exit 0

"$LLAMA_BIN" \
    -m "$MODEL_DIR/$MODEL" \
    --device "$DEVICE" \
    -ngl 99 \
    -c 2048
