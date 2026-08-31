#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

DEVICE="$(
    "$LLAMA_BIN" --list-devices |
        sed -n 's/^  \([^:]*\):.*/\1/p' |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose a GPU/device. "
)"

[[ -z "$DEVICE" ]] && exit 0

sed -i "s|^DEVICE=.*|DEVICE=\"$DEVICE\"|" \
    "$LLM_HOME/config/config.sh"

echo "Device set to: $DEVICE"
