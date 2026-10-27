#!/usr/bin/env bash
# `llm help` — top-level and per-command help.

cmd_help() {
    local topic="${1:-}"
    if [[ -n "$topic" ]]; then
        if declare -F "help_$topic" >/dev/null 2>&1; then
            "help_$topic"
            return 0
        fi
        err "No help available for: $topic"
        return 2
    fi

    cat <<EOF
${BOLD}llm${NC} ${DIM}$VERSION${NC} — llama.cpp launcher

${CYAN}::${NC} ${BOLD}Usage${NC}
  llm <command> [subcommand] [options]

${CYAN}::${NC} ${BOLD}Launch${NC}
  llm launch                  Launch the default model
  llm launch default          Launch the default model
  llm launch select           Pick a model with fzf
  llm launch <model>          Launch a model by filename
  llm launch ... -- <flags>   Pass extra flags to llama-cli

${CYAN}::${NC} ${BOLD}Configuration${NC}
  llm config show             Show the effective configuration
  llm config edit             Interactive configuration menu
  llm config set <key> <val>  Set a configuration value
  llm config default          Choose the default model
  llm config device           Choose the GPU/device
  llm config context          Choose the context size
  llm config ngl              Choose GPU layers offloaded
  llm config memory           Choose the long-term memory file

${CYAN}::${NC} ${BOLD}Diagnostics${NC}
  llm health                  Check the installation
  llm version                 Show version and paths

${CYAN}::${NC} ${BOLD}Models${NC}
  llm models                  List local models
  llm models download <url>   Download a .gguf file

${CYAN}::${NC} ${BOLD}Setup${NC}
  llm setup                   Run the setup script

${CYAN}::${NC} ${BOLD}Examples${NC}
  llm launch select
  llm launch Qwen3-1.7B-Q4_K_M.gguf -- --temp 0.2
  llm config set CONTEXT_SIZE 32768
  llm health

${DIM}Run 'llm help <command>' for command-specific details.
Exit codes: 0 success, 1 failure, 2 usage error.${NC}
EOF
}

help_help() {
    cat <<EOF
${BOLD}llm help${NC} [command]

Show the full command list, or detailed help for one command.

  llm help              Full help
  llm help launch       Help for 'launch'
  llm --help            Same as 'llm help'
EOF
}

help_version() {
    cat <<EOF
${BOLD}llm version${NC}

Print the llm-launcher version and important paths.
EOF
}
