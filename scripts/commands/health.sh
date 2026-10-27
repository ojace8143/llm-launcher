#!/usr/bin/env bash
# `llm health` — installation diagnostics.

cmd_health() {
    local failures=0

    check_ok() {
        printf '  %s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"
    }

    check_fail() {
        printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$*"
        failures=$((failures + 1))
    }

    section "Health check"

    if [[ -n "${LLM_HOME:-}" && -n "${MODEL_DIR:-}" && -n "${LLAMA_BIN:-}" ]]; then
        check_ok "configuration loaded"
    else
        check_fail "configuration incomplete (run ./setup.sh)"
    fi

    if [[ -x "${LLAMA_BIN:-}" ]]; then
        check_ok "llama.cpp binary found: $LLAMA_BIN"
    else
        check_fail "llama.cpp binary not found: ${LLAMA_BIN:-unset}"
    fi

    if [[ -d "${MODEL_DIR:-}" ]]; then
        check_ok "model directory found: $MODEL_DIR"
    else
        check_fail "model directory not found: ${MODEL_DIR:-unset}"
    fi

    local -a models=()
    if [[ -d "${MODEL_DIR:-}" ]]; then
        mapfile -t models < <(list_models)
    fi
    if (( ${#models[@]} > 0 )); then
        check_ok "${#models[@]} model(s) available"
    else
        check_fail "no .gguf models in ${MODEL_DIR:-models}"
    fi

    if [[ -z "${DEFAULT_MODEL:-}" ]]; then
        check_fail "no default model configured"
    elif [[ -f "$MODEL_DIR/$DEFAULT_MODEL" ]]; then
        check_ok "default model found: $DEFAULT_MODEL"
    else
        check_fail "default model missing: $DEFAULT_MODEL"
    fi

    if [[ -x "${LLAMA_SERVER_BIN:-}" ]]; then
        check_ok "llama-server found: $LLAMA_SERVER_BIN"
    else
        check_fail "llama-server not found: ${LLAMA_SERVER_BIN:-unset}"
    fi

    if [[ -n "${DEVICE:-}" ]]; then
        if validate_device_list "$DEVICE"; then
            check_ok "configured device(s) found: $DEVICE"
        else
            check_fail "configured device not found: $DEVICE"
        fi
    else
        check_ok "device selection: CPU / auto"
    fi

    if validate_gpu_config; then
        check_ok "GPU settings valid (split: ${SPLIT_MODE:-layer})"
    else
        check_fail "invalid GPU settings"
    fi

    if [[ "${MEMORY_ENABLED:-false}" == "true" ]]; then
        if [[ -f "${MEMORY_FILE:-}" ]]; then
            check_ok "memory file found: $MEMORY_FILE"
        else
            check_fail "memory enabled but file missing: ${MEMORY_FILE:-unset}"
        fi
    else
        check_ok "long-term memory disabled"
    fi

    if have_cmd fzf; then
        check_ok "fzf found"
    else
        check_fail "fzf not found (interactive commands will fail)"
    fi

    if [[ -r "${LLM_CONFIG:-}" ]]; then
        check_ok "local config readable: $LLM_CONFIG"
    else
        check_ok "local config not created yet (using defaults)"
    fi

    if [[ -n "${MCP_CONFIG:-}" ]]; then
        if [[ -f "$MCP_CONFIG" ]]; then
            check_ok "MCP config found: $MCP_CONFIG"
        else
            check_fail "MCP config missing: $MCP_CONFIG"
        fi
    fi

    if [[ -n "${AGENT_WORKSPACE:-}" ]]; then
        if [[ -d "$AGENT_WORKSPACE" ]]; then
            check_ok "agent workspace found: $AGENT_WORKSPACE"
        else
            check_fail "agent workspace missing: $AGENT_WORKSPACE"
        fi
    fi

    if [[ -f "${RUN_DIR:-$LLM_HOME/run}/server.pid" ]]; then
        check_ok "background server PID file present"
    fi

    echo
    if (( failures == 0 )); then
        printf '%sAll health checks passed.%s\n' "$GREEN" "$NC"
        return 0
    fi

    if (( failures == 1 )); then
        printf '%s1 health check failed.%s See the messages above.\n' "$RED" "$NC"
    else
        printf '%s%d health checks failed.%s See the messages above.\n' "$RED" "$failures" "$NC"
    fi
    return 1
}

help_health() {
    cat <<EOF
${BOLD}llm health${NC}

Check the configuration, llama.cpp binaries, models, devices,
multi-GPU split settings, memory file, server paths, and fzf.

  llm health        Run checks (exit 1 if any fail)
  llm config check  Configuration-only checks
EOF
}
