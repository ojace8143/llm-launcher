#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

MODEL="$(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' |
    fzf --prompt="Choose a model to launch. " --height=40% --border)"

[[ -z "$MODEL" ]] && exit 0

LLAMA_ARGS=(
    -m "$MODEL_DIR/$MODEL"
    -ngl 99
    -c "$CONTEXT_SIZE" 
)

if [[ -n "$DEVICE" ]]; then
    LLAMA_ARGS+=(--device "$DEVICE")
fi

if [[ -f "$MEMORY_FILE" ]]; then
    LLAMA_ARGS+=(--system-prompt-file "$MEMORY_FILE")
else
    echo "MEMORY FILE NOT FOUND, EXITING"
    exit 1
fi

"$LLAMA_BIN" "${LLAMA_ARGS[@]}"
