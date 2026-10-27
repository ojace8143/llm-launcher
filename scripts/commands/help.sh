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
  llm launch <model>          Launch by full or partial model name
  llm launch ... -- <flags>   Pass extra flags to llama-cli

${CYAN}::${NC} ${BOLD}Configuration${NC}
  llm config show [--json]    Show the effective configuration
  llm config edit             Interactive configuration menu
  llm config get <key>        Print a configuration value
  llm config set <key> <val>  Set a configuration value
  llm config unset <key>      Remove a local override
  llm config reset            Reset local config (backs up first)
  llm config path             Print the local config path
  llm config open             Open the local config in \$EDITOR
  llm config default          Choose the default model
  llm config device           Choose GPU devices (multi-select)
  llm config context          Choose the context size
  llm config ngl              Choose GPU layers offloaded
  llm config memory           Choose the long-term memory file
  llm config check            Validate the configuration

${CYAN}::${NC} ${BOLD}Diagnostics${NC}
  llm health                  Check the installation
  llm version                 Show version and paths

${CYAN}::${NC} ${BOLD}Models${NC}
  llm models                  List local models
  llm models add <path>       Add a .gguf to the models directory
  llm models download <url>   Download a .gguf file

${CYAN}::${NC} ${BOLD}GPU${NC}
  llm devices                 List devices and free memory
  llm config device           Select one or more devices
  llm config split            Split mode
  llm config tensor-split     Tensor split (auto or manual)

${CYAN}::${NC} ${BOLD}Server${NC}
  llm serve                   Start llama-server in the foreground
  llm serve --background      Start in the background
  llm serve status|stop|logs  Manage the background server

${CYAN}::${NC} ${BOLD}Agent${NC}
  llm agent                   Web UI agent with read/search/edit tools
  llm agent --shell           Also allow shell commands
  llm agent --workspace DIR   Limit the workspace

${CYAN}::${NC} ${BOLD}Setup${NC}
  llm setup                   Run the setup script
  llm completion bash|zsh     Print shell completion

${CYAN}::${NC} ${BOLD}Examples${NC}
  llm launch select
  llm launch Qwen3-1.7B-Q4_K_M.gguf -- --temp 0.2
  llm launch --device CUDA0,CUDA1 --split-mode layer
  llm config set CONTEXT_SIZE 32768
  llm serve --background
  llm agent --workspace ~/Projects/my-app
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
