#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_HOME="$SCRIPT_DIR"
export LLM_HOME

# shellcheck source=/dev/null
source "$LLM_HOME/lib/common.sh"

LLM_CONFIG="$LLM_HOME/config/config.local.sh"
export LLM_CONFIG

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

ASSUME_YES=0
NO_DEPS=0
FRESH=0
BACKEND_OVERRIDE=""

usage() {
    cat <<EOF
${BOLD}setup.sh${NC} — install and configure llm-launcher

Usage: ./setup.sh [options]

  -y, --yes             Accept defaults (non-interactive where possible)
      --no-deps         Skip package installation
      --backend=NAME    cpu | cuda | vulkan | cuda+vulkan | custom
      --fresh           Delete the llama.cpp build directory first
  -h, --help            Show this help

${DIM}Examples:${NC}
  ./setup.sh
  ./setup.sh --backend=vulkan
  ./setup.sh --yes --no-deps --backend=cpu
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --fresh) FRESH=1 ;;
        --backend=*) BACKEND_OVERRIDE="${1#*=}" ;;
        --backend)
            [[ $# -ge 2 ]] || die "--backend requires a value"
            BACKEND_OVERRIDE="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

# Load existing settings so model paths and defaults are available.
if [[ -f "$LLM_HOME/config/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LLM_HOME/config/config.sh"
fi

# ---------------------------------------------------------------------------
# Banner and prompts
# ---------------------------------------------------------------------------

banner() {
    [[ -t 1 ]] && clear 2>/dev/null || true
    printf '%s%s' "$MAGENTA" "$BOLD"
    llm_ascii_art
    printf '%s%sllm-launcher setup%s\n\n' "$NC" "$DIM" "$NC"
}

interactive() { [[ -t 0 && -t 1 ]]; }

menu() {
    local prompt="$1"
    shift
    if (( $# == 0 )); then
        return 1
    fi
    if ! interactive; then
        printf '%s\n' "$1"
        return 0
    fi
    printf '%s\n' "$@" |
        fzf --height 40% --reverse --border --prompt="$prompt> " 2>/dev/null || true
}

ask_yesno() {
    local prompt="$1"
    local default="${2:-No}"
    if (( ASSUME_YES )) || ! interactive; then
        printf '%s\n' "$default"
        return 0
    fi
    local choice
    choice="$(
        printf '%s\n' Yes No |
            fzf --height 40% --reverse --border --prompt="$prompt> " 2>/dev/null || true
    )"
    printf '%s\n' "${choice:-$default}"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

detect_pm() {
    if have_cmd xbps-install; then
        PM="xbps"
    elif have_cmd pacman; then
        PM="pacman"
    elif have_cmd emerge; then
        PM="emerge"
    elif have_cmd apt-get; then
        PM="apt"
    elif have_cmd apt; then
        PM="apt"
    else
        PM="unknown"
    fi
}

install_deps() {
    section "Packages"
    detect_pm
    info "Detected package manager: ${BOLD}${PM}${NC}"

    if (( NO_DEPS )); then
        info "Skipping package installation (--no-deps)"
    elif [[ "$PM" == "unknown" ]]; then
        warn "Unsupported package manager."
        warn "Install manually: git cmake make gcc/g++ pkg-config curl fzf"
    elif [[ "$(ask_yesno "Install required packages with $PM?" Yes)" == "Yes" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            SUDO=""
        elif have_cmd sudo; then
            SUDO="sudo"
        else
            warn "sudo not found and not running as root; skipping package installation"
            SUDO=""
        fi

        if [[ -n "$SUDO" || "$(id -u)" -eq 0 ]]; then
            case "$PM" in
                xbps)
                    subsection "Installing packages (xbps)..."
                    local -a missing_pkgs=() pkg
                    for pkg in git cmake gcc make pkgconf curl fzf; do
                        xbps-query -l "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
                    done
                    if (( ${#missing_pkgs[@]} > 0 )); then
                        $SUDO xbps-install -Sy "${missing_pkgs[@]}" ||
                            warn "Package installation reported errors"
                    else
                        info "All packages already installed"
                    fi
                    ;;
                pacman)
                    subsection "Installing packages (pacman)..."
                    $SUDO pacman -S --needed --noconfirm git cmake gcc make pkgconf curl fzf ||
                        warn "Package installation reported errors"
                    ;;
                emerge)
                    subsection "Installing packages (emerge)..."
                    $SUDO emerge --ask=n --oneshot \
                        dev-vcs/git dev-build/cmake sys-devel/gcc sys-devel/make \
                        dev-util/pkgconf net-misc/curl app-shells/fzf ||
                        warn "Package installation reported errors"
                    ;;
                apt)
                    subsection "Installing packages (apt)..."
                    $SUDO apt-get update || warn "apt-get update failed"
                    $SUDO apt-get install -y git cmake gcc g++ make pkg-config curl fzf ||
                        warn "Package installation reported errors"
                    ;;
            esac
        fi
    else
        info "Skipping package installation"
    fi

    subsection "Checking dependencies..."
    local missing=0 dep
    for dep in git cmake make curl fzf; do
        if have_cmd "$dep"; then
            info "  $dep: found"
        else
            warn "  $dep: not found"
            missing=1
        fi
    done

    if have_cmd pkg-config || have_cmd pkgconf; then
        info "  pkg-config: found"
    else
        warn "  pkg-config: not found"
    fi

    if have_cmd g++ || have_cmd c++ || have_cmd clang++; then
        info "  C++ compiler: found"
    else
        warn "  C++ compiler: not found"
        missing=1
    fi

    if (( missing )); then
        die "Missing required build tools. Install them and re-run setup."
    fi
    if interactive && ! have_cmd fzf; then
        die "fzf is required for the setup menus."
    fi
}

# ---------------------------------------------------------------------------
# llama.cpp
# ---------------------------------------------------------------------------

detect_backends() {
    HAS_CUDA=0
    HAS_VULKAN=0

    # If CUDA_HOME is not configured, look in common user-local locations.
    if [[ -z "${CUDA_HOME:-}" ]]; then
        local cuda_dir
        for cuda_dir in "$HOME"/Src/cuda-* /opt/cuda; do
            if [[ -x "$cuda_dir/bin/nvcc" ]]; then
                CUDA_HOME="$cuda_dir"
                export CUDA_HOME
                export PATH="$CUDA_HOME/bin:$PATH"
                export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                break
            fi
        done
    fi

    if have_cmd nvcc || [[ -n "${CUDA_HOME:-}" && -x "$CUDA_HOME/bin/nvcc" ]] ||
        [[ -x /opt/cuda/bin/nvcc ]]; then
        HAS_CUDA=1
    fi

    if compgen -G "/usr/share/vulkan/icd.d/*.json" >/dev/null 2>&1 ||
        compgen -G "/etc/vulkan/icd.d/*.json" >/dev/null 2>&1 ||
        have_cmd vulkaninfo ||
        { have_cmd ldconfig && ldconfig -p 2>/dev/null | grep -q "libvulkan"; }; then
        HAS_VULKAN=1
    fi
}

normalize_backend() {
    local value="${1:-}"
    value="${value,,}"
    value="${value// /}"
    case "$value" in
        cpu) printf 'CPU' ;;
        cuda) printf 'CUDA' ;;
        vulkan) printf 'Vulkan' ;;
        cuda+vulkan|vulkan+cuda|cudavulkan) printf 'CUDA + Vulkan' ;;
        custom) printf 'Custom' ;;
        *) printf '' ;;
    esac
}

choose_backend() {
    local backend
    if [[ -n "$BACKEND_OVERRIDE" ]]; then
        backend="$(normalize_backend "$BACKEND_OVERRIDE")"
        [[ -n "$backend" ]] || die "Unknown backend: $BACKEND_OVERRIDE"
    else
        backend="$(menu "Select backend" \
            "CPU" \
            "CUDA" \
            "Vulkan" \
            "CUDA + Vulkan" \
            "Custom")"
        [[ -n "$backend" ]] || die "No backend selected."
    fi
    printf '%s\n' "$backend"
}

setup_llama() {
    section "llama.cpp"
    local LLAMA_DIR="$LLM_HOME/llama.cpp"

    if [[ ! -d "$LLAMA_DIR" ]]; then
        info "llama.cpp not found. Cloning..."
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR" ||
            die "Failed to clone llama.cpp"
    else
        info "llama.cpp found at $LLAMA_DIR"
        if [[ "$(ask_yesno "Update llama.cpp from git?" No)" == "Yes" ]]; then
            subsection "Updating..."
            (cd "$LLAMA_DIR" && git pull --ff-only) || warn "Update failed; continuing"
        fi
    fi

    subsection "Checking accelerators..."
    detect_backends
    if (( HAS_CUDA )); then
        info "  CUDA toolkit: found"
    else
        warn "  CUDA toolkit: not found (nvcc)"
    fi
    if (( HAS_VULKAN )); then
        info "  Vulkan runtime: found"
    else
        warn "  Vulkan runtime: not found"
    fi

    section "Backend Selection"
    info "CPU is always compiled as a fallback."
    local backend
    backend="$(choose_backend)"
    info "Selected: ${BOLD}$backend${NC}"

    local -a cmake_args=("-DCMAKE_BUILD_TYPE=Release")

    case "$backend" in
        CPU)
            cmake_args+=("-DGGML_CUDA=OFF" "-DGGML_VULKAN=OFF")
            ;;
        CUDA)
            if (( ! HAS_CUDA )); then
                [[ "$(ask_yesno "CUDA toolkit not found. Continue anyway?" No)" == "Yes" ]] ||
                    die "CUDA toolkit missing. Install it, set CUDA_HOME, or choose another backend."
            fi
            cmake_args+=("-DGGML_CUDA=ON" "-DGGML_VULKAN=OFF")
            ;;
        Vulkan)
            if (( ! HAS_VULKAN )); then
                [[ "$(ask_yesno "Vulkan runtime not found. Continue anyway?" No)" == "Yes" ]] ||
                    die "Vulkan runtime missing. Install it or choose another backend."
            fi
            cmake_args+=("-DGGML_CUDA=OFF" "-DGGML_VULKAN=ON")
            ;;
        "CUDA + Vulkan")
            if (( ! HAS_CUDA )); then
                [[ "$(ask_yesno "CUDA toolkit not found. Continue anyway?" No)" == "Yes" ]] ||
                    die "CUDA toolkit missing. Install it, set CUDA_HOME, or choose another backend."
            fi
            if (( ! HAS_VULKAN )); then
                [[ "$(ask_yesno "Vulkan runtime not found. Continue anyway?" No)" == "Yes" ]] ||
                    die "Vulkan runtime missing. Install it or choose another backend."
            fi
            cmake_args+=("-DGGML_CUDA=ON" "-DGGML_VULKAN=ON")
            ;;
        Custom)
            local custom
            read -rp "Extra CMake flags: " custom || die "No flags provided"
            # shellcheck disable=SC2206
            local extra=($custom)
            cmake_args+=("${extra[@]}")
            ;;
    esac

    if [[ "$backend" == "CUDA" || "$backend" == "CUDA + Vulkan" ]] &&
        [[ -n "${CUDA_HOME:-}" ]]; then
        cmake_args+=("-DCUDAToolkit_ROOT=$CUDA_HOME")
        info "Using CUDA toolkit: $CUDA_HOME"
    fi

    section "Building llama.cpp"
    local build_dir="$LLAMA_DIR/build"
    local llama_bin="$build_dir/bin/llama-cli"

    if (( FRESH )) && [[ -d "$build_dir" ]]; then
        info "Removing existing build directory (--fresh)"
        rm -rf "$build_dir"
    fi

    if [[ -x "$llama_bin" ]] && (( ! FRESH )); then
        if [[ "$(ask_yesno "Existing llama-cli found. Rebuild?" No)" != "Yes" ]]; then
            info "Skipping build."
            warn "The selected backend was not rebuilt; the existing binary is unchanged."
            warn "Use './setup.sh --fresh --backend=$backend' to rebuild it."
            configure_gpu_choice
            return 0
        fi
    fi

    local jobs
    jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

    info "CMake args: ${cmake_args[*]}"
    if ! (cd "$LLAMA_DIR" && cmake -B build "${cmake_args[@]}"); then
        err "CMake configuration failed."
        warn "Try './setup.sh --fresh --backend=cpu', or install the missing SDK."
        exit 1
    fi
    if ! (cd "$LLAMA_DIR" && cmake --build build --config Release -j"$jobs"); then
        err "Build failed."
        exit 1
    fi

    if [[ -x "$llama_bin" ]]; then
        info "Build complete: $llama_bin"
    else
        die "llama-cli was not produced at $llama_bin"
    fi

    configure_gpu_choice
}

