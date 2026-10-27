#!/usr/bin/env bash
# `llm launch` — start llama-cli.

cmd_launch() {
    local target="${1:-default}"
    [[ $# -gt 0 ]] && shift

    # Allow `llm launch ... -- --flag value`
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi

    case "$target" in
        -h|--help)
            help_launch
            ;;
        ""|default)
            launch_default "$@"
            ;;
        select)
            require_fzf
            local model
            model="$(pick_model)" || return 1
            [[ -n "$model" ]] || return 0
            launch_model "$model" "$@"
            ;;
        *)
            launch_model "$target" "$@"
            ;;
    esac
}

launch_default() {
    if [[ -z "${DEFAULT_MODEL:-}" ]]; then
        err "No default model configured."
        echo "Choose one with: llm config default" >&2
        echo "Or launch one now with: llm launch select" >&2
        return 1
    fi

    launch_model "$DEFAULT_MODEL" "$@"
}

help_launch() {
    cat <<EOF
${BOLD}llm launch${NC} [default|select|<model>] [-- <llama-cli flags>]

Launch llama.cpp with the configured context size, GPU layers, device,
and long-term memory settings.

  llm launch                     Launch the default model
  llm launch default             Launch the default model
  llm launch select              Pick a model with fzf
  llm launch <model>             Launch a model by filename
  llm launch <model> -- -t 8     Pass flags through to llama-cli

${DIM}Configure the default model with: llm config default${NC}
EOF
}
