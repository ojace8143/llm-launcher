#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

OPTION="$(
    printf '%s\n' \
        "Default model" \
        "GPU/device" \
        "Context size" \
        "GPU layers" \
        "Long term memory" \
        "Editor" |
        fzf \
            --height 40% \
            --reverse \
            --border \
            --prompt="Choose a configuration option. "
)"

case "$OPTION" in

    "Default model")
        "$LLM_HOME/scripts/configdefault.sh"
        ;;

    "GPU/device")
        "$LLM_HOME/scripts/configdevice.sh"
        ;;

    "Context size")
        echo "Context size configuration not implemented yet."
        ;;

    "GPU layers")
        echo "GPU layers configuration not implemented yet."
        ;;

    "Long term memory")
        echo "Long term memory configuration not implemented yet."
        ;;

    "Editor")
        echo "Editor configuration not implemented yet."
        ;;

    "")
        exit 0
        ;;

esac
