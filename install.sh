#!/usr/bin/env bash
set -euo pipefail

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$LLM_HOME/config"
mkdir -p "$LLM_HOME/memory"
mkdir -p "$LLM_HOME/models"

source "$LLM_HOME/config/config.sh"

touch "$MEMORY_DIR/memory.md"


check_dependency() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "$1 found"
    else
        echo "$1 not found, quitting"
        exit 1
    fi
}


#install script

export PATH="$LLM_HOME:$PATH"
chmod +x "$LLM_HOME/llm"

if [[ ! -f "$LLM_HOME/config/.configured" ]]; then
    # first-time setup
    echo "welcome to first time setup"
    echo "this install is made for xbps, pacman and emerge"
    echo ""
    echo "Checking Dependencies. . ."

    if command -v xbps-install >/dev/null 2>&1; then
        PACKAGE_MANAGER="xbps"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v emerge >/dev/null 2>&1; then
        PACKAGE_MANAGER="emerge"
    else
        echo ""
        echo "Unsupported package manager detected; check README.md for all dependencies and how to install"
        echo "Supported package managers: xbps, pacman, emerge"
        exit 1
    fi

    echo ""
    echo "Detected package manager: $PACKAGE_MANAGER"
    
    case "$PACKAGE_MANAGER" in
        xbps)
            sudo xbps-install -Syu
            sudo xbps-install -y \
                git \
                cmake \
                gcc \
                make \
                fzf
            ;;

        pacman)
            sudo pacman -Syu --needed \
                git \
                cmake \
                gcc \
                make \
                fzf
            ;;
        emerge)
            EMERGE_PACKAGES=()

            for pkg in \
                dev-vcs/git \
                dev-build/cmake \
           sys-devel/gcc \
            app-shells/fzf
        do
            if has_version "$pkg"; then
                echo "$pkg already installed"
            else
                EMERGE_PACKAGES+=("$pkg")
            fi
        done

        if [[ ${#EMERGE_PACKAGES[@]} -gt 0 ]]; then
            sudo emerge --ask --oneshot "${EMERGE_PACKAGES[@]}"
        fi
        ;;
    esac

    check_dependency git
    check_dependency cmake
    check_dependency gcc
    check_dependency make
    check_dependency fzf

    if [[ ! -d "$LLAMA_HOME" ]]; then
        echo "llama.cpp not found."
        echo "Cloning llama.cpp..."
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_HOME"
    else
        echo "llama.cpp already exists; continuing"
    fi

    cd "$LLAMA_HOME"
    cmake -B build

    if [[ $? -ne 0 ]]; then
        echo "CMake configuration failed; exiting"
        exit 1
    fi

    cmake --build build --config Release -j"$(nproc)"

    if [[ $? -ne 0 ]]; then
        echo "llama.cpp build failed; exiting"
        exit 1
    fi

    if [[ -x "$LLAMA_BIN" ]]; then
        echo "llama.cpp build completed; continuing"
    else
        echo "llama-cli was not created; exiting"
        exit 1
    fi

    EDITOR=$(printf '%s\n' nvim vim vi nano | 
        fzf --height 40% --reverse --prompt="Select editor: ")
    echo "EDITOR=\"$EDITOR\"" >> "$LLM_HOME/config/config.sh"

    MEMORY_ENABLED=$(printf '%s\n' Yes No |
        fzf --height 40% --reverse --prompt="Use Long Term Memory File?")

    case "$MEMORY_ENABLED" in
        Yes) MEMORY_ENABLED=true ;;
        No) MEMORY_ENABLED=false ;;
    esac

    echo "MEMORY_ENABLED=\"$MEMORY_ENABLED\"" >> "$LLM_HOME/config/config.sh"

    if [[ "$MEMORY_ENABLED" == "true" ]]; then
        echo "editing default long term memory file"
        sleep 5s
        "$EDITOR" "$MEMORY_FILE"
    fi


    #marks as first time setup complete
    touch "$LLM_HOME/config/.configured"
fi
