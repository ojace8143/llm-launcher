#!/usr/bin/env bash
# `llm serve` — run llama-server with the configured model and GPU settings.

server_pid_file() { printf '%s/server.pid\n' "${RUN_DIR:-$LLM_HOME/run}"; }
server_log_file() { printf '%s/server.log\n' "${LOG_DIR:-$LLM_HOME/logs}"; }

server_running() {
    local pidfile
    pidfile="$(server_pid_file)"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

server_url() {
    local host="${SERVER_HOST:-127.0.0.1}"
    case "$host" in
        0.0.0.0|"") host="127.0.0.1" ;;
        ::|"[::]") host="[::1]" ;;
    esac
    printf 'http://%s:%s' "$host" "${SERVER_PORT:-9931}"
}

is_loopback() {
    case "${1:-}" in
        127.0.0.1|localhost|::1|"[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

wait_for_server() {
    local url="$1" attempts="${2:-60}"
    local i
    for (( i = 0; i < attempts; i++ )); do
        if have_cmd curl && curl -fsS --max-time 2 "$url/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
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
    local model_query="${DEFAULT_MODEL:-}"
    local tools_override="" agent_mode="" key_override="" host_override=""
    local port_override="" workspace="${AGENT_WORKSPACE:-$PWD}"
    local sandbox="" mcp_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --background|-b) background=1 ;;
            --open) open_browser=1 ;;
            --no-open) open_browser=0 ;;
            --no-ui|--no-webui) no_ui=1 ;;
            --dry-run) dry_run=1 ;;
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

    if [[ -z "$model_query" ]]; then
        err "No model selected. Set DEFAULT_MODEL or pass --model."
        return 1
    fi

    local resolved
    resolved="$(resolve_model "$model_query")" || {
        err "Model not found: $model_query"
        return 1
    }
    [[ -n "$resolved" ]] || return 1
    [[ "$resolved" != /* ]] && resolved="$MODEL_DIR/$resolved"

    load_profile "$resolved"
    validate_gpu_config || return 1

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

    local -a args=()
    build_server_args args "$resolved"
    (( no_ui )) && args+=(--no-webui)
    [[ -n "$sandbox" ]] && args+=(--tools-runtime "$sandbox")

    if (( dry_run )); then
        printf 'cd %q && ' "$workspace"
        print_argv "$LLAMA_SERVER_BIN" "${args[@]}"
        return 0
    fi

    local url
    url="$(server_url)"
    local pidfile logfile
    pidfile="$(server_pid_file)"
    logfile="$(server_log_file)"
    mkdir -p "${RUN_DIR:-$LLM_HOME/run}" "${LOG_DIR:-$LLM_HOME/logs}"

    if server_running; then
        err "Server already running (PID $(cat "$pidfile")). Use 'llm serve stop'."
        return 1
    fi
    rm -f "$pidfile"

    section "Server"
    info "Model: $resolved"
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
            if have_cmd nohup; then
                exec nohup "$LLAMA_SERVER_BIN" "${args[@]}"
            else
                exec "$LLAMA_SERVER_BIN" "${args[@]}"
            fi
        ) >"$logfile" 2>&1 &
        local pid=$!
        printf '%s\n' "$pid" >"$pidfile"
        info "Started in background (PID $pid)"
        info "Log: $logfile"

        if wait_for_server "$url"; then
            info "Server is ready."
            (( open_browser )) && open_url "$url"
        else
            err "Server did not become ready. Check $logfile"
            return 1
        fi
        return 0
    fi

    (( open_browser )) && open_url "$url"
    cd "$workspace" || die "Unable to cd to $workspace"
    exec "$LLAMA_SERVER_BIN" "${args[@]}"
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
        rm -f "$pidfile"
        return 0
    fi

    local pid
    pid="$(cat "$pidfile")"
    info "Stopping server (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    local i
    for (( i = 0; i < 20; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "Server did not stop; sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
    info "Server stopped"
}

cmd_serve_status() {
    section "Server status"
    if server_running; then
        local pid
        pid="$(cat "$(server_pid_file)")"
        info "Running (PID $pid)"
        info "URL: $(server_url)"
        if have_cmd curl && curl -fsS --max-time 2 "$(server_url)/health" >/dev/null 2>&1; then
            info "Health: ok"
        else
            warn "Health endpoint not responding"
        fi
    else
        local pidfile
        pidfile="$(server_pid_file)"
        if [[ -f "$pidfile" ]]; then
            warn "Not running (removing stale PID file)"
            rm -f "$pidfile"
        else
            info "Not running"
        fi
    fi
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
  llm serve                     Run in the foreground
  llm serve --background        Run in the background
  llm serve status              Show PID and health
  llm serve stop                Stop the background server
  llm serve logs [-f]           Show the server log

${BOLD}Options${NC}
  --model NAME                  Model to serve (default: DEFAULT_MODEL)
  --host HOST                   Bind host (default: 127.0.0.1)
  --port PORT                   Bind port (default: 9931)
  --api-key KEY                 Require an API key
  --workspace DIR               CWD for tool operations
  --agent                       Enable all built-in tools
  --tools LIST                  Enable specific tools
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

${DIM}The server binds to loopback. Set SERVER_API_KEY before exposing it.${NC}
EOF
}
