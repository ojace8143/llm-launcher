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

"$LLAMA_BIN" \
    -m "$MODEL" \
    -ngl 99 \
    -c 2048
