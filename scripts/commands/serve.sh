#!/usr/bin/env bash
# `llm serve` — run llama-server with the configured model and GPU settings.

server_pid_file() { printf '%s/server.pid\n' "${RUN_DIR:-$LLM_HOME/run}"; }
server_meta_file() { printf '%s/server.meta\n' "${RUN_DIR:-$LLM_HOME/run}"; }
server_preset_file() { printf '%s/models.ini\n' "${RUN_DIR:-$LLM_HOME/run}"; }
server_log_file() { printf '%s/server.log\n' "${LOG_DIR:-$LLM_HOME/logs}"; }

pid_is_llama_server() {
    local pid="$1"
    [[ -r "/proc/$pid/cmdline" ]] || return 0
    local cmdline
    cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *llama-server* ]]
}

server_running() {
    local pidfile
    pidfile="$(server_pid_file)"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    pid_is_llama_server "$pid"
}

server_url() {
    local host="${SERVER_HOST:-127.0.0.1}"
    case "$host" in
        0.0.0.0|"") host="127.0.0.1" ;;
        ::|"[::]"|::1) host="[::1]" ;;
    esac
    printf 'http://%s:%s' "$host" "${SERVER_PORT:-9931}"
}

is_loopback() {
    case "${1:-}" in
        127.0.0.1|localhost|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

# Host to probe for a local port check when the bind address is a wildcard.
probe_host() {
    case "${1:-}" in
        0.0.0.0|"") printf '127.0.0.1\n' ;;
        ::|"[::]"|::1) printf '[::1]\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

port_in_use() {
    local port="$1" host="${2:-127.0.0.1}"
    if have_cmd ss; then
        ss -H -ltn 2>/dev/null |
            awk -v port="$port" '
                {
                    n = split($4, parts, ":")
                    if (parts[n] == port) found = 1
                }
                END { exit !found }
            '
        return $?
    fi
    if have_cmd lsof; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1
}

wait_for_server() {
    local url="$1" pid="${2:-}" attempts
    if ! have_cmd curl; then
        err "curl is required to check server readiness"
        return 1
    fi
    local timeout="${SERVER_START_TIMEOUT:-180}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=180
    attempts=$(( (timeout + 1) * 2 ))
    local i
    for (( i = 0; i < attempts; i++ )); do
        if curl -fsS --max-time 2 "$url/health" >/dev/null 2>&1; then
            return 0
        fi
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.5
    done
    return 1
}

write_server_meta() {
    local mode="$1" port="$2" model="$3" url="$4" logfile="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$mode" "$port" "$model" "$url" "$logfile" >"$(server_meta_file)"
}

read_server_meta() {
    META_MODE=""
    META_PORT=""
    META_MODEL=""
    META_URL=""
    META_LOG=""
    local metafile
    metafile="$(server_meta_file)"
    [[ -f "$metafile" ]] || return 1
    IFS=$'\t' read -r META_MODE META_PORT META_MODEL META_URL META_LOG <"$metafile" || true
    return 0
}

clear_server_state() {
    rm -f "$(server_pid_file)" "$(server_meta_file)"
}

cmd_serve() {
    local sub="${1:-run}"
    case "$sub" in
        stop) cmd_serve_stop; return $? ;;
        status) cmd_serve_status; return $? ;;
        logs) shift; cmd_serve_logs "$@"; return $? ;;
        restart)
            cmd_serve_stop
            shift
            cmd_serve_run "$@"
            return $?
            ;;
        run) shift; cmd_serve_run "$@" ;;
        -h|--help) help_serve ;;
        *) cmd_serve_run "$@" ;;
    esac
}

