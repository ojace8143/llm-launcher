#!/usr/bin/env bash
# `llm version`

cmd_version() {
    local llama_version="unknown"
    if [[ -d "${LLAMA_HOME:-}/.git" ]] && have_cmd git; then
        llama_version="$(git -C "$LLAMA_HOME" describe --tags --always --dirty 2>/dev/null || echo unknown)"
    fi

    printf 'llm-launcher %s\n' "$VERSION"
    printf '  LLM_HOME    %s\n' "$LLM_HOME"
    printf '  llama.cpp   %s\n' "$llama_version"
    printf '  llama-cli   %s\n' "${LLAMA_BIN:-unset}"
    printf '  config      %s\n' "$LLM_CONFIG"
}

help_version() {
    cat <<EOF
${BOLD}llm version${NC}

Print the llm-launcher version and important paths.
EOF
}
