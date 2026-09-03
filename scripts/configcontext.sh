#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

CONTEXT="$(
    printf '%s\n' \
        "1024" \
        "2048" \
        "4096" \
        "8192" \
        "16384" |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose context size: "
)"

[[ -z "$CONTEXT" ]] && exit 0

sed -i "s|^CONTEXT_SIZE=.*|CONTEXT_SIZE=\"$CONTEXT\"|" \
    "$LLM_HOME/config/config.sh"

echo "Context size set to: $CONTEXT"