# Internal: build and run the server.
cmd_serve_run() {
    local background=0 open_browser=0 no_ui=0 dry_run=0
    local router=0 no_tools=0
    local model_query=""
    local tools_override="" agent_mode="" key_override="" host_override=""
    local port_override="" workspace="${AGENT_WORKSPACE:-$PWD}"
    local sandbox="" mcp_override="" alias_override=""
    local models_max="${SERVER_MODELS_MAX:-1}"
    local memory_margin="${SERVER_MEMORY_MARGIN:-0}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --background|-b) background=1 ;;
            --open) open_browser=1 ;;
            --no-open) open_browser=0 ;;
            --no-ui|--no-webui) no_ui=1 ;;
            --dry-run) dry_run=1 ;;
            --all|--router) router=1 ;;
            --no-tools) no_tools=1; tools_override=""; agent_mode="false" ;;
            --agent) agent_mode="true" ;;
            --tools)
                [[ $# -ge 2 ]] || { err "--tools requires a value"; return 2; }
                tools_override="$2"; agent_mode="false"; shift ;;
            --sandbox)
                [[ $# -ge 2 ]] || { err "--sandbox requires a value"; return 2; }
                sandbox="$2"; shift ;;
            --mcp)
                [[ $# -ge 2 ]] || { err "--mcp requires a value"; return 2; }
                mcp_override="$2"; shift ;;
            --model)
                [[ $# -ge 2 ]] || { err "--model requires a value"; return 2; }
                model_query="$2"; shift ;;
            --alias)
                [[ $# -ge 2 ]] || { err "--alias requires a value"; return 2; }
                alias_override="$2"; shift ;;
            --models-max)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                models_max="$2"; shift ;;
            --memory-margin)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                memory_margin="$2"; shift ;;
            --workspace)
                [[ $# -ge 2 ]] || { err "--workspace requires a value"; return 2; }
                workspace="$2"; shift ;;
            --host)
                [[ $# -ge 2 ]] || { err "--host requires a value"; return 2; }
                host_override="$2"; shift ;;
            --port)
                [[ $# -ge 2 ]] || { err "--port requires a value"; return 2; }
                port_override="$2"; shift ;;
            --api-key)
                [[ $# -ge 2 ]] || { err "--api-key requires a value"; return 2; }
                key_override="$2"; shift ;;
            -c|--ctx|--context)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                CONTEXT_SIZE="$2"; shift ;;
            --ngl|--gpu-layers)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                NGL="$2"; shift ;;
            --device)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                DEVICE="$2"; shift ;;
            --split-mode)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                SPLIT_MODE="$2"; shift ;;
            --tensor-split)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                TENSOR_SPLIT="$2"; shift ;;
            --parallel)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                PARALLEL="$2"; shift ;;
            --no-memory) MEMORY_ENABLED="false" ;;
            -h|--help) help_serve; return 0 ;;
            -*) err "Unknown serve option: $1"; return 2 ;;
            *)
                if [[ -n "$model_query" ]]; then
                    err "Unexpected argument: $1"
                    return 2
                fi
                model_query="$1"
                ;;
        esac
        shift
    done

    [[ -n "$host_override" ]] && SERVER_HOST="$host_override"
    [[ -n "$port_override" ]] && SERVER_PORT="$port_override"
    [[ -n "$key_override" ]] && SERVER_API_KEY="$key_override"
    [[ -n "$tools_override" ]] && SERVER_TOOLS="$tools_override"
    [[ -n "$agent_mode" ]] && SERVER_AGENT="$agent_mode"
    [[ -n "$mcp_override" ]] && MCP_CONFIG="$mcp_override"
    if (( no_tools )); then
        SERVER_TOOLS=""
        SERVER_AGENT="false"
    fi

    if (( router )); then
        if [[ -n "$model_query" ]]; then
            err "--all cannot be combined with a model name"
            return 2
        fi
        if [[ -n "$alias_override" ]]; then
            err "--alias only applies to single-model mode; use 'llm models alias' for router mode"
            return 2
        fi
    else
        [[ -n "$model_query" ]] || model_query="${DEFAULT_MODEL:-}"
        if [[ -z "$model_query" ]]; then
            err "No model selected. Set DEFAULT_MODEL or pass --model."
            return 1
        fi
    fi

    local resolved="" model_id="" model_desc=""
    if (( ! router )); then
        resolved="$(resolve_model "$model_query")" || {
            err "Model not found: $model_query"
            return 1
        }
        [[ -n "$resolved" ]] || return 1
        resolved="$(absolute_model_path "$resolved")" || {
            err "Unable to resolve model path: $resolved"
            return 1
        }
        load_profile "$resolved"
        validate_gpu_config || return 1

        model_id="${alias_override:-$(alias_for_model "$resolved")}"
        if [[ -n "$alias_override" ]] && ! _alias_valid "$alias_override"; then
            err "Invalid alias '$alias_override' (use letters, numbers, dot, underscore, or dash)"
            return 2
        fi
        model_desc="$model_id ($resolved)"
    else
        validate_gpu_config || return 1
        validate_aliases || return 1
        local model_count
        model_count="$(list_models | wc -l | tr -d ' ')"
        if (( model_count == 0 )); then
            err "No .gguf models found in ${MODEL_DIR:-models}"
            return 1
        fi
        model_desc="${model_count} model(s)"
        if [[ "${SERVER_AGENT:-false}" == "true" || -n "${SERVER_TOOLS:-}" ]]; then
            warn "llama-server built-in tools are enabled."
            warn "OpenCode supplies its own tools; use --no-tools to avoid duplicate tool layers."
        fi
    fi

    if [[ -n "$sandbox" ]]; then
        case "$sandbox" in
            docker:*|podman:*|docker-container:*|podman-container:*|ssh:*) ;;
            *) sandbox="docker:$sandbox" ;;
        esac
    fi

    if [[ ! "${SERVER_PORT:-}" =~ ^[0-9]+$ ]] ||
        (( SERVER_PORT < 1 || SERVER_PORT > 65535 )); then
        err "Invalid SERVER_PORT: ${SERVER_PORT:-unset}"
        return 1
    fi
    if ! is_loopback "$SERVER_HOST" && [[ -z "$SERVER_API_KEY" ]]; then
        err "SERVER_HOST=$SERVER_HOST is not loopback; set SERVER_API_KEY first."
        return 1
    fi
    if [[ ! -x "${LLAMA_SERVER_BIN:-}" ]]; then
        err "llama-server not found: ${LLAMA_SERVER_BIN:-unset}"
        err "Rebuild llama.cpp with ./setup.sh"
        return 1
    fi
    if [[ -n "$MCP_CONFIG" && ! -f "$MCP_CONFIG" ]]; then
        err "MCP config not found: $MCP_CONFIG"
        return 1
    fi
    if [[ ! -d "$workspace" ]]; then
        err "Workspace does not exist: $workspace"
        return 1
    fi
    if [[ ! "$models_max" =~ ^[0-9]+$ ]]; then
        err "--models-max must be a non-negative number"
        return 2
    fi
    if [[ ! "$memory_margin" =~ ^[0-9]+$ ]]; then
        err "--memory-margin must be a non-negative number"
        return 2
    fi

    local url pidfile metafile logfile preset_path
    url="$(server_url)"
    pidfile="$(server_pid_file)"
    metafile="$(server_meta_file)"
    logfile="$(server_log_file)"
    preset_path="$(server_preset_file)"

    local -a args=()
    if (( router )); then
        build_runtime_args args
        args+=(--host "${SERVER_HOST:-127.0.0.1}" --port "${SERVER_PORT:-9931}")
        [[ -n "${SERVER_API_KEY:-}" ]] && args+=(--api-key "$SERVER_API_KEY")
        if [[ "${SERVER_AGENT:-false}" == "true" ]]; then
            args+=(--agent)
        elif [[ -n "${SERVER_TOOLS:-}" ]]; then
            args+=(--tools "$SERVER_TOOLS")
        fi
        [[ -n "${MCP_CONFIG:-}" ]] && args+=(--mcp-servers-config "$MCP_CONFIG")
        args+=(--models-preset "$preset_path" --models-max "$models_max" --models-autoload)
        (( memory_margin > 0 )) && args+=(--models-memory-margin "$memory_margin")
    else
        build_server_args args "$resolved"
        args+=(--alias "$model_id")
    fi
    (( no_ui )) && args+=(--no-webui)
    [[ -n "$sandbox" ]] && args+=(--tools-runtime "$sandbox")

    if (( dry_run )); then
        if (( router )); then
            local preview
            preview="$(mktemp "${TMPDIR:-/tmp}/llm-preset.XXXXXX")" || return 1
            if ! write_router_preset "$preview"; then
                rm -f "$preview"
                return 1
            fi
            printf '# Router preset (%s):\n' "$preset_path"
            cat "$preview"
            printf '\n'
            rm -f "$preview"
        fi
        printf 'cd %q && ' "$workspace"
        print_argv "$LLAMA_SERVER_BIN" "${args[@]}"
        return 0
    fi

    mkdir -p "${RUN_DIR:-$LLM_HOME/run}" "${LOG_DIR:-$LLM_HOME/logs}"
    if server_running; then
        err "Server already running (PID $(cat "$pidfile")). Use 'llm serve stop'."
        return 1
    fi
    if [[ -f "$pidfile" ]]; then
        warn "Removing stale PID file: $pidfile"
        clear_server_state
    fi

    local probe
    probe="$(probe_host "${SERVER_HOST:-127.0.0.1}")"
    if port_in_use "$SERVER_PORT" "$probe"; then
        err "Port $SERVER_PORT is already in use."
        err "Stop the other process or use 'llm serve --port <port>'."
        return 1
    fi

    if (( router )); then
        if ! write_router_preset "$preset_path"; then
            return 1
        fi
    fi

    section "Server"
    info "Mode:  $([[ $router -eq 1 ]] && echo router || echo single)"
    if (( router )); then
        info "Models: $model_desc (max loaded: $models_max)"
        info "Preset: $preset_path"
    else
        info "Model: $resolved"
        info "Alias: $model_id"
    fi
    info "URL:   $url"
    if [[ "${SERVER_AGENT:-false}" == "true" ]]; then
        info "Mode:  agent (all built-in tools)"
    elif [[ -n "${SERVER_TOOLS:-}" ]]; then
        info "Mode:  tools (${SERVER_TOOLS})"
    else
        info "Mode:  chat (no tools)"
    fi
    if [[ -n "$sandbox" ]]; then
        info "Sandbox: $sandbox"
    fi

    if (( background )); then
        (
            cd "$workspace" || exit 1
            printf '===== %s =====\n' "$(date -Is)"
            if have_cmd nohup; then
                exec nohup "$LLAMA_SERVER_BIN" "${args[@]}"
            else
                exec "$LLAMA_SERVER_BIN" "${args[@]}"
            fi
        ) >"$logfile" 2>&1 &
        local pid=$!
        printf '%s\n' "$pid" >"$pidfile"
        write_server_meta "$([[ $router -eq 1 ]] && echo router || echo single)" \
            "$SERVER_PORT" "$model_desc" "$url" "$logfile"
        info "Started in background (PID $pid)"
        info "Log: $logfile"

        if wait_for_server "$url" "$pid"; then
            info "Server is ready."
            (( open_browser )) && open_url "$url"
        else
            err "Server did not become ready. Check $logfile"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
            clear_server_state
            tail -n 20 "$logfile" >&2 2>/dev/null || true
            return 1
        fi
        return 0
    fi

    printf '===== %s =====\n' "$(date -Is)" >>"$logfile"
    cd "$workspace" || die "Unable to cd to $workspace"
    "$LLAMA_SERVER_BIN" "${args[@]}" > >(tee -a "$logfile") 2>&1 &
    local fg_pid=$!
    printf '%s\n' "$fg_pid" >"$pidfile"
    write_server_meta "$([[ $router -eq 1 ]] && echo router || echo single)" \
        "$SERVER_PORT" "$model_desc" "$url" "$logfile"

    foreground_cleanup() {
        trap - INT TERM EXIT
        kill "$fg_pid" 2>/dev/null || true
        wait "$fg_pid" 2>/dev/null || true
        clear_server_state
    }
    trap foreground_cleanup INT TERM EXIT

    if wait_for_server "$url" "$fg_pid"; then
        info "Server is ready."
        (( open_browser )) && open_url "$url"
    else
        warn "Server did not become ready. Check $logfile"
    fi

    local rc=0
    wait "$fg_pid" || rc=$?
    trap - INT TERM EXIT
    clear_server_state
    return "$rc"
}

