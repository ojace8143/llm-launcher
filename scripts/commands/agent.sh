#!/usr/bin/env bash
# `llm agent` — run llama-server with file/search/edit tools and the Web UI.

cmd_agent() {
    local shell_tools=0 full_tools=0 no_open=0 tools_given=0
    local tools_value=""
    local workspace="${AGENT_WORKSPACE:-$PWD}"
    local -a forward=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) help_agent; return 0 ;;
            --shell) shell_tools=1 ;;
            --full) full_tools=1 ;;
            --no-open) no_open=1 ;;
            --open) no_open=0 ;;
            --tools)
                tools_given=1
                forward+=("$1")
                [[ $# -ge 2 ]] || { err "--tools requires a value"; return 2; }
                tools_value="$2"
                forward+=("$2"); shift
                ;;
            --workspace)
                [[ $# -ge 2 ]] || { err "--workspace requires a value"; return 2; }
                workspace="$2"; shift
                ;;
            --workspace=*) workspace="${1#*=}" ;;
            --model|--port|--host|--api-key|--sandbox|--mcp)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                forward+=("$1" "$2"); shift
                ;;
            --background|-b|--dry-run|--no-ui)
                forward+=("$1")
                ;;
            -c|--ctx|--context|--ngl|--gpu-layers|--device|--split-mode|--tensor-split|--parallel)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                forward+=("$1" "$2"); shift
                ;;
            --no-memory) forward+=("--no-memory") ;;
            *) err "Unknown agent option: $1"; return 2 ;;
        esac
        shift
    done

    local show_tools=""
    if (( tools_given )); then
        show_tools="$tools_value"
    elif (( full_tools )) || [[ "${SERVER_AGENT:-false}" == "true" ]]; then
        forward+=("--agent")
        show_tools="all built-in tools"
    elif (( shell_tools )); then
        forward+=("--tools" "$ALL_TOOLS")
        show_tools="$ALL_TOOLS"
    elif [[ -n "${SERVER_TOOLS:-}" ]]; then
        forward+=("--tools" "$SERVER_TOOLS")
        show_tools="$SERVER_TOOLS"
    else
        forward+=("--tools" "$PROFILE_TOOLS")
        show_tools="$PROFILE_TOOLS"
    fi

    if [[ ! -d "$workspace" ]]; then
        err "Workspace does not exist: $workspace"
        return 1
    fi
    forward+=("--workspace" "$workspace")

    (( no_open )) || forward+=("--open")

    cat <<EOF
${YELLOW}Agent mode grants the model read/write access to files under:
  $workspace${NC}
${DIM}Tools: ${show_tools}${NC}
${DIM}Only bind to loopback unless you set an API key.${NC}
EOF

    cmd_serve_run "${forward[@]}"
}

help_agent() {
    cat <<EOF
${BOLD}llm agent${NC} [options]

Start llama-server with file tools and the Web UI. The model can read,
search, create, and edit files in the workspace.

${BOLD}Options${NC}
  --workspace DIR     Directory the agent may operate in (default: current dir)
  --shell             Also allow exec_shell_command
  --full              Enable all built-in tools (same as --shell today)
  --tools LIST        Explicit tool list (overrides defaults)
  --mcp FILE          Add tools from MCP servers
  --sandbox IMAGE     Run tools in docker:<image> or podman:<image>
  --model NAME        Model to serve
  --port PORT         Server port
  --host HOST         Bind host
  --api-key KEY       Require an API key
  --no-open           Do not open a browser
  --background, -b    Run in the background
  --dry-run           Print the command instead of running it

${BOLD}Default tools${NC}
  read_file, file_glob_search, grep_search, get_info,
  write_file, edit_file

${DIM}Shell execution is opt-in with --shell.${NC}
EOF
}
