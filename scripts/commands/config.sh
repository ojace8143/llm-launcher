#!/usr/bin/env bash
# `llm config` — view and change configuration.

CONFIG_KEYS="DEFAULT_MODEL MODEL_DIR LLAMA_HOME LLAMA_BIN LLAMA_SERVER_BIN MEMORY_DIR MEMORY_FILE MEMORY_ENABLED CONTEXT_SIZE NGL THREADS THREADS_BATCH FLASH_ATTN PARALLEL TEMP TOP_P EXTRA_ARGS DEVICE SPLIT_MODE TENSOR_SPLIT MAIN_GPU FIT SERVER_HOST SERVER_PORT SERVER_API_KEY SERVER_TOOLS SERVER_AGENT AGENT_WORKSPACE MCP_CONFIG RUN_DIR LOG_DIR"

cmd_config() {
    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        ""|help|-h|--help) help_config ;;
        show) config_show "$@" ;;
        edit) config_edit ;;
        get) config_cmd_get "$@" ;;
        set) config_cmd_set "$@" ;;
        unset) config_cmd_unset "$@" ;;
        reset) config_cmd_reset "$@" ;;
        path) printf '%s\n' "$LLM_CONFIG" ;;
        open) config_cmd_open ;;
        check) config_check ;;
        default) config_default ;;
        device|devices) config_device ;;
        split|split-mode) config_split ;;
        tensor-split) config_tensor_split ;;
        main-gpu) config_main_gpu ;;
        context) config_context ;;
        ngl) config_ngl ;;
        threads) config_threads ;;
        flash) config_flash ;;
        parallel) config_parallel ;;
        temp) config_temp ;;
        top-p) config_top_p ;;
        extra-args|extra) config_extra_args ;;
        memory) config_memory ;;
        host) config_server_host ;;
        port) config_server_port ;;
        api-key) config_api_key ;;
        tools) config_tools ;;
        workspace) config_workspace ;;
        mcp) config_mcp ;;
        *)
            err "Unknown config option: $sub"
            help_config
            return 2
            ;;
    esac
}

config_row() { printf '  %-18s %s\n' "$1" "$2"; }

_json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    printf '%s' "$v"
}

config_show() {
    if [[ "${1:-}" == "--json" ]]; then
        printf '{'
        local first=1 key value
        for key in $CONFIG_KEYS; do
            (( first )) || printf ','
            first=0
            value="$(config_get "$key")"
            printf '"%s":"%s"' "$key" "$(_json_escape "$value")"
        done
        printf '}\n'
        return 0
    fi

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

    local api_state="(unset)"
    [[ -n "${SERVER_API_KEY:-}" ]] && api_state="(set)"

    section "Model"
    config_row "Config file" "$LLM_CONFIG"
    config_row "Default model" "$model_state"
    config_row "Models dir" "${MODEL_DIR:-unset}"
    config_row "Context size" "${CONTEXT_SIZE:-unset}"
    config_row "GPU layers" "${NGL:-unset}"
    config_row "Threads" "${THREADS:-(auto)}"
    config_row "Flash attention" "${FLASH_ATTN:-(auto)}"
    config_row "Parallel" "${PARALLEL:-1}"
    config_row "Memory" "$memory_state"

    section "GPU"
    config_row "Devices" "${DEVICE:-(CPU / auto)}"
    config_row "Split mode" "${SPLIT_MODE:-layer}"
    config_row "Tensor split" "${TENSOR_SPLIT:-(auto / even)}"
    config_row "Main GPU" "${MAIN_GPU:-0}"
    config_row "Fit" "${FIT:-(llama default)}"

    section "Generation"
    config_row "Temperature" "${TEMP:-(model default)}"
    config_row "Top-p" "${TOP_P:-(model default)}"
    config_row "Extra args" "${EXTRA_ARGS:-(none)}"

    section "Server / Agent"
    config_row "Host" "${SERVER_HOST:-127.0.0.1}"
    config_row "Port" "${SERVER_PORT:-9931}"
    config_row "API key" "$api_state"
    config_row "Agent mode" "${SERVER_AGENT:-false}"
    config_row "Tools" "${SERVER_TOOLS:-(none)}"
    config_row "Workspace" "${AGENT_WORKSPACE:-(current dir)}"
    config_row "MCP config" "${MCP_CONFIG:-(none)}"

    section "Paths"
    config_row "LLM_HOME" "$LLM_HOME"
    config_row "llama.cpp" "${LLAMA_HOME:-unset}"
    config_row "llama-cli" "${LLAMA_BIN:-unset}"
    config_row "llama-server" "${LLAMA_SERVER_BIN:-unset}"
    config_row "Run dir" "${RUN_DIR:-unset}"
    config_row "Log dir" "${LOG_DIR:-unset}"
}

