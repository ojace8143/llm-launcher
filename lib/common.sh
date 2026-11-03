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
VERSION="${VERSION:-0.5.0}"

PROFILE_TOOLS="read_file,file_glob_search,grep_search,get_info,write_file,edit_file"
ALL_TOOLS="read_file,file_glob_search,grep_search,get_info,write_file,edit_file,exec_shell_command"

# Keys allowed in a per-model profile (config/profiles/<model>.sh).
PROFILE_KEYS="CONTEXT_SIZE NGL THREADS THREADS_BATCH FLASH_ATTN PARALLEL TEMP TOP_P EXTRA_ARGS DEVICE SPLIT_MODE TENSOR_SPLIT MAIN_GPU FIT"

# Runtime flags given on the command line. These are re-applied after a profile
# is loaded so CLI options beat both global config and per-model profiles.
declare -A CLI_OVERRIDES=()

apply_cli_overrides() {
    local key
    for key in "${!CLI_OVERRIDES[@]}"; do
        printf -v "$key" '%s' "${CLI_OVERRIDES[$key]}"
    done
    return 0
}

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

# The llm-launcher banner used by setup and `llm version`.
llm_ascii_art() {
    cat <<'EOF'
   __    __             __                        _
  / /   / /   /\/\     / /  __ _ _   _ _ __   ___| |__   ___ _ __
 / /   / /   /    \   / /  / _` | | | | '_ \ / __| '_ \ / _ \ '__|
/ /___/ /___/ /\/\ \ / /__| (_| | |_| | | | | (__| | | |  __/ |
\____/\____/\/    \/ \____/\__,_|\__,_|_| |_|\___|_| |_|\___|_|

EOF
}

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

# Set KEY=VALUE in a config-style file, replacing an existing entry.
config_set_file() {
    local file="${1:-}"
    local key="${2:-}"
    local value="${3-}"
    local escaped tmp

    [[ -n "$file" ]] || die "config_set_file: missing file"
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

# Set KEY=VALUE in the local (global) config file.
config_set() {
    config_set_file "$LLM_CONFIG" "${1:-}" "${2-}"
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
    return 0
}

# Create a profile file if it does not exist. Prints its path.
profile_init() {
    local model="$1"
    local file
    file="$(profile_path "$model")"
    if [[ -f "$file" ]]; then
        printf '%s\n' "$file"
        return 0
    fi

    mkdir -p "$(dirname "$file")"
    {
        printf '# Per-model settings for %s\n' "${model##*/}"
        printf '# Created by llm models config. Overrides config.local.sh for this model.\n'
        printf '# Keys: %s\n\n' "$PROFILE_KEYS"
    } >"$file"
    printf '%s\n' "$file"
}

# True when KEY is explicitly set in a profile file.
profile_has_key() {
    local file="$1" key="$2"
    [[ -f "$file" ]] && grep -qE "^${key}\\+?=" "$file"
}

# Set KEY=VALUE in a model profile.
profile_set() {
    local model="$1"
    local key="${2:-}"
    shift 2 || true
    local value="$*"
    local file

    [[ " $PROFILE_KEYS " == *" $key "* ]] || {
        err "Unknown per-model key: $key"
        err "Keys: $PROFILE_KEYS"
        return 2
    }

    file="$(profile_init "$model")" || return 1
    config_set_file "$file" "$key" "$value"
}

# Remove KEY from a model profile.
profile_unset() {
    local model="$1"
    local key="${2:-}"
    local file

    [[ " $PROFILE_KEYS " == *" $key "* ]] || {
        err "Unknown per-model key: $key"
        return 2
    }

    file="$(profile_path "$model")"
    config_unset_file "$file" "$key"
}

# Delete a model profile.
profile_remove() {
    local file
    file="$(profile_path "$1")"
    rm -f "$file"
}

# Validate every per-model profile. Returns 1 when any profile is invalid.
validate_all_profiles() {
    local failures=0
    local -a files=()
    shopt -s nullglob
    files=("$LLM_HOME"/config/profiles/*.sh)
    shopt -u nullglob

    local file base model
    for file in "${files[@]}"; do
        base="${file##*/}"
        base="${base%.sh}"
        [[ "$base" == "example" ]] && continue

        model="${MODEL_DIR:-}/$base.gguf"
        if [[ ! -f "$model" ]]; then
            warn "Profile has no matching model: ${file##*/}"
            continue
        fi
        if ! ( load_profile "$model"; validate_gpu_config ); then
            failures=$((failures + 1))
        fi
    done

    (( failures == 0 ))
}

# Resolve a model name, path, partial name, or alias to a filename/path.
resolve_model_or_alias() {
    local query="${1:-}"
    local target

    if target="$(model_for_alias "$query")"; then
        resolve_model "$target"
        return $?
    fi
    resolve_model "$query"
}

# Resolve a model name to an absolute path. Prints the input unchanged when it
# cannot be resolved, so callers can still validate the result themselves.
absolute_model_path() {
    local model="$1"
    if [[ "$model" != /* ]]; then
        model="${MODEL_DIR:-}/$model"
    fi
    local dir
    if ! dir="$(cd "$(dirname "$model")" 2>/dev/null && pwd)"; then
        printf '%s\n' "$model"
        return 1
    fi
    printf '%s/%s\n' "$dir" "$(basename "$model")"
}

# ---------------------------------------------------------------------------
# Model aliases
#
# MODEL_ALIASES is a comma-separated list of alias=model pairs, for example:
#   MODEL_ALIASES="coder=coding-model.gguf,general=general-model.gguf"
#
# Aliases are used as llama-server --alias values, router preset section names,
# and OpenCode model IDs.
# ---------------------------------------------------------------------------

_alias_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Print alias<TAB>model for every valid entry in MODEL_ALIASES.
model_alias_entries() {
    local raw="${MODEL_ALIASES:-}"
    [[ -n "$raw" ]] || return 0

    local item alias model
    local -a items=()
    IFS=',' read -r -a items <<<"$raw"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" && "$item" == *=* ]] || continue
        alias="${item%%=*}"
        model="${item#*=}"
        alias="${alias#"${alias%%[![:space:]]*}"}"
        alias="${alias%"${alias##*[![:space:]]}"}"
        model="${model#"${model%%[![:space:]]*}"}"
        model="${model%"${model##*[![:space:]]}"}"
        [[ -n "$alias" && -n "$model" ]] || continue
        printf '%s\t%s\n' "$alias" "$model"
    done
}

# Expand an alias target to a path without requiring the file to exist.
alias_model_path() {
    local model="$1"
    if [[ "$model" == /* || "$model" == */* ]]; then
        printf '%s\n' "$model"
    else
        printf '%s/%s\n' "${MODEL_DIR:-}" "$model"
    fi
}

# Turn a filename stem into a safe model ID.
sanitize_model_id() {
    local id="${1:-}"
    id="${id//[^A-Za-z0-9._-]/-}"
    id="$(printf '%s' "$id" | sed -E 's/^-+//; s/-+$//')"
    [[ -n "$id" ]] || id="model"
    printf '%s\n' "$id"
}

# Print the configured alias for a model, or its sanitized filename stem.
alias_for_model() {
    local model="$1"
    local base model_path alias target
    base="${model##*/}"
    base="${base%.gguf}"
    model_path="$(absolute_model_path "$model" 2>/dev/null)" || model_path="$model"

    while IFS=$'\t' read -r alias target; do
        local target_path
        target_path="$(alias_model_path "$target")"
        if [[ "$target" == "$base" ||
            "$target" == "$model" ||
            "$target" == "${model##*/}" ||
            "$target_path" == "$model" ||
            "$target_path" == "$model_path" ]]; then
            printf '%s\n' "$alias"
            return 0
        fi
    done < <(model_alias_entries)

    sanitize_model_id "$base"
}

# Print the model configured for an alias.
model_for_alias() {
    local wanted="$1" alias target
    while IFS=$'\t' read -r alias target; do
        if [[ "$alias" == "$wanted" ]]; then
            printf '%s\n' "$target"
            return 0
        fi
    done < <(model_alias_entries)
    return 1
}

# Validate MODEL_ALIASES, or the value passed as the first argument.
validate_aliases() {
    local raw="${1:-${MODEL_ALIASES:-}}"
    local failures=0
    local -A seen=()

    if [[ -z "$raw" ]]; then
        return 0
    fi

    local item alias target path
    local -a items=()
    IFS=',' read -r -a items <<<"$raw"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        if [[ "$item" != *=* ]]; then
            err "Invalid MODEL_ALIASES entry (expected alias=model): $item"
            failures=$((failures + 1))
            continue
        fi
        alias="${item%%=*}"
        target="${item#*=}"
        alias="${alias#"${alias%%[![:space:]]*}"}"
        alias="${alias%"${alias##*[![:space:]]}"}"
        target="${target#"${target%%[![:space:]]*}"}"
        target="${target%"${target##*[![:space:]]}"}"

        if ! _alias_valid "$alias"; then
            err "Invalid model alias '$alias' (use letters, numbers, dot, underscore, or dash)"
            failures=$((failures + 1))
        elif [[ -n "${seen[$alias]:-}" ]]; then
            err "Duplicate model alias: $alias"
            failures=$((failures + 1))
        else
            seen[$alias]=1
        fi

        path="$(alias_model_path "$target")"
        if [[ -z "$target" || ! -f "$path" ]]; then
            err "Alias '$alias' points to a missing model: ${path:-$target}"
            failures=$((failures + 1))
        fi
    done

    (( failures == 0 ))
}

# Read the context size for a model, honoring its profile.
context_for_model() {
    local model="$1"
    (
        load_profile "$model"
        printf '%s' "${CONTEXT_SIZE:-}"
    )
}

# Build a router preset exposing every installed model. Alias entries become
# preset section names; unaliased models use their sanitized filename.
write_router_preset() {
    local path="$1"
    local -a models=()
    mapfile -t models < <(list_models)
    if (( ${#models[@]} == 0 )); then
        err "No .gguf models found in ${MODEL_DIR:-models}"
        return 1
    fi

    local model_dir="$MODEL_DIR"
    if [[ "$model_dir" != /* ]]; then
        model_dir="$(cd "$model_dir" 2>/dev/null && pwd)" || {
            err "Unable to resolve model directory: $MODEL_DIR"
            return 1
        }
    fi

    local tmp
    tmp="$(mktemp "${path}.XXXXXX")" || {
        err "Unable to create temporary file for $path"
        return 1
    }

    local -A seen=()
    local base resolved id body profile
    {
        printf '# Generated by llm-launcher. Do not edit.\n'
        printf 'version = 1\n\n'
        for base in "${models[@]}"; do
            resolved="$model_dir/$base"
            id="$(alias_for_model "$resolved")"
            if [[ -n "${seen[$id]:-}" ]]; then
                err "Duplicate model ID '$id' for $base and ${seen[$id]}"
                rm -f "$tmp"
                return 1
            fi
            seen[$id]="$base"

            profile="$(profile_path "$base")"
            # Each section is self-contained so a profile override cannot
            # inherit an incompatible global split setting.
            if ! body="$(
                load_profile "$resolved"
                apply_cli_overrides
                validate_gpu_config || exit 1
                preset_runtime_lines || exit 1
            )"; then
                err "Invalid runtime settings for $base"
                [[ -f "$profile" ]] && err "Check profile: $profile"
                rm -f "$tmp"
                return 1
            fi

            printf '[%s]\n' "$id"
            printf 'model = %s\n' "$resolved"
            if [[ -n "$body" ]]; then
                printf '%s\n' "$body"
            fi
            printf '\n'
        done
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }

    mv -- "$tmp" "$path"
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

# True when the device value means CPU-only offload.
device_is_cpu() {
    [[ "${1:-}" == "none" || "${1:-}" == "cpu" ]]
}

# True when every comma-separated device ID is known.
validate_device_list() {
    local csv="${1:-}"
    [[ -z "$csv" ]] && return 0
    device_is_cpu "$csv" && return 0

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

# Interactive device picker. Prints a comma-separated device list, or "none"
# for CPU only. Returns 1 when no devices exist or the selection is cancelled.
select_devices() {
    require_fzf
    local -a rows=() choices=()
    mapfile -t rows < <(llama_devices)
    if (( ${#rows[@]} == 0 )); then
        warn "No devices reported by llama.cpp (CPU-only build or no GPU)."
        return 1
    fi

    choices+=("CPU only")
    local row id desc free total
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id desc free total <<<"$row"
        choices+=("$id|$desc")
    done

    local -a selection=()
    mapfile -t selection < <(
        printf '%s\n' "${choices[@]}" |
            fzf --multi --height 40% --reverse --border --prompt="Devices (TAB to multi-select)> " || true
    )
    (( ${#selection[@]} > 0 )) || return 1

    local -a ids=()
    local choice
    for choice in "${selection[@]}"; do
        [[ "$choice" == "CPU only" ]] && { ids=(); break; }
        ids+=("${choice%%|*}")
    done

    if (( ${#ids[@]} == 0 )); then
        printf 'none\n'
    else
        local IFS=','
        printf '%s\n' "${ids[*]}"
    fi
    return 0
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

    # Split settings only apply when more than one device is selected.
    if [[ -n "${TENSOR_SPLIT:-}" && "$csv" == *,* ]]; then
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

# Expand EXTRA_ARGS into an array, accepting either a string or a bash array.
collect_extra_args() {
    local out_var="$1"
    local -n out="$out_var"
    out=()

    if [[ "$(declare -p EXTRA_ARGS 2>/dev/null)" == declare\ -a* ]]; then
        out=("${EXTRA_ARGS[@]}")
    elif [[ -n "${EXTRA_ARGS:-}" ]]; then
        local -a parsed=()
        read -r -a parsed <<<"$EXTRA_ARGS"
        out=("${parsed[@]}")
    fi
    return 0
}

# Print EXTRA_ARGS as one space-separated string.
extra_args_string() {
    local -a extra=()
    collect_extra_args extra
    local IFS=' '
    printf '%s' "${extra[*]}"
}

# Convert EXTRA_ARGS entries to router preset keys.
# Examples: "-ctk q4_0" -> "ctk = q4_0", "--no-mmap" -> "no-mmap = true".
preset_extra_lines() {
    local -a extra=("$@")
    local -A seen=()
    local i=0 token key value next

    while (( i < ${#extra[@]} )); do
        token="${extra[$i]}"
        case "$token" in
            --*=*)
                key="${token%%=*}"
                key="${key#--}"
                value="${token#*=}"
                ;;
            -*)
                key="${token#-}"
                key="${key#-}"
                value="true"
                if (( i + 1 < ${#extra[@]} )); then
                    next="${extra[$((i + 1))]}"
                    if [[ "$next" != -* || "$next" =~ ^-[0-9] ]]; then
                        value="$next"
                        i=$((i + 1))
                    fi
                fi
                ;;
            *)
                err "EXTRA_ARGS: cannot convert '$token' to a router preset option"
                return 1
                ;;
        esac

        if [[ -z "$key" ]]; then
            err "EXTRA_ARGS: empty option name in '$token'"
            return 1
        fi
        if [[ -n "${seen[$key]:-}" ]]; then
            err "EXTRA_ARGS: repeated option '$key' is not supported in router mode"
            return 1
        fi
        seen["$key"]=1
        printf '%s = %s\n' "$key" "$value"
        i=$((i + 1))
    done
    return 0
}

# Emit the current runtime settings as router preset INI lines.
preset_runtime_lines() {
    [[ -n "${NGL:-}" ]] && printf 'n-gpu-layers = %s\n' "$NGL"
    [[ -n "${CONTEXT_SIZE:-}" ]] && printf 'c = %s\n' "$CONTEXT_SIZE"
    [[ -n "${THREADS:-}" ]] && printf 'threads = %s\n' "$THREADS"
    [[ -n "${THREADS_BATCH:-}" ]] && printf 'threads-batch = %s\n' "$THREADS_BATCH"
    [[ -n "${FLASH_ATTN:-}" ]] && printf 'flash-attn = %s\n' "$FLASH_ATTN"
    [[ -n "${PARALLEL:-}" && "${PARALLEL}" != "1" ]] && printf 'parallel = %s\n' "$PARALLEL"

    if [[ -n "${DEVICE:-}" ]]; then
        if device_is_cpu "$DEVICE"; then
            printf 'device = none\n'
        else
            printf 'device = %s\n' "$DEVICE"
            if [[ "$DEVICE" == *,* ]]; then
                [[ -n "${SPLIT_MODE:-}" ]] && printf 'split-mode = %s\n' "$SPLIT_MODE"
                [[ -n "${TENSOR_SPLIT:-}" ]] && printf 'tensor-split = %s\n' "$TENSOR_SPLIT"
                [[ -n "${MAIN_GPU:-}" ]] && printf 'main-gpu = %s\n' "$MAIN_GPU"
            fi
        fi
    fi
    [[ -n "${FIT:-}" ]] && printf 'fit = %s\n' "$FIT"

    [[ -n "${TEMP:-}" ]] && printf 'temp = %s\n' "$TEMP"
    [[ -n "${TOP_P:-}" ]] && printf 'top-p = %s\n' "$TOP_P"

    local -a extra=()
    collect_extra_args extra
    if (( ${#extra[@]} > 0 )); then
        preset_extra_lines "${extra[@]}" || return 1
    fi
    return 0
}

# build_runtime_args <out-array-name>
# Model/runtime options shared by llama-cli, and single-model llama-server.
build_runtime_args() {
    local out_var="$1"
    local -n out="$out_var"

    out=()

    [[ -n "${NGL:-}" ]] && out+=(-ngl "$NGL")
    [[ -n "${CONTEXT_SIZE:-}" ]] && out+=(-c "$CONTEXT_SIZE")
    [[ -n "${THREADS:-}" ]] && out+=(-t "$THREADS")
    [[ -n "${THREADS_BATCH:-}" ]] && out+=(-tb "$THREADS_BATCH")
    [[ -n "${FLASH_ATTN:-}" ]] && out+=(-fa "$FLASH_ATTN")
    [[ -n "${PARALLEL:-}" && "${PARALLEL}" != "1" ]] && out+=(-np "$PARALLEL")

    if [[ -n "${DEVICE:-}" ]]; then
        if device_is_cpu "$DEVICE"; then
            out+=(--device none)
        else
            out+=(--device "$DEVICE")
            if [[ "$DEVICE" == *,* ]]; then
                [[ -n "${SPLIT_MODE:-}" ]] && out+=(--split-mode "$SPLIT_MODE")
                [[ -n "${TENSOR_SPLIT:-}" ]] && out+=(--tensor-split "$TENSOR_SPLIT")
                [[ -n "${MAIN_GPU:-}" ]] && out+=(--main-gpu "$MAIN_GPU")
            fi
        fi
    fi
    [[ -n "${FIT:-}" ]] && out+=(--fit "$FIT")

    [[ -n "${TEMP:-}" ]] && out+=(--temp "$TEMP")
    [[ -n "${TOP_P:-}" ]] && out+=(--top-p "$TOP_P")

    local -a extra=()
    collect_extra_args extra
    if (( ${#extra[@]} > 0 )); then
        out+=("${extra[@]}")
    fi
    return 0
}

# build_llama_args <out-array-name> <model-path>
build_llama_args() {
    local out_var="$1"
    local model="$2"
    local -n out="$out_var"

    local -a runtime=()
    build_runtime_args runtime
    out=(-m "$model" "${runtime[@]}")
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
    resolved="$(resolve_model_or_alias "$query")" || return 1
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
    apply_cli_overrides
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

# Remove a key from a config-style file.
config_unset_file() {
    local file="${1:-}"
    local key="${2:-}"
    [[ -n "$file" ]] || die "config_unset_file: missing file"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Invalid config key: $key"
    [[ -f "$file" ]] || return 0

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")" || die "Unable to create temporary file"
    grep -v "^${key}=" "$file" >"$tmp" || true
    mv "$tmp" "$file"
}

# Remove a key from the local (global) config file.
config_unset() {
    config_unset_file "$LLM_CONFIG" "${1:-}"
}

config_is_set() {
    [[ -f "$LLM_CONFIG" ]] && grep -q "^${1}=" "$LLM_CONFIG"
}
