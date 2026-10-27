#!/usr/bin/env bash
# `llm config` — view and change configuration.

CONFIG_KEYS="DEFAULT_MODEL MODEL_DIR LLAMA_HOME LLAMA_BIN MEMORY_DIR MEMORY_FILE CONTEXT_SIZE NGL DEVICE MEMORY_ENABLED"

cmd_config() {
    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        ""|help|-h|--help) help_config ;;
        show) config_show ;;
        edit) config_edit ;;
        set) config_cmd_set "$@" ;;
        default) config_default ;;
        device) config_device ;;
        context) config_context ;;
        ngl) config_ngl ;;
        memory) config_memory ;;
        *)
            err "Unknown config option: $sub"
            help_config
            return 2
            ;;
    esac
}

config_row() { printf '  %-18s %s\n' "$1" "$2"; }

config_show() {
    local model_state="${DEFAULT_MODEL:-(none)}"
    if [[ -n "${DEFAULT_MODEL:-}" && ! -f "${MODEL_DIR:-}/$DEFAULT_MODEL" ]]; then
        model_state="$DEFAULT_MODEL ${RED}(missing)${NC}"
    fi

    local memory_state
    if [[ "${MEMORY_ENABLED:-false}" == "true" ]]; then
        memory_state="enabled -> ${MEMORY_FILE:-unset}"
    else
        memory_state="disabled"
    fi

    section "Configuration"
    config_row "Config file" "$LLM_CONFIG"
    config_row "LLM_HOME" "$LLM_HOME"
    config_row "llama.cpp" "${LLAMA_HOME:-unset}"
    config_row "llama-cli" "${LLAMA_BIN:-unset}"
    config_row "Models dir" "${MODEL_DIR:-unset}"
    config_row "Default model" "$model_state"
    config_row "Context size" "${CONTEXT_SIZE:-unset}"
    config_row "GPU layers" "${NGL:-unset}"
    config_row "Device" "${DEVICE:-(CPU / auto)}"
    config_row "Memory" "$memory_state"
}

config_edit() {
    require_fzf
    while true; do
        local option
        option="$(
            printf '%s\n' \
                "Default model" \
                "GPU/device" \
                "Context size" \
                "GPU layers" \
                "Memory file" \
                "Exit" |
                fzf --height 40% --reverse --border --prompt="Config> " || true
        )"

        case "$option" in
            "Default model") config_default ;;
            "GPU/device") config_device ;;
            "Context size") config_context ;;
            "GPU layers") config_ngl ;;
            "Memory file") config_memory ;;
            ""|"Exit") return 0 ;;
        esac
    done
}

config_cmd_set() {
    if [[ $# -lt 2 ]]; then
        err "Usage: llm config set <KEY> <VALUE>"
        echo "Keys: $CONFIG_KEYS" >&2
        return 2
    fi

    local key="$1"
    shift
    local value="$*"

    case "$key" in
        DEFAULT_MODEL|MODEL_DIR|LLAMA_HOME|LLAMA_BIN|MEMORY_DIR|MEMORY_FILE|CONTEXT_SIZE|NGL|DEVICE|MEMORY_ENABLED) ;;
        *)
            err "Unknown key: $key"
            echo "Keys: $CONFIG_KEYS" >&2
            return 2
            ;;
    esac

    if [[ "$key" == "CONTEXT_SIZE" || "$key" == "NGL" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
        err "$key must be a number"
        return 2
    fi

    if [[ "$key" == "MEMORY_ENABLED" && "$value" != "true" && "$value" != "false" ]]; then
        err "MEMORY_ENABLED must be true or false"
        return 2
    fi

    config_set "$key" "$value"
    info "$key set to: $value"
}

config_default() {
    local model
    model="$(pick_model)" || return 1
    [[ -n "$model" ]] || return 0
    config_set DEFAULT_MODEL "$model"
    info "Default model set to: $model"
}

config_device() {
    [[ -x "${LLAMA_BIN:-}" ]] || die "llama.cpp is not built. Run ./setup.sh"

    local devices
    devices="$("$LLAMA_BIN" --list-devices 2>/dev/null |
        awk '/^[[:space:]]+[A-Za-z0-9_.-]+:/ { gsub(/^[[:space:]]+/, ""); sub(/:.*/, ""); print }')"

    if [[ -z "$devices" ]]; then
        warn "No GPU devices reported by llama-cli."
        return 1
    fi

    local selection
    selection="$(
        printf '%s\n' "None (CPU only)" "$devices" |
            fzf --height 40% --reverse --border --prompt="Select device> " || true
    )"
    [[ -n "$selection" ]] || return 0

    if [[ "$selection" == "None (CPU only)" ]]; then
        config_set DEVICE ""
        info "Device disabled (CPU only)"
    else
        config_set DEVICE "$selection"
        info "Device set to: $selection"
    fi
}

config_context() {
    require_fzf
    local selection
    selection="$(
        printf '%s\n' 1024 2048 4096 8192 16384 32768 65536 131072 "Custom" |
            fzf --height 40% --reverse --border --prompt="Context size> " || true
    )"
    [[ -n "$selection" ]] || return 0

    if [[ "$selection" == "Custom" ]]; then
        local custom
        read -rp "Context size: " custom || return 0
        [[ "$custom" =~ ^[0-9]+$ ]] || {
            err "Context size must be a number"
            return 2
        }
        selection="$custom"
    fi

    config_set CONTEXT_SIZE "$selection"
    info "Context size set to: $selection"
}

config_ngl() {
    require_fzf
    local selection
    selection="$(
        printf '%s\n' 0 8 16 32 64 99 "Custom" |
            fzf --height 40% --reverse --border --prompt="GPU layers> " || true
    )"
    [[ -n "$selection" ]] || return 0

    if [[ "$selection" == "Custom" ]]; then
        local custom
        read -rp "GPU layers: " custom || return 0
        [[ "$custom" =~ ^[0-9]+$ ]] || {
            err "GPU layers must be a number"
            return 2
        }
        selection="$custom"
    fi

    config_set NGL "$selection"
    info "GPU layers set to: $selection"
}

config_memory() {
    require_fzf
    local -a files=()
    if [[ -d "${MEMORY_DIR:-}" ]]; then
        mapfile -t files < <(find "$MEMORY_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)
    fi

    local selection
    selection="$(
        printf '%s\n' "Disable long-term memory" "${files[@]}" |
            fzf --height 40% --reverse --border --prompt="Memory file> " || true
    )"
    [[ -n "$selection" ]] || return 0

    if [[ "$selection" == "Disable long-term memory" ]]; then
        config_set MEMORY_ENABLED "false"
        info "Long-term memory disabled"
    else
        config_set MEMORY_FILE "$selection"
        config_set MEMORY_ENABLED "true"
        info "Memory file set to: $selection"
    fi
}

help_config() {
    cat <<EOF
${BOLD}llm config${NC} <subcommand>

View and change llm-launcher settings. Values are stored in
${DIM}$LLM_CONFIG${NC} (gitignored), not in the tracked defaults.

  llm config show                 Show effective configuration
  llm config edit                 Interactive menu
  llm config set <KEY> <VALUE>    Set a value directly
  llm config default              Choose the default model
  llm config device               Choose the GPU/device
  llm config context              Choose the context size
  llm config ngl                  Choose GPU layers offloaded
  llm config memory               Choose the memory file

${DIM}Keys: $CONFIG_KEYS${NC}
EOF
}