config_edit() {
    require_fzf
    while true; do
        local option
        option="$(
            printf '%s\n' \
                "Model: default model" \
                "Model: context size" \
                "Model: GPU layers" \
                "Model: threads" \
                "Model: flash attention" \
                "Model: memory file" \
                "GPU: devices" \
                "GPU: split mode" \
                "GPU: tensor split" \
                "GPU: main GPU" \
                "GPU: fit" \
                "Generation: temperature" \
                "Generation: top-p" \
                "Generation: parallel sequences" \
                "Generation: extra args" \
                "Server: host" \
                "Server: port" \
                "Server: API key" \
                "Agent: tools" \
                "Agent: workspace" \
                "Agent: MCP config" \
                "Maintenance: show config" \
                "Maintenance: check config" \
                "Exit" |
                fzf --height 60% --reverse --border --prompt="Config> " || true
        )"

        case "$option" in
            "Model: default model") config_default ;;
            "Model: context size") config_context ;;
            "Model: GPU layers") config_ngl ;;
            "Model: threads") config_threads ;;
            "Model: flash attention") config_flash ;;
            "Model: memory file") config_memory ;;
            "GPU: devices") config_device ;;
            "GPU: split mode") config_split ;;
            "GPU: tensor split") config_tensor_split ;;
            "GPU: main GPU") config_main_gpu ;;
            "GPU: fit") config_fit ;;
            "Generation: temperature") config_temp ;;
            "Generation: top-p") config_top_p ;;
            "Generation: parallel sequences") config_parallel ;;
            "Generation: extra args") config_extra_args ;;
            "Server: host") config_server_host ;;
            "Server: port") config_server_port ;;
            "Server: API key") config_api_key ;;
            "Agent: tools") config_tools ;;
            "Agent: workspace") config_workspace ;;
            "Agent: MCP config") config_mcp ;;
            "Maintenance: show config") config_show ;;
            "Maintenance: check config") config_check || true ;;
            ""|"Exit") return 0 ;;
        esac
    done
}

_require_number() {
    local key="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || {
        err "$key must be a number"
        return 2
    }
}

