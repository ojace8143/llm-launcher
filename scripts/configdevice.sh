#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

SELECTION="$(
    "$LLAMA_BIN" --list-devices |
        sed -n 's/^  \([^:]*\): \(.*\)$/\1\t\2/p' |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose a GPU/device. "
)"

[[ -z "$SELECTION" ]] && exit 0

DEVICE="${SELECTION%%$'\t'*}"

sed -i "s|^DEVICE=.*|DEVICE=\"$DEVICE\"|" \
    "$LLM_HOME/config/config.sh"

echo "Device set to: $DEVICE"
