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
    elif command -v apt >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt-get"
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
                fzf
            ;;

        pacman)
            sudo pacman -Syu --needed \
                git \
                cmake \
                gcc \
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
                if emerge -q "$pkg"; then
                    echo "$pkg already installed"
                else
                    EMERGE_PACKAGES+=("$pkg")
                fi
            done

            if [[ ${#EMERGE_PACKAGES[@]} -gt 0 ]]; then
                sudo emerge --ask --oneshot "${EMERGE_PACKAGES[@]}"
            fi
            ;;

        apt)
            sudo apt-get update
            sudo apt-get install -y \
                git \
                cmake \
                gcc \
                fzf
            ;;
        esac

    check_dependency git
    check_dependency cmake
    check_dependency gcc
    check_dependency fzf

    if [[ ! -f "$LLAMA_HOME/CMakeLists.txt" ]]; then

        echo "llama.cpp not found."
        echo "Cloning llama.cpp..."
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_HOME"

    else
        echo "llama.cpp already exists; continuing"
    fi

    cd "$LLAMA_HOME"

    echo ""
    echo "Select llama.cpp backend(s):"

    BACKEND=$(printf '%s\n' \
        "CPU" \
        "CUDA" \
        "Vulkan" \
        "CUDA + Vulkan" |
        fzf --height 40% --reverse --prompt="Backend: ")

    case "$BACKEND" in
        CPU)
            CMAKE_ARGS=(
                -DCMAKE_BUILD_TYPE=Release
                -DGGML_CUDA=OFF
                -DGGML_VULKAN=OFF
            )
            ;;

        CUDA)
            CMAKE_ARGS=(
                -DCMAKE_BUILD_TYPE=Release
                -DGGML_CUDA=ON
            -DGGML_VULKAN=OFF
            )
            ;;

        Vulkan)
            CMAKE_ARGS=(
                -DCMAKE_BUILD_TYPE=Release
                -DGGML_CUDA=OFF
                -DGGML_VULKAN=ON
            )
            ;;

        "CUDA + Vulkan")
            CMAKE_ARGS=(
                -DCMAKE_BUILD_TYPE=Release
                -DGGML_CUDA=ON
                -DGGML_VULKAN=ON
            )
            ;;

        *)
            echo "No backend selected; exiting"
            exit 1
           ;;
    esac

    echo ""
    echo "Configuring llama.cpp with: $BACKEND"

    cmake -B build "${CMAKE_ARGS[@]}"
    cmake --build build --config Release -j"$(nproc)"

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

    MODELS=("$MODEL_DIR"/*.gguf)

    if [[ ! -e "${MODELS[0]}" ]]; then
        echo "No GGUF models found"

        DOWNLOAD_MODEL=$(printf '%s\n' Yes No |
            fzf --height 40% --reverse --prompt="Download a default model? ")

        if [[ "$DOWNLOAD_MODEL" == "Yes" ]]; then
            curl -L -o "$MODEL_DIR/Qwen3VL-8B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/main/Qwen3VL-8B-Instruct-Q4_K_M.gguf"

            DEFAULT_MODEL="Qwen3VL-8B-Instruct-Q4_K_M.gguf"

            sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"$DEFAULT_MODEL\"|" \
                "$LLM_HOME/config/config.sh"
        else
            sed -i 's|^DEFAULT_MODEL=.*|DEFAULT_MODEL=""|' \
                "$LLM_HOME/config/config.sh"
        fi
    else
        DEFAULT_MODEL=$(find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" -printf "%f\n" |
            fzf --height 40% --reverse --prompt="Select default model: ")

        sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"$DEFAULT_MODEL\"|" \
            "$LLM_HOME/config/config.sh"
    fi

    #marks as first time setup complete
    touch "$LLM_HOME/config/.configured"
fi
