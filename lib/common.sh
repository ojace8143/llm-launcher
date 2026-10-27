#!/usr/bin/env bash
# Shared helpers for the llm dispatcher and setup.sh.
# This file is meant to be sourced, not executed.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Resolve a script path, following symlinks. Usage: resolve_dir "/path/to/script"
resolve_dir() {
    local src="${1:-${BASH_SOURCE[0]}}"
    local dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

_COMMON_DIR="$(resolve_dir "${BASH_SOURCE[0]}")"
LLM_HOME="${LLM_HOME:-$(cd "$_COMMON_DIR/.." && pwd)}"
export LLM_HOME

LLM_CONFIG="${LLM_CONFIG:-$LLM_HOME/config/config.local.sh}"
VERSION="${VERSION:-0.2.0}"

# ---------------------------------------------------------------------------
# Colors (only when writing to a terminal)
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info() { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err() { printf '%s[ERR]%s %s\n' "$RED" "$NC" "$*" >&2; }
section() { printf '\n%s::%s %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$1" "$NC"; }
subsection() { printf '  %s->%s %s\n' "$BLUE" "$NC" "$*"; }
die() {
    err "$*"
    exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

# Print the current value of a config variable.
config_get() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 1
    printf '%s' "${!key-}"
}

# Escape a value for a double-quoted shell assignment.
_config_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '%s' "$value"
}

# Set KEY=VALUE in the local config file, replacing an existing entry.
config_set() {
    local key="${1:-}"
    local value="${2-}"
    local file="$LLM_CONFIG"
    local escaped tmp

    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Invalid config key: $key"

    mkdir -p "$(dirname "$file")"
    escaped="$(_config_escape "$value")"
    tmp="$(mktemp "${file}.XXXXXX")" || die "Unable to create temporary file"

    if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
        # Pass the value through the environment: awk -v would interpret
        # backslash escapes and strip the escaping we just added.
        V="$escaped" awk -v k="$key" '
            index($0, k"=") == 1 { print k"=\"" ENVIRON["V"] "\""; next }
            { print }
        ' "$file" >"$tmp" || {
            rm -f "$tmp"
            die "Failed to update $file"
        }
    else
        if [[ -f "$file" ]]; then
            cat "$file" >"$tmp" || {
                rm -f "$tmp"
                die "Failed to read $file"
            }
        else
            printf '%s\n' "# llm-launcher local settings (gitignored)" >"$tmp"
        fi
        # Make sure the existing file ends with a newline before appending.
        if [[ -s "$tmp" ]] && [[ "$(tail -c 1 "$tmp" | wc -l)" -eq 0 ]]; then
            printf '\n' >>"$tmp"
        fi
        printf '%s="%s"\n' "$key" "$escaped" >>"$tmp"
    fi

    mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Model helpers
# ---------------------------------------------------------------------------

# List .gguf filenames in MODEL_DIR, one per line.
list_models() {
    [[ -n "${MODEL_DIR:-}" && -d "$MODEL_DIR" ]] || return 0
    local -a models=()
    shopt -s nullglob
    models=("$MODEL_DIR"/*.gguf)
    shopt -u nullglob
    local m
    for m in "${models[@]}"; do
        printf '%s\n' "${m##*/}"
    done
}

require_fzf() {
    have_cmd fzf || die "fzf is required for interactive commands. Install fzf and try again."
}

# Interactive model picker. Prints the selected filename.
pick_model() {
    require_fzf
    local -a models=()
    mapfile -t models < <(list_models)
    if (( ${#models[@]} == 0 )); then
        warn "No .gguf models found in ${MODEL_DIR:-models}"
        return 1
    fi
    printf '%s\n' "${models[@]}" |
        fzf --height 40% --reverse --border --prompt="Select model> " || true
}

# ---------------------------------------------------------------------------
# Launch helper
# ---------------------------------------------------------------------------

# launch_model <name-or-path> [extra llama-cli args...]
launch_model() {
    [[ $# -ge 1 ]] || die "launch_model: missing model"
    local model="$1"
    shift

    if [[ "$model" != /* ]]; then
        model="${MODEL_DIR:-}/$model"
    fi

    [[ -f "$model" ]] || die "Model not found: $model"
    [[ -x "${LLAMA_BIN:-}" ]] || die "llama.cpp is not built. Run ./setup.sh"

    local -a args=(
        -m "$model"
        -ngl "${NGL:-99}"
        -c "${CONTEXT_SIZE:-16384}"
    )

    if [[ -n "${DEVICE:-}" ]]; then
        args+=(--device "$DEVICE")
    fi

    if [[ "${MEMORY_ENABLED:-false}" == "true" ]]; then
        [[ -f "${MEMORY_FILE:-}" ]] || die "Memory is enabled but the file is missing: ${MEMORY_FILE:-unset}"
        args+=(--system-prompt-file "$MEMORY_FILE")
    fi

    exec "$LLAMA_BIN" "${args[@]}" "$@"
}