_validate_set() {
    local key="$1" value="$2"
    case "$key" in
        CONTEXT_SIZE|NGL|THREADS|THREADS_BATCH|PARALLEL|MAIN_GPU|NGL)
            _require_number "$key" "$value" || return 2
            ;;
        SERVER_PORT)
            _require_number "$key" "$value" || return 2
            (( value >= 1 && value <= 65535 )) || {
                err "SERVER_PORT must be between 1 and 65535"
                return 2
            }
            ;;
        SPLIT_MODE)
            case "$value" in
                none|layer|row|tensor) ;;
                *) err "SPLIT_MODE must be none, layer, row, or tensor"; return 2 ;;
            esac
            ;;
        FLASH_ATTN)
            case "$value" in
                on|off|auto) ;;
                *) err "FLASH_ATTN must be on, off, or auto"; return 2 ;;
            esac
            ;;
        FIT)
            case "$value" in
                ""|on|off) ;;
                *) err "FIT must be on or off (or empty)"; return 2 ;;
            esac
            ;;
        MEMORY_ENABLED|SERVER_AGENT)
            [[ "$value" == "true" || "$value" == "false" ]] || {
                err "$key must be true or false"
                return 2
            }
            ;;
        DEVICE)
            if [[ -n "$value" ]] && ! validate_device_list "$value"; then
                err "Unknown device(s): $value"
                return 2
            fi
            ;;
        TENSOR_SPLIT)
            if [[ -n "$value" ]]; then
                if [[ -z "${DEVICE:-}" ]]; then
                    err "Set DEVICE before TENSOR_SPLIT"
                    return 2
                fi
                local -a parts=()
                IFS=',' read -r -a parts <<<"$value"
                local p
                for p in "${parts[@]}"; do
                    [[ "$p" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
                        err "TENSOR_SPLIT must be a comma-separated number list"
                        return 2
                    }
                done
                local -a ids=()
                IFS=',' read -r -a ids <<<"$DEVICE"
                if (( ${#ids[@]} != ${#parts[@]} )); then
                    err "TENSOR_SPLIT has ${#parts[@]} values but DEVICE has ${#ids[@]} devices"
                    return 2
                fi
            fi
            ;;
        DEFAULT_MODEL)
            if [[ -n "$value" && ! -f "${MODEL_DIR:-}/$value" ]]; then
                err "Model not found: ${MODEL_DIR:-}/$value"
                return 2
            fi
            ;;
        MEMORY_FILE)
            if [[ -n "$value" ]]; then
                local path="$value"
                [[ "$path" != /* ]] && path="${MEMORY_DIR:-}/$path"
                [[ -f "$path" ]] || {
                    err "Memory file not found: $path"
                    return 2
                }
            fi
            ;;
        SERVER_API_KEY)
            ;;
        *)
            # Free-form string keys are accepted as-is.
            ;;
    esac
    return 0
}

config_cmd_get() {
    local key="${1:-}"
    if [[ -z "$key" ]]; then
        err "Usage: llm config get <KEY>"
        return 2
    fi
    if [[ " $CONFIG_KEYS " != *" $key "* ]]; then
        err "Unknown key: $key"
        return 2
    fi
    config_get "$key"
    printf '\n'
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

    if [[ " $CONFIG_KEYS " != *" $key "* ]]; then
        err "Unknown key: $key"
        echo "Keys: $CONFIG_KEYS" >&2
        return 2
    fi

    _validate_set "$key" "$value" || return $?
    config_set "$key" "$value"
    info "$key set to: ${value:-(empty)}"
}

config_cmd_unset() {
    local key="${1:-}"
    [[ -n "$key" ]] || { err "Usage: llm config unset <KEY>"; return 2; }
    if [[ " $CONFIG_KEYS " != *" $key "* ]]; then
        err "Unknown key: $key"
        return 2
    fi
    config_unset "$key"
    info "$key removed from local config (default will be used)"
}

config_cmd_reset() {
    local key="${1:-}"
    if [[ -n "$key" ]]; then
        config_cmd_unset "$key"
        return
    fi
    if [[ ! -f "$LLM_CONFIG" ]]; then
        info "No local config to reset"
        return 0
    fi
    local backup="${LLM_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$LLM_CONFIG" "$backup"
    rm -f "$LLM_CONFIG"
    info "Local config reset. Backup: $backup"
}

config_cmd_open() {
    if [[ ! -f "$LLM_CONFIG" ]]; then
        printf '%s\n' "# llm-launcher local settings (gitignored)" >"$LLM_CONFIG"
    fi
    local editor="${VISUAL:-${EDITOR:-vi}}"
    "$editor" "$LLM_CONFIG"
}

config_check() {
    local failures=0
    check_ok() { printf '  %s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
    check_fail() { printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$*"; failures=$((failures + 1)); }

    section "Config check"

    [[ -n "${LLM_HOME:-}" ]] && check_ok "LLM_HOME set" || check_fail "LLM_HOME is empty"
    [[ -d "${MODEL_DIR:-}" ]] && check_ok "model directory exists" || check_fail "model directory missing: ${MODEL_DIR:-unset}"
    [[ -x "${LLAMA_BIN:-}" ]] && check_ok "llama-cli exists" || check_fail "llama-cli missing: ${LLAMA_BIN:-unset}"

    if [[ -n "${DEFAULT_MODEL:-}" ]]; then
        [[ -f "${MODEL_DIR:-}/$DEFAULT_MODEL" ]] &&
            check_ok "default model exists" ||
            check_fail "default model missing: $DEFAULT_MODEL"
    else
        check_fail "no default model configured"
    fi

    if [[ "${MEMORY_ENABLED:-false}" == "true" ]]; then
        [[ -f "${MEMORY_FILE:-}" ]] &&
            check_ok "memory file exists" ||
            check_fail "memory file missing: ${MEMORY_FILE:-unset}"
    else
        check_ok "memory disabled"
    fi

    if validate_gpu_config; then
        check_ok "GPU settings valid"
    else
        check_fail "GPU settings invalid"
    fi

    if [[ "${SERVER_PORT:-}" =~ ^[0-9]+$ ]] &&
        (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )); then
        check_ok "server port valid: $SERVER_PORT"
    else
        check_fail "invalid SERVER_PORT: ${SERVER_PORT:-unset}"
    fi

    if [[ -n "${MCP_CONFIG:-}" ]]; then
        [[ -f "$MCP_CONFIG" ]] && check_ok "MCP config exists" || check_fail "MCP config missing: $MCP_CONFIG"
    fi

    if [[ -n "${AGENT_WORKSPACE:-}" ]]; then
        [[ -d "$AGENT_WORKSPACE" ]] &&
            check_ok "agent workspace exists" ||
            check_fail "agent workspace missing: $AGENT_WORKSPACE"
    fi

    echo
    if (( failures == 0 )); then
        printf '%sConfiguration is valid.%s\n' "$GREEN" "$NC"
        return 0
    fi
    printf '%s%d configuration problem(s) found.%s\n' "$RED" "$failures" "$NC"
    return 1
}

prompt_value() {
    local prompt="$1" current="${2:-}" value
    read -rp "$prompt [$current]: " value || return 0
    printf '%s' "${value:-$current}"
}

config_default() {
    local model
    model="$(pick_model)" || return 1
    [[ -n "$model" ]] || return 0
    config_set DEFAULT_MODEL "$model"
    info "Default model set to: $model"
}

config_device() {
    require_fzf
    local -a rows=() choices=()
    mapfile -t rows < <(llama_devices)
    if (( ${#rows[@]} == 0 )); then
        warn "No devices reported by llama.cpp (CPU-only build or no GPU)."
        return 1
    fi

    choices+=("CPU only")
    local row id desc free total
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id desc free total <<<"$row"
        choices+=("$id|$desc")
    done

    local -a selection=()
    mapfile -t selection < <(
        printf '%s\n' "${choices[@]}" |
            fzf --multi --height 40% --reverse --border --prompt="Devices (TAB to multi-select)> " || true
    )
    (( ${#selection[@]} > 0 )) || return 0

    local -a ids=()
    local choice
    for choice in "${selection[@]}"; do
        [[ "$choice" == "CPU only" ]] && { ids=(); break; }
        ids+=("${choice%%|*}")
    done

    local joined=""
    if (( ${#ids[@]} > 0 )); then
        local IFS=','
        joined="${ids[*]}"
    fi

    config_set DEVICE "$joined"
    if [[ -z "$joined" ]]; then
        config_set TENSOR_SPLIT ""
        info "Device disabled (CPU only)"
    else
        info "Devices set to: $joined"
        if [[ "$joined" == *,* ]]; then
            local -a ids=() parts=()
            IFS=',' read -r -a ids <<<"$joined"
            if [[ -n "${TENSOR_SPLIT:-}" ]]; then
                IFS=',' read -r -a parts <<<"$TENSOR_SPLIT"
            fi
            if (( ${#parts[@]} != ${#ids[@]} )); then
                local auto
                if auto="$(auto_tensor_split "$joined")" && [[ -n "$auto" ]]; then
                    config_set TENSOR_SPLIT "$auto"
                    info "Tensor split set from VRAM: $auto"
                else
                    config_set TENSOR_SPLIT ""
                    warn "Could not determine free VRAM; tensor split left to llama.cpp"
                fi
            fi
        else
            config_set TENSOR_SPLIT ""
        fi
    fi
}

config_split() {
    require_fzf
    local selection
    selection="$(printf '%s\n' none layer row tensor |
        fzf --height 40% --reverse --border --prompt="Split mode> " || true)"
    [[ -n "$selection" ]] || return 0
    config_set SPLIT_MODE "$selection"
    info "Split mode set to: $selection"
}

config_tensor_split() {
    require_fzf
    local selection
    selection="$(printf '%s\n' "Auto (by free VRAM)" "Even (llama default)" "Manual" |
        fzf --height 40% --reverse --border --prompt="Tensor split> " || true)"
    [[ -n "$selection" ]] || return 0

    case "$selection" in
        "Auto (by free VRAM)")
            if [[ -z "${DEVICE:-}" ]]; then
                warn "Select devices first: llm config device"
                return 1
            fi
            local auto
            if auto="$(auto_tensor_split "$DEVICE")" && [[ -n "$auto" ]]; then
                config_set TENSOR_SPLIT "$auto"
                info "Tensor split set to: $auto"
            else
                warn "Could not determine free VRAM for: $DEVICE"
                return 1
            fi
            ;;
        "Even (llama default)")
            config_set TENSOR_SPLIT ""
            info "Tensor split cleared (llama default)"
            ;;
        Manual)
            local value
            value="$(prompt_value "Tensor split (e.g. 3,1)" "${TENSOR_SPLIT:-}")"
            [[ -n "$value" ]] || return 0
            _validate_set TENSOR_SPLIT "$value" || return $?
            config_set TENSOR_SPLIT "$value"
            info "Tensor split set to: $value"
            ;;
    esac
}

config_main_gpu() {
    local value
    value="$(prompt_value "Main GPU index" "${MAIN_GPU:-0}")"
    [[ -n "$value" ]] || return 0
    _validate_set MAIN_GPU "$value" || return $?
    config_set MAIN_GPU "$value"
    info "Main GPU set to: $value"
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
        selection="$(prompt_value "Context size" "${CONTEXT_SIZE:-16384}")"
        [[ "$selection" =~ ^[0-9]+$ ]] || {
            err "Context size must be a number"
            return 2
        }
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
        selection="$(prompt_value "GPU layers" "${NGL:-99}")"
        [[ "$selection" =~ ^[0-9]+$ ]] || {
            err "GPU layers must be a number"
            return 2
        }
    fi

    config_set NGL "$selection"
    info "GPU layers set to: $selection"
}

config_threads() {
    local value
    value="$(prompt_value "Threads (empty = auto)" "${THREADS:-}")"
    [[ -z "$value" ]] || _validate_set THREADS "$value" || return $?
    config_set THREADS "$value"
    info "Threads set to: ${value:-(auto)}"
}

config_flash() {
    require_fzf
    local selection
    selection="$(printf '%s\n' on off auto |
        fzf --height 40% --reverse --border --prompt="Flash attention> " || true)"
    [[ -n "$selection" ]] || return 0
    config_set FLASH_ATTN "$selection"
    info "Flash attention set to: $selection"
}

config_fit() {
    require_fzf
    local selection
    selection="$(printf '%s\n' "on" "off" "default" |
        fzf --height 40% --reverse --border --prompt="Fit> " || true)"
    [[ -n "$selection" ]] || return 0
    [[ "$selection" == "default" ]] && selection=""
    config_set FIT "$selection"
    info "Fit set to: ${selection:-(default)}"
}

config_parallel() {
    local value
    value="$(prompt_value "Parallel sequences" "${PARALLEL:-1}")"
    [[ -n "$value" ]] || return 0
    _validate_set PARALLEL "$value" || return $?
    config_set PARALLEL "$value"
    info "Parallel sequences set to: $value"
}

config_temp() {
    local value
    value="$(prompt_value "Temperature (empty = model default)" "${TEMP:-}")"
    if [[ -n "$value" && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        err "Temperature must be a number"
        return 2
    fi
    config_set TEMP "$value"
    info "Temperature set to: ${value:-(model default)}"
}

config_top_p() {
    local value
    value="$(prompt_value "Top-p (empty = model default)" "${TOP_P:-}")"
    if [[ -n "$value" && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        err "Top-p must be a number"
        return 2
    fi
    config_set TOP_P "$value"
    info "Top-p set to: ${value:-(model default)}"
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

config_extra_args() {
    local value
    value="$(prompt_value "Extra llama-cli args (space-separated)" "${EXTRA_ARGS:-}")"
    config_set EXTRA_ARGS "$value"
    info "Extra args set to: ${value:-(none)}"
}

config_server_host() {
    local value
    value="$(prompt_value "Server host" "${SERVER_HOST:-127.0.0.1}")"
    [[ -n "$value" ]] || return 0
    config_set SERVER_HOST "$value"
    info "Server host set to: $value"
}

config_api_key() {
    local value
    value="$(prompt_value "Server API key (empty = none)" "${SERVER_API_KEY:-}")"
    config_set SERVER_API_KEY "$value"
    info "API key set: $([[ -n "$value" ]] && echo yes || echo no)"
}

config_server_port() {
    local value
    value="$(prompt_value "Server port" "${SERVER_PORT:-9931}")"
    [[ -n "$value" ]] || return 0
    _validate_set SERVER_PORT "$value" || return $?
    config_set SERVER_PORT "$value"
    info "Server port set to: $value"
}

config_tools() {
    require_fzf
    local selection
    selection="$(
        printf '%s\n' \
            "Read + search + edit (recommended)" \
            "All built-in tools (includes shell)" \
            "Read-only" \
            "None" \
            "Custom" |
            fzf --height 40% --reverse --border --prompt="Agent tools> " || true
    )"
    [[ -n "$selection" ]] || return 0

    case "$selection" in
        "Read + search + edit (recommended)") config_set SERVER_TOOLS "$PROFILE_TOOLS" ;;
        "All built-in tools (includes shell)") config_set SERVER_TOOLS "$ALL_TOOLS" ;;
        "Read-only") config_set SERVER_TOOLS "read_file,file_glob_search,grep_search,get_info" ;;
        "None") config_set SERVER_TOOLS "" ;;
        Custom)
            local value
            value="$(prompt_value "Tools (comma-separated)" "${SERVER_TOOLS:-}")"
            config_set SERVER_TOOLS "$value"
            ;;
    esac
    # Explicit tool lists take precedence over the all-tools shortcut.
    config_set SERVER_AGENT "false"
    info "Agent tools updated"
}

config_workspace() {
    local value
    value="$(prompt_value "Agent workspace" "${AGENT_WORKSPACE:-$PWD}")"
    [[ -n "$value" ]] || return 0
    if [[ ! -d "$value" ]]; then
        err "Directory does not exist: $value"
        return 2
    fi
    config_set AGENT_WORKSPACE "$value"
    info "Agent workspace set to: $value"
}

config_mcp() {
    local value
    value="$(prompt_value "MCP config path (empty = none)" "${MCP_CONFIG:-}")"
    if [[ -n "$value" && ! -f "$value" ]]; then
        err "File does not exist: $value"
        return 2
    fi
    config_set MCP_CONFIG "$value"
    info "MCP config set to: ${value:-(none)}"
}

help_config() {
    cat <<EOF
${BOLD}llm config${NC} <subcommand>

View and change llm-launcher settings. Values are stored in
${DIM}$LLM_CONFIG${NC} (gitignored), not in the tracked defaults.

${BOLD}General${NC}
  llm config show [--json]        Show effective configuration
  llm config edit                 Interactive menu
  llm config get <KEY>            Print a value
  llm config set <KEY> <VALUE>    Set a value
  llm config unset <KEY>          Remove a local override
  llm config reset [KEY]          Remove all overrides (backs up)
  llm config path                 Print the local config path
  llm config open                 Open the local config in \$EDITOR
  llm config check                Validate configuration

${BOLD}Shortcuts${NC}
  llm config default              Default model
  llm config device               Devices (multi-select)
  llm config split                Split mode
  llm config tensor-split         Tensor split
  llm config main-gpu             Main GPU index
  llm config context              Context size
  llm config ngl                  GPU layers
  llm config threads              CPU threads
  llm config flash                Flash attention
  llm config parallel             Parallel sequences
  llm config temp                 Temperature
  llm config top-p                Top-p
  llm config extra                Extra llama-cli args
  llm config memory               Memory file
  llm config host                 Server host
  llm config port                 Server port
  llm config api-key              Server API key
  llm config tools                Agent tools
  llm config workspace            Agent workspace
  llm config mcp                  MCP config

${BOLD}Keys${NC}
  $CONFIG_KEYS

${DIM}Per-model overrides: config/profiles/<model>.sh${NC}
EOF
}
