#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

if [[ -z "$DEFAULT_MODEL" ]]; then
    echo "No default model configured."
    echo "Run 'llm launch select' to choose a model."
    exit 1
fi

MODEL="$MODEL_DIR/$DEFAULT_MODEL"

if [[ ! -f "$MODEL" ]]; then
    echo "Default model not found:"
    echo "$MODEL"
    exit 1
fi

LLAMA_ARGS=(
    -m "$MODEL"
    -ngl 99
    -c "$CONTEXT_SIZE"
)

if [[ -n "$DEVICE" ]]; then
    LLAMA_ARGS+=(--device "$DEVICE")
fi

if [[  -f "$MEMORY_FILE" ]]; then
    LLAMA_ARGS+=(--system-prompt-file "$MEMORY_FILE")
else
    echo "MEMORY FILE NOT FOUND, EXITING"
    exit 1
fi

"$LLAMA_BIN" "${LLAMA_ARGS[@]}"
