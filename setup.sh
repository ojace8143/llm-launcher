#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_HOME="$SCRIPT_DIR"

# Helpers
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }
section() { echo -e "\n${CYAN}::${NC} ${BOLD}$1${NC}"; }
subsection() { echo -e "  ${BLUE}->${NC} $*"; }

banner() {
    clear 2>/dev/null || true
    if command -v figlet >/dev/null 2>&1; then
        figlet -f small "LLMLauncher" 2>/dev/null || figlet "LLMLauncher" 2>/dev/null
    elif command -v toilet >/dev/null 2>&1; then
        toilet -f small "LLMLauncher" 2>/dev/null || toilet "LLMLauncher" 2>/dev/null
    elif command -v banner >/dev/null 2>&1; then
        /usr/bin/banner "LLMLauncher" 2>/dev/null || command banner "LLMLauncher" 2>/dev/null
    else
        echo -e "${MAGENTA}${BOLD}LLMLauncher${NC}"
    fi
    echo -e "${DIM}llm-launcher setup${NC}\n"
}

fzf_menu() {
    local prompt="$1"
    shift
    if (( $# == 0 )); then
        return 1
    fi
    printf '%s\n' "$@" | fzf --height 40% --reverse --border --prompt="$prompt> " 2>/dev/null || true
}

fzf_yesno() {
    local prompt="$1"
    fzf_menu "$prompt" "Yes" "No"
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_pm() {
    if check_cmd xbps-install; then
        PM="xbps"
    elif check_cmd pacman; then
        PM="pacman"
    elif check_cmd emerge; then
        PM="emerge"
    elif check_cmd apt-get; then
        PM="apt"
    elif check_cmd apt; then
        PM="apt"
    else
        PM="unknown"
    fi
}

install_deps() {
    section "Packages"
    detect_pm
    info "Detected package manager: ${BOLD}${PM}${NC}"

    case "$PM" in
        xbps)
            info "Updating and installing dependencies (xbps)..."
            sudo xbps-install -Syu || true
            sudo xbps-install -y git cmake gcc g++ make pkg-config curl fzf || true
            ;;
        pacman)
            info "Updating and installing dependencies (pacman)..."
            sudo pacman -Syu --needed --noconfirm git cmake gcc make pkg-config curl fzf || true
            ;;
        emerge)
            info "Installing dependencies (emerge)..."
            local pkgs=(dev-vcs/git dev-build/cmake sys-devel/gcc sys-devel/make dev-util/pkgconfig net-misc/curl app-shells/fzf)
            sudo emerge --ask=n --oneshot "${pkgs[@]}" || true
            ;;
        apt)
            info "Updating and installing dependencies (apt)..."
            sudo apt-get update || true
            sudo apt-get install -y git cmake gcc g++ make pkg-config curl fzf || true
            ;;
        unknown)
            warn "Unsupported package manager."
            warn "Please install: git, cmake, gcc/g++, make, pkg-config, curl, fzf"
            ;;
    esac

    subsection "Checking dependencies..."
    for dep in git cmake gcc fzf curl make; do
        if check_cmd "$dep"; then
            info "  $dep: ${GREEN}found${NC}"
        else
            warn "  $dep: ${RED}not found${NC}"
        fi
    done
    if ! check_cmd g++ && ! check_cmd clang++; then
        warn "  C++ compiler (g++/clang++): ${YELLOW}not found${NC} (needed for some builds)"
    fi
}

ensure_dirs() {
    section "Directories"
    mkdir -p "$LLM_HOME/config" "$LLM_HOME/memory" "$LLM_HOME/models"
    info "Created/ensured: config/, memory/, models/"
    touch "$LLM_HOME/memory/memory.md" 2>/dev/null || true
    [ -f "$LLM_HOME/memory/example.md" ] || touch "$LLM_HOME/memory/example.md"
}

