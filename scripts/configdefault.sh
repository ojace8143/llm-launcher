#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

MODEL="$(
    find "$MODEL_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.gguf' \
        -printf '%f\n' |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose a default model. "
)"

[[ -z "$MODEL" ]] && exit 0

sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"$MODEL\"|" \
    "$LLM_HOME/config/config.sh"

echo "Default model set to: $MODEL"
