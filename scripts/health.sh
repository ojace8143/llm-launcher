#!/usr/bin/env bash

LLM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LLM_HOME/config/config.sh"

FAILURES=0

check_pass() {
    echo "$1"
}

check_fail() {
    echo "$1"
    FAILURES=$((FAILURES + 1))
}

if [[ -x "$LLAMA_BIN" ]]; then
    check_pass "llama.cpp binary found."
else
    check_fail "llama.cpp binary not found: $LLAMA_BIN"
fi

if [[ -d "$MODEL_DIR" ]]; then
    check_pass "model directory found."
else
    check_fail "model directory not found: $MODEL_DIR"
fi

if [[ -n "$DEFAULT_MODEL" && -f "$MODEL_DIR/$DEFAULT_MODEL" ]]; then
    check_pass "default model found"
elif [[ -z "$DEFAULT_MODEL" ]]; then
    check_fail "default model is not configured"
else
    check_fail "default model not found: $DEFAULT_MODEL"
fi

if [[ -n "$DEVICE" ]]; then
    if "$LLAMA_BIN" --list-devices 2>/dev/null |
        grep -q "^  $DEVICE:"; then
        check_pass "configured device ($DEVICE) found"
    else
        check_fail "configured device not found: $DEVICE"
    fi
else
    check_pass "device selection (CPU)"
fi

if [[ "$MEMORY_ENABLED" == "true" ]]; then
    if [[ -f "$MEMORY_FILE" ]]; then
        check_pass "memory file found"
    else
        check_fail "memory file not found: $MEMORY_FILE"
    fi
else
    check_pass "long-term memory disabled"
fi

# fzf
if command -v fzf >/dev/null 2>&1; then
    check_pass "fzf find"
else
    check_fail "fzf not found"
fi

echo ""

if [[ "$FAILURES" -eq 0 ]]; then
    echo "All health checks passed. Nice."
    exit 0
else
    echo "$FAILURES health check failed. Above messages will give you clues."
    exit 1
fi