setup_llama() {
    section "llama.cpp"
    local LLAMA_DIR="$LLM_HOME/llama.cpp"

    if [ ! -d "$LLAMA_DIR" ]; then
        info "llama.cpp not found. Cloning..."
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
        info "Cloned to $LLAMA_DIR"
    else
        info "llama.cpp found at $LLAMA_DIR"
        local upd
        upd=$(fzf_yesno "Update llama.cpp from git?")
        if [ "$upd" = "Yes" ]; then
            subsection "Updating..."
            (cd "$LLAMA_DIR" && git pull --ff-only) || warn "Update failed or not possible"
        fi
    fi

    subsection "Detecting GPU hints..."
    local HAS_CUDA=0 HAS_VULKAN=0
    if check_cmd nvidia-smi; then
        info "  NVIDIA GPU detected (nvidia-smi available)"
    fi
    if check_cmd nvcc; then
        info "  CUDA toolkit detected (nvcc available)"
        HAS_CUDA=1
    fi
    if check_cmd vulkaninfo || check_cmd vulkan-loader-icd-list 2>/dev/null; then
        info "  Vulkan runtime detected"
        HAS_VULKAN=1
    fi
    if [ $HAS_CUDA -eq 0 ] && check_cmd nvidia-smi; then
        warn "  CUDA toolkit (nvcc) not found but NVIDIA GPU present - CUDA build may fail"
    fi
    if [ $HAS_VULKAN -eq 0 ]; then
        warn "  Vulkan tools not clearly detected - Vulkan build may fail"
    fi

    section "Backend Selection"
    info "Choose which backends to compile llama.cpp with"
    local -a BACKEND_OPTS=("CPU")
    if [ $HAS_CUDA -eq 1 ]; then
        BACKEND_OPTS+=("CUDA")
    else
        BACKEND_OPTS+=("CUDA (may fail - no nvcc)")
    fi
    if [ $HAS_VULKAN -eq 1 ]; then
        BACKEND_OPTS+=("Vulkan")
    else
        BACKEND_OPTS+=("Vulkan (may fail - no vulkan)")
    fi
    if [ $HAS_CUDA -eq 1 ] && [ $HAS_VULKAN -eq 1 ]; then
        BACKEND_OPTS+=("CUDA + Vulkan")
        BACKEND_OPTS+=("CUDA, Vulkan")
    elif [ $HAS_CUDA -eq 1 ]; then
        BACKEND_OPTS+=("CUDA + Vulkan (vulkan may fail)")
    elif [ $HAS_VULKAN -eq 1 ]; then
        BACKEND_OPTS+=("CUDA + Vulkan (cuda may fail)")
    else
        BACKEND_OPTS+=("CUDA + Vulkan (may fail)")
        BACKEND_OPTS+=("CUDA, Vulkan (may fail)")
    fi
    BACKEND_OPTS+=("CPU + CUDA + Vulkan")
    BACKEND_OPTS+=("Custom (advanced)")
    local BACKEND
    BACKEND=$(fzf_menu "Select backend" "${BACKEND_OPTS[@]}")
    
    if [ -z "$BACKEND" ] || [ "$BACKEND" = "null" ]; then
        err "No backend selected. Exiting."
        exit 1
    fi
    info "Selected: ${BOLD}$BACKEND${NC}"

    local -a CMAKE_ARGS=("-DCMAKE_BUILD_TYPE=Release")
    case "$BACKEND" in
        "CPU")
            CMAKE_ARGS+=("-DGGML_CUDA=OFF" "-DGGML_VULKAN=OFF")
            ;;
        "CUDA"|"CUDA (may fail - no nvcc)")
            if [ $HAS_CUDA -eq 0 ]; then
                warn "Attempting CUDA build without nvcc - this will likely fail."
            fi
            CMAKE_ARGS+=("-DGGML_CUDA=ON" "-DGGML_VULKAN=OFF")
            ;;
        "Vulkan"|"Vulkan (may fail - no vulkan)")
            if [ $HAS_VULKAN -eq 0 ]; then
                warn "Attempting Vulkan build without Vulkan tools - this may fail."
            fi
            CMAKE_ARGS+=("-DGGML_CUDA=OFF" "-DGGML_VULKAN=ON")
            ;;
        "CUDA + Vulkan"|"CUDA, Vulkan"|"CUDA + Vulkan (vulkan may fail)"|"CUDA + Vulkan (cuda may fail)"|"CUDA + Vulkan (may fail)"|"CUDA, Vulkan (may fail)")
            if [ $HAS_CUDA -eq 0 ]; then
                warn "CUDA requested but nvcc not found."
            fi
            if [ $HAS_VULKAN -eq 0 ]; then
                warn "Vulkan requested but vulkan tools not found."
            fi
            CMAKE_ARGS+=("-DGGML_CUDA=ON" "-DGGML_VULKAN=ON")
            ;;
        "CPU + CUDA + Vulkan")
            if [ $HAS_CUDA -eq 0 ]; then
                warn "CUDA requested but nvcc not found."
            fi
            if [ $HAS_VULKAN -eq 0 ]; then
                warn "Vulkan requested but vulkan tools not found."
            fi
            CMAKE_ARGS+=("-DGGML_CUDA=ON" "-DGGML_VULKAN=ON")
            ;;
        "Custom (advanced)")
            info "Enter CMake flags (space separated), e.g. -DGGML_CUDA=ON -DGGML_VULKAN=ON"
            read -rp "> " CUSTOM
            # shellcheck disable=SC2206
            local extra=($CUSTOM)
            CMAKE_ARGS+=("${extra[@]}")
            ;;
        *)
            CMAKE_ARGS+=("-DGGML_CUDA=OFF" "-DGGML_VULKAN=OFF")
            ;;
    esac

    section "Building llama.cpp"
    info "CMake args: ${CMAKE_ARGS[*]}"
    if ! (cd "$LLAMA_DIR" && cmake -B build "${CMAKE_ARGS[@]}"); then
        err "CMake configuration failed."
        warn "Try selecting just 'CPU' if CUDA/Vulkan are unavailable."
        exit 1
    fi
    if ! (cd "$LLAMA_DIR" && cmake --build build --config Release -j"$(nproc)"); then
        err "Build failed."
        exit 1
    fi
    
    local LLAMA_BIN_PATH="$LLAMA_DIR/build/bin/llama-cli"
    if [ -x "$LLAMA_BIN_PATH" ]; then
        info "Build complete: ${GREEN}$LLAMA_BIN_PATH${NC}"
    else
        warn "llama-cli not found at expected location."
        warn "Check $LLAMA_DIR/build/bin/ for binaries."
    fi
}

