#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

while true; do

    OPTION="$(
        printf '%s\n' \
            "Default model" \
            "GPU/device" \
            "Context size" \
            "GPU layers" \
            "Memory File" \
            "Editor" \
            "Exit" |
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
            "$LLM_HOME"/scripts/configcontext.sh
            ;;

        "GPU layers")
            echo "GPU layers configuration not implemented yet."
            ;;

        "Memory File")
            "$LLM_HOME/scripts/configmemoryfile.sh"
            ;;

        "Editor")
            "$LLM_HOME/scripts/configeditor.sh"
            ;;
        
        "Exit")
            exit 0
            ;;
        "")
            exit 0
            ;;

    esac
done
