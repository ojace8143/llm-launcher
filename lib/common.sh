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
VERSION="${VERSION:-0.3.0}"

PROFILE_TOOLS="read_file,file_glob_search,grep_search,get_info,write_file,edit_file"
ALL_TOOLS="read_file,file_glob_search,grep_search,get_info,write_file,edit_file,exec_shell_command"

print_argv() {
    local -a argv=("$@")
    printf '%q ' "${argv[@]}"
    printf '\n'
}

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

# Resolve a model name, path, or partial name to a filename/path.
# Prints the resolved name; returns 1 if nothing matched.
resolve_model() {
    local query="${1:-}"
    [[ -n "$query" ]] || return 1

    if [[ "$query" == /* && -f "$query" ]]; then
        printf '%s\n' "$query"
        return 0
    fi

    if [[ -f "${MODEL_DIR:-}/$query" ]]; then
        printf '%s\n' "$query"
        return 0
    fi

    local -a matches=() m
    while IFS= read -r m; do
        [[ "$m" == *"$query"* ]] && matches+=("$m")
    done < <(list_models)

    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    if (( ${#matches[@]} > 1 )); then
        require_fzf
        printf '%s\n' "${matches[@]}" |
            fzf --height 40% --reverse --border --prompt="Multiple matches> " || true
        return 0
    fi

    return 1
}

# Per-model profile: config/profiles/<model-without-.gguf>.sh
profile_path() {
    local base="${1##*/}"
    base="${base%.gguf}"
    printf '%s/config/profiles/%s.sh\n' "$LLM_HOME" "$base"
}

load_profile() {
    local profile
    profile="$(profile_path "$1")"
    if [[ -f "$profile" ]]; then
        # shellcheck source=/dev/null
        source "$profile"
    fi
}

# ---------------------------------------------------------------------------
# Device helpers
# ---------------------------------------------------------------------------

# Print device rows: ID<TAB>description<TAB>free_mib<TAB>total_mib
# Set LLM_DEVICES_FIXTURE to a file to test parsing without GPU hardware.
llama_devices() {
    local input=""
    if [[ -n "${LLM_DEVICES_FIXTURE:-}" && -f "$LLM_DEVICES_FIXTURE" ]]; then
        input="$(cat "$LLM_DEVICES_FIXTURE")"
    elif [[ -x "${LLAMA_BIN:-}" ]]; then
        input="$("$LLAMA_BIN" --list-devices 2>/dev/null || true)"
    fi

    local line id desc free total
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]+([A-Za-z0-9_.-]+):[[:space:]]*(.*)$ ]] || continue
        id="${BASH_REMATCH[1]}"
        desc="${BASH_REMATCH[2]}"
        free=""
        total=""
        if [[ "$desc" =~ \(([0-9]+)[[:space:]]*MiB,[[:space:]]*([0-9]+)[[:space:]]*MiB[[:space:]]+free\) ]]; then
            total="${BASH_REMATCH[1]}"
            free="${BASH_REMATCH[2]}"
        fi
        printf '%s\t%s\t%s\t%s\n' "$id" "$desc" "$free" "$total"
    done <<<"$input"
}

# True when every comma-separated device ID is known.
validate_device_list() {
    local csv="${1:-}"
    [[ -z "$csv" ]] && return 0

    local -a known=() ids=()
    mapfile -t known < <(llama_devices | cut -f1)
    IFS=',' read -r -a ids <<<"$csv"
    local id k found
    for id in "${ids[@]}"; do
        found=0
        for k in "${known[@]}"; do
            [[ "$id" == "$k" ]] && found=1
        done
        (( found )) || return 1
    done
    return 0
}

# Compute a tensor split proportional to free VRAM, e.g. "3,1".
auto_tensor_split() {
    local csv="${1:-}"
    [[ -n "$csv" ]] || return 1

    local -A free_map=()
    local id desc free total
    while IFS=$'\t' read -r id desc free total; do
        free_map["$id"]="$free"
    done < <(llama_devices)

    local -a ids=() frees=() parts=()
    IFS=',' read -r -a ids <<<"$csv"
    local min=0 f
    for id in "${ids[@]}"; do
        f="${free_map[$id]:-}"
        [[ "$f" =~ ^[0-9]+$ ]] || return 1
        frees+=("$f")
        if (( min == 0 || f < min )); then
            min="$f"
        fi
    done
    (( min > 0 )) || return 1

    for f in "${frees[@]}"; do
        local ratio=$(( (f + min / 2) / min ))
        (( ratio < 1 )) && ratio=1
        parts+=("$ratio")
    done

    local IFS=','
    printf '%s' "${parts[*]}"
}