configure_env() {
    section "Configuration"
    local CFG="$LLM_HOME/config/config.sh"
    [ -f "$CFG" ] || {
        cat > "$CFG" << 'EOF'
#!/usr/bin/env bash
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_HOME="$(cd "$CONFIG_DIR/.." && pwd)"

LLAMA_HOME="$LLM_HOME/llama.cpp"
LLAMA_BIN="$LLAMA_HOME/build/bin/llama-cli"

MODEL_DIR="$LLM_HOME/models"

DEFAULT_MODEL=""

MEMORY_DIR="$LLM_HOME/memory"
MEMORY_FILE="$MEMORY_DIR/example.md"

CONTEXT_SIZE="16384"

DEVICE=""

EDITOR=""
MEMORY_ENABLED="false"
EOF
        chmod +x "$CFG"
    }

    # Ensure relative paths
    sed -i "s|^CONFIG_DIR=.*|CONFIG_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"|" "$CFG" 2>/dev/null || true
    sed -i "s|^LLM_HOME=.*|LLM_HOME=\"\$(cd \"\$CONFIG_DIR/..\" && pwd)\"|" "$CFG" 2>/dev/null || true
    grep -q '^LLAMA_HOME=' "$CFG" || echo 'LLAMA_HOME="$LLM_HOME/llama.cpp"' >> "$CFG"
    grep -q '^LLAMA_BIN=' "$CFG" || echo 'LLAMA_BIN="$LLAMA_HOME/build/bin/llama-cli"' >> "$CFG"
    grep -q '^MODEL_DIR=' "$CFG" || echo 'MODEL_DIR="$LLM_HOME/models"' >> "$CFG"
    grep -q '^DEFAULT_MODEL=' "$CFG" || echo 'DEFAULT_MODEL=""' >> "$CFG"
    grep -q '^MEMORY_DIR=' "$CFG" || echo 'MEMORY_DIR="$LLM_HOME/memory"' >> "$CFG"
    grep -q '^MEMORY_FILE=' "$CFG" || echo 'MEMORY_FILE="$MEMORY_DIR/example.md"' >> "$CFG"
    grep -q '^CONTEXT_SIZE=' "$CFG" || echo 'CONTEXT_SIZE="16384"' >> "$CFG"
    grep -q '^DEVICE=' "$CFG" || echo 'DEVICE=""' >> "$CFG"
    grep -q '^EDITOR=' "$CFG" || echo 'EDITOR=""' >> "$CFG"
    grep -q '^MEMORY_ENABLED=' "$CFG" || echo 'MEMORY_ENABLED="false"' >> "$CFG"

    subsection "Editor"
    local EDITOR_CHOICE
    EDITOR_CHOICE=$(fzf_menu "Select editor" "nvim" "vim" "vi" "nano" "emacs" "hx" "code")
    if [ -n "$EDITOR_CHOICE" ] && [ "$EDITOR_CHOICE" != "null" ]; then
        sed -i "s|^EDITOR=.*|EDITOR=\"$EDITOR_CHOICE\"|" "$CFG"
        info "Editor set: $EDITOR_CHOICE"
    fi

    subsection "Long term memory"
    local MEM_CHOICE
    MEM_CHOICE=$(fzf_yesno "Enable/use long term memory file?")
    if [ "$MEM_CHOICE" = "Yes" ]; then
        sed -i "s|^MEMORY_ENABLED=.*|MEMORY_ENABLED=\"true\"|" "$CFG"
        mkdir -p "$LLM_HOME/memory"
        touch "$LLM_HOME/memory/memory.md"
        source "$CFG" 2>/dev/null || true
        local ED
        ED=$(grep '^EDITOR=' "$CFG" | cut -d'"' -f2)
        if [ -n "$ED" ] && check_cmd "$ED"; then
            local edit_now
            edit_now=$(fzf_yesno "Edit memory file now?")
            if [ "$edit_now" = "Yes" ]; then
                "$ED" "$LLM_HOME/memory/example.md" 2>/dev/null || "$ED" "$LLM_HOME/memory/memory.md"
            fi
        fi
    else
        sed -i "s|^MEMORY_ENABLED=.*|MEMORY_ENABLED=\"false\"|" "$CFG"
    fi

    subsection "Models"
    shopt -s nullglob
    local MODELS=("$LLM_HOME/models"/*.gguf)
    shopt -u nullglob
    if (( ${#MODELS[@]} == 0 )); then
        warn "No .gguf models found in models/"
        local DL
        DL=$(fzf_yesno "Download a default model (Qwen3VL-8B-Instruct-Q4_K_M.gguf)?")
        if [ "$DL" = "Yes" ]; then
            info "Downloading..."
            curl -L -o "$LLM_HOME/models/Qwen3VL-8B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/main/Qwen3VL-8B-Instruct-Q4_K_M.gguf" || warn "Download failed"
            if [ -f "$LLM_HOME/models/Qwen3VL-8B-Instruct-Q4_K_M.gguf" ]; then
                sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"Qwen3VL-8B-Instruct-Q4_K_M.gguf\"|" "$CFG"
                info "Default model set."
            fi
        else
            sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"\"|" "$CFG"
        fi
    else
        info "Found ${#MODELS[@]} model(s)"
        local names=()
        for m in "${MODELS[@]}"; do names+=("$(basename "$m")"); done
        local DEF
        DEF=$(fzf_menu "Select default model" "${names[@]}")
        if [ -n "$DEF" ] && [ "$DEF" != "null" ]; then
            sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"$DEF\"|" "$CFG"
            info "Default model: $DEF"
        else
            sed -i "s|^DEFAULT_MODEL=.*|DEFAULT_MODEL=\"\"|" "$CFG"
        fi
    fi

    touch "$LLM_HOME/config/.configured"
    info "Configuration saved to $CFG"
}

post_setup() {
    section "Finishing up"
    chmod +x "$LLM_HOME/llm" 2>/dev/null || true
    chmod +x "$LLM_HOME/setup.sh" 2>/dev/null || true

    local SYM
    SYM=$(fzf_yesno "Create symlink for 'llm' in PATH (~/.local/bin)?")
    if [ "$SYM" = "Yes" ]; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$LLM_HOME/llm" "$HOME/.local/bin/llm"
        info "Symlinked: $HOME/.local/bin/llm -> $LLM_HOME/llm"
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            warn "Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
    fi

    echo -e "\n${GREEN}${BOLD}Setup complete!${NC}"
    echo -e "${DIM}Usage:${NC}"
    echo -e "  ${CYAN}llm help${NC}    - Show help"
    echo -e "  ${CYAN}llm config show${NC}"
    echo -e "  ${CYAN}llm launch${NC} / ${CYAN}llm launch select${NC}"
    echo -e "\n${DIM}Config:${NC} $LLM_HOME/config/config.sh"
}

main() {
    banner
    ensure_dirs
    install_deps
    setup_llama
    configure_env
    post_setup
}

main "$@"