open_url() {
    local url="$1"
    if have_cmd xdg-open; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif have_cmd open; then
        open "$url" >/dev/null 2>&1 &
    else
        warn "No browser opener found; open $url manually"
    fi
}

cmd_serve_stop() {
    local pidfile
    pidfile="$(server_pid_file)"
    if ! server_running; then
        info "Server is not running"
        if [[ -f "$pidfile" ]]; then
            warn "Removing stale PID file"
        fi
        clear_server_state
        return 0
    fi

    local pid
    pid="$(cat "$pidfile")"
    info "Stopping server (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    local i
    for (( i = 0; i < 60; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "Server did not stop; sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    clear_server_state
    info "Server stopped"
}

cmd_serve_status() {
    section "Server status"
    read_server_meta || true

    if server_running; then
        local pid
        pid="$(cat "$(server_pid_file)")"
        info "Running (PID $pid)"
        [[ -n "${META_MODE:-}" ]] && info "Mode: ${META_MODE}"
        [[ -n "${META_MODEL:-}" ]] && info "Model: ${META_MODEL}"
        info "URL: ${META_URL:-$(server_url)}"
        if have_cmd curl && curl -fsS --max-time 2 "${META_URL:-$(server_url)}/health" >/dev/null 2>&1; then
            info "Health: ok"
        else
            warn "Health endpoint not responding"
        fi
        [[ -n "${META_LOG:-}" ]] && info "Log: ${META_LOG}"
        if [[ "${META_MODE:-}" == "router" && -f "$(server_preset_file)" ]]; then
            info "Preset: $(server_preset_file)"
        fi
    else
        local pidfile
        pidfile="$(server_pid_file)"
        if [[ -f "$pidfile" ]]; then
            warn "Not running (removing stale PID file)"
            clear_server_state
        elif port_in_use "${SERVER_PORT:-9931}" "$(probe_host "${SERVER_HOST:-127.0.0.1}")"; then
            warn "Not managed by llm, but port ${SERVER_PORT:-9931} is in use"
        else
            info "Not running"
        fi
        [[ -n "${META_LOG:-}" && -f "${META_LOG:-}" ]] && info "Last log: $META_LOG"
    fi
    return 0
}

cmd_serve_logs() {
    local follow=0
    [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]] && follow=1
    local logfile
    logfile="$(server_log_file)"
    [[ -f "$logfile" ]] || die "No log file at $logfile"
    if (( follow )); then
        tail -f "$logfile"
    else
        tail -n 200 "$logfile"
    fi
}

help_serve() {
    cat <<EOF
${BOLD}llm serve${NC} [options]

Run llama-server with the configured model, multi-GPU settings, and server
options.

${BOLD}Lifecycle${NC}
  llm serve                     Run the default model in the foreground
  llm serve <model>             Run one model in the foreground
  llm serve --all               Expose every installed model (router mode)
  llm serve --background        Run in the background
  llm serve status              Show PID, mode, and health
  llm serve stop                Stop the background server
  llm serve logs [-f]           Show the server log
  llm serve restart             Restart with the same arguments

${BOLD}Options${NC}
  --model NAME                  Model to serve (default: DEFAULT_MODEL)
  --all, --router               Router mode: load models on demand
  --alias NAME                  API model ID for single-model mode
  --models-max N                Max router models loaded at once (default: 1)
  --memory-margin MIB           Keep this much device memory free in router mode
  --host HOST                   Bind host (default: 127.0.0.1)
  --port PORT                   Bind port (default: 9931)
  --api-key KEY                 Require an API key
  --workspace DIR               CWD for tool operations
  --agent                       Enable all built-in tools
  --tools LIST                  Enable specific tools
  --no-tools                    Disable built-in tools (recommended for OpenCode)
  --mcp FILE                    MCP servers config (Cursor-compatible)
  --sandbox IMAGE               docker:<image> or podman:<image>
  --no-ui                       Disable the Web UI
  --open                        Open the Web UI in a browser
  --background, -b              Run in the background
  --dry-run                     Print the command instead of running it
  -c, --ctx N                   Override context size
      --ngl N                   Override GPU layers
      --device LIST             Override devices
      --split-mode MODE         none | layer | row | tensor
      --tensor-split LIST       e.g. 3,1
      --parallel N              Server slots
      --no-memory               Disable long-term memory

${DIM}Router mode uses the global GPU/runtime settings for every model. Configure
aliases with 'llm models alias' and generate an OpenCode provider with
'llm opencode config'.${NC}

${DIM}The server binds to loopback. Set SERVER_API_KEY before exposing it.${NC}
EOF
}
