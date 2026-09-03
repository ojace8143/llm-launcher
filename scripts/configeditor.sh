#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

EDITOR_CHOICE="$(
    printf '%s\n' \
        nvim \
        vim \
        vi \
        nano |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose an editor: "
)"

[[ -z "$EDITOR_CHOICE" ]] && exit 0

sed -i "s|^EDITOR=.*|EDITOR=\"$EDITOR_CHOICE\"|" \
    "$LLM_HOME/config/config.sh"

echo "Editor set to: $EDITOR_CHOICE"
