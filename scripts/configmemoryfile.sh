#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

MEMORY_CHOICE="$(
    find "$MEMORY_DIR" \
        -maxdepth 1 \
        -type f \
        -printf '%f\n' |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose a memory file: "
)"

[[ -z "$MEMORY_CHOICE" ]] && exit 0

sed -i "s|^MEMORY_FILE=.*|MEMORY_FILE=\"$MEMORY_DIR/$MEMORY_CHOICE\"|" \
    "$LLM_HOME/config/config.sh"

echo "Memory file set to: $MEMORY_CHOICE"