# Validate split-related settings. Prints an error and returns 1 on failure.
validate_gpu_config() {
    local csv="${DEVICE:-}"
    local split="${SPLIT_MODE:-layer}"

    case "$split" in
        none|layer|row|tensor) ;;
        *)
            err "Invalid SPLIT_MODE: $split (use none, layer, row, or tensor)"
            return 1
            ;;
    esac

    if [[ -n "$csv" ]] && ! validate_device_list "$csv"; then
        err "Unknown device in DEVICE: $csv"
        return 1
    fi

    if [[ -n "${TENSOR_SPLIT:-}" ]]; then
        if [[ -z "$csv" ]]; then
            err "TENSOR_SPLIT requires DEVICE to be set"
            return 1
        fi
        local -a ids=() parts=()
        IFS=',' read -r -a ids <<<"$csv"
        IFS=',' read -r -a parts <<<"$TENSOR_SPLIT"
        local p
        for p in "${parts[@]}"; do
            [[ "$p" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
                err "TENSOR_SPLIT must be a comma-separated number list: $TENSOR_SPLIT"
                return 1
            }
        done
        if (( ${#ids[@]} > 0 && ${#ids[@]} != ${#parts[@]} )); then
            err "TENSOR_SPLIT has ${#parts[@]} values but DEVICE has ${#ids[@]} devices"
            return 1
        fi
    fi

    if [[ -n "${MAIN_GPU:-}" && ! "$MAIN_GPU" =~ ^[0-9]+$ ]]; then
        err "MAIN_GPU must be a number"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Argument builders
# ---------------------------------------------------------------------------

# build_llama_args <out-array-name> <model-path>
build_llama_args() {
    local out_var="$1"
    local model="$2"
    local -n out="$out_var"

    out=(-m "$model")

    [[ -n "${NGL:-}" ]] && out+=(-ngl "$NGL")
    [[ -n "${CONTEXT_SIZE:-}" ]] && out+=(-c "$CONTEXT_SIZE")
    [[ -n "${THREADS:-}" ]] && out+=(-t "$THREADS")
    [[ -n "${THREADS_BATCH:-}" ]] && out+=(-tb "$THREADS_BATCH")
    [[ -n "${FLASH_ATTN:-}" ]] && out+=(-fa "$FLASH_ATTN")
    [[ -n "${PARALLEL:-}" && "${PARALLEL}" != "1" ]] && out+=(-np "$PARALLEL")

    [[ -n "${DEVICE:-}" ]] && out+=(--device "$DEVICE")
    if [[ -n "${SPLIT_MODE:-}" && "${DEVICE:-}" == *,* ]]; then
        out+=(--split-mode "$SPLIT_MODE")
    fi
    [[ -n "${TENSOR_SPLIT:-}" ]] && out+=(--tensor-split "$TENSOR_SPLIT")
    if [[ -n "${DEVICE:-}" && -n "${MAIN_GPU:-}" ]]; then
        out+=(--main-gpu "$MAIN_GPU")
    fi
    [[ -n "${FIT:-}" ]] && out+=(--fit "$FIT")

    [[ -n "${TEMP:-}" ]] && out+=(--temp "$TEMP")
    [[ -n "${TOP_P:-}" ]] && out+=(--top-p "$TOP_P")

    local -a extra=()
    if [[ "$(declare -p EXTRA_ARGS 2>/dev/null)" == declare\ -a* ]]; then
        extra=("${EXTRA_ARGS[@]}")
    elif [[ -n "${EXTRA_ARGS:-}" ]]; then
        read -r -a extra <<<"$EXTRA_ARGS"
    fi
    if (( ${#extra[@]} > 0 )); then
        out+=("${extra[@]}")
    fi
    return 0
}

# build_server_args <out-array-name> <model-path>
build_server_args() {
    local out_var="$1"
    local model="$2"
    local -n out="$out_var"

    build_llama_args "$out_var" "$model"

    out+=(--host "${SERVER_HOST:-127.0.0.1}" --port "${SERVER_PORT:-9931}")
    [[ -n "${SERVER_API_KEY:-}" ]] && out+=(--api-key "$SERVER_API_KEY")

    if [[ "${SERVER_AGENT:-false}" == "true" ]]; then
        out+=(--agent)
    elif [[ -n "${SERVER_TOOLS:-}" ]]; then
        out+=(--tools "$SERVER_TOOLS")
    fi

    [[ -n "${MCP_CONFIG:-}" ]] && out+=(--mcp-servers-config "$MCP_CONFIG")
    return 0
}

# ---------------------------------------------------------------------------
# Launch helper
# ---------------------------------------------------------------------------

# Build the full llama-cli argv for a model.
# prepare_launch <args-var> <resolved-model-var> <model-query>
prepare_launch() {
    local args_var="$1"
    local model_var="$2"
    local query="$3"
    local -n _args="$args_var"
    local -n _resolved="$model_var"

    local resolved
    resolved="$(resolve_model "$query")" || return 1
    [[ -n "$resolved" ]] || return 1

    if [[ "$resolved" != /* ]]; then
        resolved="${MODEL_DIR:-}/$resolved"
    fi
    [[ -f "$resolved" ]] || return 1
    [[ -x "${LLAMA_BIN:-}" ]] || {
        err "llama.cpp is not built. Run ./setup.sh"
        return 1
    }

    load_profile "$resolved"
    validate_gpu_config || return 1

    local -a built=()
    build_llama_args built "$resolved"

    if [[ "${MEMORY_ENABLED:-false}" == "true" ]]; then
        [[ -f "${MEMORY_FILE:-}" ]] || {
            err "Memory is enabled but the file is missing: ${MEMORY_FILE:-unset}"
            return 1
        }
        built+=(--system-prompt-file "$MEMORY_FILE")
    fi

    _resolved="$resolved"
    _args=("${built[@]}")
}

# launch_model <name-or-path> [extra llama-cli args...]
launch_model() {
    [[ $# -ge 1 ]] || die "launch_model: missing model"
    local query="$1"
    shift

    local resolved=""
    local -a args=()
    prepare_launch args resolved "$query" || die "Unable to launch model: $query"

    exec "$LLAMA_BIN" "${args[@]}" "$@"
}

# Remove a key from the local config file.
config_unset() {
    local key="${1:-}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Invalid config key: $key"
    [[ -f "$LLM_CONFIG" ]] || return 0

    local tmp
    tmp="$(mktemp "${LLM_CONFIG}.XXXXXX")" || die "Unable to create temporary file"
    grep -v "^${key}=" "$LLM_CONFIG" >"$tmp" || true
    mv "$tmp" "$LLM_CONFIG"
}

config_is_set() {
    [[ -f "$LLM_CONFIG" ]] && grep -q "^${1}=" "$LLM_CONFIG"
}
