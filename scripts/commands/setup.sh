#!/usr/bin/env bash
# `llm setup` — run setup.sh.

cmd_setup() {
    local script="$LLM_HOME/setup.sh"
    [[ -f "$script" ]] || die "setup.sh not found at $script"
    [[ -x "$script" ]] || chmod +x "$script" 2>/dev/null || true
    exec "$script" "$@"
}

help_setup() {
    cat <<EOF
${BOLD}llm setup${NC} [options]

Run the llm-launcher setup script. All arguments are passed through.

  llm setup                     Interactive setup
  llm setup --help              Show setup.sh options
EOF
}