# Optionally configure device selection and multi-GPU splitting.
configure_gpu_choice() {
    local -a rows=()
    mapfile -t rows < <(llama_devices)
    if (( ${#rows[@]} == 0 )); then
        info "No GPU devices reported; using CPU."
        return 0
    fi

    subsection "Detected devices"
    local row id desc free total
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id desc free total <<<"$row"
        info "  $id: $desc"
    done

    if [[ "$(ask_yesno "Configure GPU devices now?" No)" != "Yes" ]]; then
        return 0
    fi

    local -a choices=()
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id desc free total <<<"$row"
        choices+=("$id|$desc")
    done

    local -a selection=()
    if interactive && have_cmd fzf; then
        mapfile -t selection < <(
            printf '%s\n' "${choices[@]}" |
                fzf --multi --height 40% --reverse --border --prompt="Devices (TAB to select)> " || true
        )
    else
        selection=("${choices[0]}")
    fi
    (( ${#selection[@]} > 0 )) || return 0

    local -a ids=()
    local choice
    for choice in "${selection[@]}"; do
        ids+=("${choice%%|*}")
    done

    local joined
    local IFS=','
    joined="${ids[*]}"
    config_set DEVICE "$joined"
    info "Devices set to: $joined"

    if (( ${#ids[@]} > 1 )); then
        local split
        split="$(menu "Split mode" layer row tensor none)"
        [[ -n "$split" ]] || split="layer"
        config_set SPLIT_MODE "$split"
        info "Split mode set to: $split"

        local auto
        if auto="$(auto_tensor_split "$joined")" && [[ -n "$auto" ]]; then
            config_set TENSOR_SPLIT "$auto"
            info "Tensor split set from VRAM: $auto"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

configure_env() {
    section "Configuration"
    mkdir -p "$LLM_HOME/config"

    if [[ ! -f "$LLM_CONFIG" ]]; then
        printf '%s\n' "# llm-launcher local settings (gitignored)" >"$LLM_CONFIG"
    fi

    subsection "Long-term memory"
    local mem_default="No"
    [[ "${MEMORY_ENABLED:-false}" == "true" ]] && mem_default="Yes"
    if [[ "$(ask_yesno "Enable the long-term memory file?" "$mem_default")" == "Yes" ]]; then
        local mem_dir="${MEMORY_DIR:-$LLM_HOME/memory}"
        local mem_file="${MEMORY_FILE:-$mem_dir/memory.md}"
        mkdir -p "$mem_dir"
        if [[ ! -f "$mem_file" ]]; then
            mem_file="$mem_dir/memory.md"
            touch "$mem_file"
        fi
        if [[ "$mem_file" == "$mem_dir/"* ]]; then
            config_set MEMORY_FILE "${mem_file##*/}"
        else
            config_set MEMORY_FILE "$mem_file"
        fi
        config_set MEMORY_ENABLED "true"
        info "Memory enabled: $mem_file"
    else
        config_set MEMORY_ENABLED "false"
        info "Long-term memory disabled"
    fi

    subsection "Models"
    local -a models=()
    mapfile -t models < <(list_models)

    if (( ${#models[@]} == 0 )); then
        warn "No .gguf models found in ${MODEL_DIR:-$LLM_HOME/models}"
        if [[ "$(ask_yesno "Download a default model (Qwen3-VL-8B Q4_K_M)?" No)" == "Yes" ]]; then
            local model_name="Qwen3VL-8B-Instruct-Q4_K_M.gguf"
            local url="https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/main/$model_name"
            mkdir -p "${MODEL_DIR:-$LLM_HOME/models}"
            info "Downloading $model_name..."
            if curl -fL --retry 3 --progress-bar -o "${MODEL_DIR:-$LLM_HOME/models}/$model_name" "$url"; then
                config_set DEFAULT_MODEL "$model_name"
                info "Default model set: $model_name"
            else
                warn "Download failed; no default model set"
                config_set DEFAULT_MODEL ""
            fi
        else
            config_set DEFAULT_MODEL ""
        fi
    else
        info "Found ${#models[@]} model(s)"
        local current="${DEFAULT_MODEL:-}"

        if [[ -n "$current" && -f "$MODEL_DIR/$current" ]] &&
            [[ "$(ask_yesno "Keep '$current' as the default model?" Yes)" == "Yes" ]]; then
            info "Default model unchanged: $current"
        else
            local choice
            if interactive && have_cmd fzf; then
                choice="$(printf '%s\n' "${models[@]}" |
                    fzf --height 40% --reverse --border --prompt="Default model> " || true)"
            else
                choice="${models[0]}"
            fi
            if [[ -n "$choice" ]]; then
                config_set DEFAULT_MODEL "$choice"
                info "Default model set: $choice"
            else
                info "Default model unchanged"
            fi
        fi
    fi

    mkdir -p "$LLM_HOME/config"
    touch "$LLM_HOME/config/.configured"

    # Validate that the config loads to sane values.
    if ! bash -c '
        set -u
        source "$1/config/config.sh" >/dev/null 2>&1
        [[ -n "${LLM_HOME:-}" && -n "${MODEL_DIR:-}" && -n "${LLAMA_BIN:-}" ]]
    ' _ "$LLM_HOME"; then
        die "Configuration validation failed. Check $LLM_CONFIG and config/config.sh"
    fi

    info "Configuration saved to $LLM_CONFIG"
}

# ---------------------------------------------------------------------------
# Finishing up
# ---------------------------------------------------------------------------

post_setup() {
    section "Finishing up"
    chmod +x "$LLM_HOME/llm" 2>/dev/null || true
    chmod +x "$LLM_HOME/setup.sh" 2>/dev/null || true

    if [[ "$(ask_yesno "Create a symlink for 'llm' in ~/.local/bin?" No)" == "Yes" ]]; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$LLM_HOME/llm" "$HOME/.local/bin/llm"
        info "Symlinked: $HOME/.local/bin/llm -> $LLM_HOME/llm"
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            warn "Add ~/.local/bin to your PATH to use 'llm' from anywhere"
        fi
    fi

    subsection "Verifying installation..."
    "$LLM_HOME/llm" health || true

    printf '\n%sSetup complete.%s\n' "$GREEN$BOLD" "$NC"
    printf '  %-22s %s\n' "llm help" "Show commands"
    printf '  %-22s %s\n' "llm config show" "Show configuration"
    printf '  %-22s %s\n' "llm launch" "Launch the default model"
    printf '  %sConfig:%s %s\n' "$DIM" "$NC" "$LLM_CONFIG"
}

ensure_dirs() {
    section "Directories"
    mkdir -p "$LLM_HOME/config" "${MEMORY_DIR:-$LLM_HOME/memory}" "${MODEL_DIR:-$LLM_HOME/models}"
    info "Ensured: config/, ${MEMORY_DIR:-$LLM_HOME/memory}, ${MODEL_DIR:-$LLM_HOME/models}"
    [[ -f "${MEMORY_DIR:-$LLM_HOME/memory}/memory.md" ]] ||
        touch "${MEMORY_DIR:-$LLM_HOME/memory}/memory.md"
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
