#!/usr/bin/env bash
# `llm models` — list and fetch models.

cmd_models() {
    local sub="${1:-list}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        -h|--help|help) help_models ;;
        list|"") models_list ;;
        default) config_default ;;
        download) models_download "$@" ;;
        add) models_add "$@" ;;
        remove|rm) models_remove "$@" ;;
        info) models_info "$@" ;;
        config|profile) models_config "$@" ;;
        alias) models_alias "$@" ;;
        aliases) models_aliases ;;
        *)
            err "Unknown models option: $sub"
            help_models
            return 2
            ;;
    esac
}

models_list() {
    local -a models=()
    mapfile -t models < <(list_models)

    section "Models"
    printf '  %-18s %s\n' "Directory" "${MODEL_DIR:-unset}"
    if (( ${#models[@]} == 0 )); then
        warn "No .gguf models found."
        return 0
    fi
    printf '  %-18s %s\n' "Default" "${DEFAULT_MODEL:-(none)}"
    echo
    local m marker
    for m in "${models[@]}"; do
        marker=""
        [[ -f "$(profile_path "$m")" ]] && marker=" ${DIM}[profile]${NC}"
        if [[ "$m" == "${DEFAULT_MODEL:-}" ]]; then
            printf '  %s* %s%s%s\n' "$GREEN" "$m" "$NC" "$marker"
        else
            printf '    %s%s\n' "$m" "$marker"
        fi
    done
    printf '\n  %sConfigure per model with: llm models config <model>%s\n' "$DIM" "$NC"
}

models_download() {
    local url="${1:-}"
    if [[ -z "$url" ]]; then
        err "Usage: llm models download <url>"
        return 2
    fi

    local filename="${url##*/}"
    filename="${filename%%\?*}"
    [[ "$filename" == *.gguf ]] || {
        err "URL does not look like a .gguf file: $filename"
        return 2
    }

    mkdir -p "$MODEL_DIR" || die "Unable to create $MODEL_DIR"
    info "Downloading $filename"
    curl -fL --retry 3 --progress-bar -o "$MODEL_DIR/$filename" "$url" ||
        die "Download failed"
    info "Saved to $MODEL_DIR/$filename"
}

models_add() {
    local link=0 path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --link|-l) link=1 ;;
            -h|--help) help_models; return 0 ;;
            *) path="$1" ;;
        esac
        shift
    done

    [[ -n "$path" ]] || { err "Usage: llm models add <path> [--link]"; return 2; }
    [[ -f "$path" ]] || { err "File not found: $path"; return 1; }
    [[ "$path" == *.gguf ]] || { err "Not a .gguf file: $path"; return 2; }

    mkdir -p "$MODEL_DIR" || die "Unable to create $MODEL_DIR"
    local name="${path##*/}"
    local dest="$MODEL_DIR/$name"
    [[ ! -e "$dest" ]] || { err "Already exists: $dest"; return 1; }

    if (( link )); then
        ln -s "$(cd "$(dirname "$path")" && pwd)/$name" "$dest"
        info "Linked: $dest"
    else
        info "Copying $name..."
        cp "$path" "$dest" || die "Copy failed"
        info "Added: $dest"
    fi
}

models_remove() {
    local name="${1:-}"
    [[ -n "$name" ]] || { err "Usage: llm models remove <name>"; return 2; }
    local resolved
    resolved="$(resolve_model "$name")" || { err "Model not found: $name"; return 1; }
    [[ -n "$resolved" ]] || return 1
    [[ "$resolved" != /* ]] && resolved="$MODEL_DIR/$resolved"

    rm -f "$resolved" || die "Unable to remove $resolved"
    info "Removed: $resolved"

    local -a pairs=()
    local -a removed_aliases=()
    local alias target target_path pair joined=""
    while IFS=$'\t' read -r alias target; do
        target_path="$(alias_model_path "$target")"
        if [[ "$target_path" == "$resolved" ||
            "$target" == "${resolved##*/}" ]]; then
            removed_aliases+=("$alias")
        else
            pairs+=("$alias=$target")
        fi
    done < <(model_alias_entries)

    if (( ${#removed_aliases[@]} > 0 )); then
        for pair in "${pairs[@]}"; do
            [[ -n "$joined" ]] && joined="$joined,$pair" || joined="$pair"
        done
        config_set MODEL_ALIASES "$joined"
        info "Removed alias(es): ${removed_aliases[*]}"
    fi

    if [[ "$(basename "$resolved")" == "${DEFAULT_MODEL:-}" ]]; then
        config_set DEFAULT_MODEL ""
        info "Default model cleared"
    fi
}

models_info() {
    local name="${1:-}"
    [[ -n "$name" ]] || { err "Usage: llm models info <name>"; return 2; }
    local resolved
    resolved="$(resolve_model_or_alias "$name")" || { err "Model not found: $name"; return 1; }
    [[ -n "$resolved" ]] || return 1
    [[ "$resolved" != /* ]] && resolved="$MODEL_DIR/$resolved"
    [[ -f "$resolved" ]] || { err "Model not found: $resolved"; return 1; }

    local size
    size="$(du -h "$resolved" | cut -f1)"
    section "Model"
    printf '  %-18s %s\n' "Name" "${resolved##*/}"
    printf '  %-18s %s\n' "Path" "$resolved"
    printf '  %-18s %s\n' "Size" "$size"
    printf '  %-18s %s\n' "Default" "$([[ "${resolved##*/}" == "${DEFAULT_MODEL:-}" ]] && echo yes || echo no)"
    printf '  %-18s %s\n' "API alias" "$(alias_for_model "$resolved")"
    local profile
    profile="$(profile_path "$resolved")"
    printf '  %-18s %s\n' "Profile" "$([[ -f "$profile" ]] && echo "$profile" || echo "(none)")"

    (
        load_profile "$resolved"
        local devices="${DEVICE:-(CPU / auto)}"
        [[ "$devices" == "none" || "$devices" == "cpu" ]] && devices="CPU only"
        local split="${SPLIT_MODE:-layer}"
        local tensor="${TENSOR_SPLIT:-(auto / even)}"
        if [[ -n "${DEVICE:-}" && "$DEVICE" != *,* ]]; then
            split="(single device)"
            tensor="(ignored)"
        fi
        printf '  %-18s %s\n' "Context" "${CONTEXT_SIZE:-(unset)}"
        printf '  %-18s %s\n' "GPU layers" "${NGL:-auto}"
        printf '  %-18s %s\n' "Devices" "$devices"
        printf '  %-18s %s\n' "Split mode" "$split"
        printf '  %-18s %s\n' "Tensor split" "$tensor"
    )
}

models_config() {
    local query="${1:-}"
    case "$query" in
        -h|--help|help) help_models; return 0 ;;
    esac
    if [[ -z "$query" ]]; then
        query="$(pick_model)" || return 1
        [[ -n "$query" ]] || return 0
    else
        case "$query" in
            set|unset|get|show|edit|remove)
                err "Specify a model: llm models config <model> $query ..."
                return 2
                ;;
        esac
        shift
    fi

    local resolved
    resolved="$(resolve_model_or_alias "$query")" || {
        err "Model not found: $query"
        return 1
    }
    [[ -n "$resolved" ]] || return 1
    resolved="$(absolute_model_path "$resolved")" || {
        err "Unable to resolve model path: $resolved"
        return 1
    }
    [[ -f "$resolved" ]] || {
        err "Model not found: $resolved"
        return 1
    }

    local action="${1:-interactive}"
    [[ $# -gt 0 ]] && shift

    case "$action" in
        interactive|"") models_config_menu "$resolved" ;;
        show) models_config_show "$resolved" ;;
        set) models_config_set "$resolved" "$@" ;;
        unset) models_config_unset "$resolved" "$@" ;;
        get) models_config_get "$resolved" "$@" ;;
        edit) models_config_edit "$resolved" ;;
        remove) models_config_remove "$resolved" ;;
        -h|--help) help_models ;;
        *)
            err "Unknown models config action: $action"
            err "Use: show, set, unset, get, edit, remove"
            return 2
            ;;
    esac
}

_require_profile_key() {
    local key="$1"
    [[ " $PROFILE_KEYS " == *" $key "* ]] || {
        err "Unknown per-model key: $key"
        err "Keys: $PROFILE_KEYS"
        return 2
    }
}

models_config_get() {
    local resolved="$1" key="${2:-}"
    [[ -n "$key" ]] || { err "Usage: llm models config <model> get <KEY>"; return 2; }
    _require_profile_key "$key" || return $?

    (
        load_profile "$resolved"
        printf '%s\n' "${!key-}"
    )
}

models_config_set() {
    local resolved="$1" key="${2:-}"
    [[ -n "$key" ]] || {
        err "Usage: llm models config <model> set <KEY> <VALUE>"
        return 2
    }
    shift 2 || true
    local value="$*"

    _require_profile_key "$key" || return $?

    # Load the effective settings so validation sees this model's device.
    load_profile "$resolved"
    _validate_set "$key" "$value" || return $?

    if [[ "$key" == "DEVICE" ]] && device_is_cpu "$value"; then
        value="none"
    fi

    profile_set "$resolved" "$key" "$value" || return $?

    # A single device makes split settings meaningless. Keep the profile clean.
    if [[ "$key" == "DEVICE" ]]; then
        if [[ "$value" == "none" || "$value" != *,* ]]; then
            profile_unset "$resolved" TENSOR_SPLIT
            profile_unset "$resolved" SPLIT_MODE
            profile_unset "$resolved" MAIN_GPU
        fi
    fi

    info "$key set for ${resolved##*/}: ${value:-(empty)}"
}

models_config_unset() {
    local resolved="$1" key="${2:-}"
    [[ -n "$key" ]] || { err "Usage: llm models config <model> unset <KEY>"; return 2; }
    _require_profile_key "$key" || return $?
    profile_unset "$resolved" "$key"
    info "$key removed from ${resolved##*/} (global value will be used)"
}

models_config_edit() {
    local resolved="$1"
    local file
    file="$(profile_init "$resolved")" || return 1
    local editor="${VISUAL:-${EDITOR:-vi}}"
    "$editor" "$file"
}

models_config_remove() {
    local resolved="$1"
    local file
    file="$(profile_path "$resolved")"
    if [[ ! -f "$file" ]]; then
        info "No profile for ${resolved##*/}"
        return 0
    fi
    profile_remove "$resolved"
    info "Removed profile: $file"
}

models_config_show() {
    local resolved="$1"
    local file
    file="$(profile_path "$resolved")"

    section "Model config"
    printf '  %-18s %s\n' "Model" "${resolved##*/}"
    printf '  %-18s %s\n' "Profile" "$([[ -f "$file" ]] && echo "$file" || echo "(none)")"
    echo

    (
        load_profile "$resolved"
        printf '  %-16s %-32s %s\n' "Key" "Value" "Source"
        local key value source display
        for key in $PROFILE_KEYS; do
            value="${!key-}"
            source="global"
            if profile_has_key "$file" "$key"; then
                source="model"
            fi
            if [[ -z "$value" && "$source" != "model" ]]; then
                continue
            fi
            display="${value:-(empty)}"
            if [[ "$key" == "EXTRA_ARGS" ]]; then
                display="$(extra_args_string)"
                [[ -n "$display" ]] || display="(empty)"
            fi
            printf '  %-16s %-32s %s\n' "$key" "$display" "$source"
        done

        if [[ -n "${DEVICE:-}" && "$DEVICE" != *,* ]] && ! device_is_cpu "$DEVICE"; then
            printf '\n  %sSingle device; SPLIT_MODE and TENSOR_SPLIT are ignored.%s\n' "$DIM" "$NC"
        fi
    )
}

models_config_menu() {
    require_fzf
    local resolved="$1"
    local file choice value
    file="$(profile_path "$resolved")"

    # Capture global values once so each menu pass starts from a clean state.
    local -A baseline=()
    local key
    for key in $PROFILE_KEYS; do
        baseline["$key"]="${!key-}"
    done

    section "Per-model config"
    printf '  %-18s %s\n' "Model" "${resolved##*/}"
    printf '  %-18s %s\n' "Profile" "$([[ -f "$file" ]] && echo "$file" || echo "(none yet)")"

    while true; do
        for key in $PROFILE_KEYS; do
            printf -v "$key" '%s' "${baseline[$key]}"
        done
        load_profile "$resolved"

        choice="$(
            printf '%s\n' \
                "Context size" \
                "GPU layers" \
                "Devices" \
                "Split mode" \
                "Tensor split" \
                "Flash attention" \
                "Temperature" \
                "Top-p" \
                "Extra llama args" \
                "Show effective settings" \
                "Open profile in editor" \
                "Remove profile" \
                "Done" |
                fzf --height 60% --reverse --border --prompt="Model config> " || true
        )"

        case "$choice" in
            "Context size")
                value="$(prompt_value "Context size" "${CONTEXT_SIZE:-16384}")"
                [[ -n "$value" ]] || continue
                _validate_set CONTEXT_SIZE "$value" || continue
                profile_set "$resolved" CONTEXT_SIZE "$value"
                info "Context size set to: $value"
                ;;
            "GPU layers")
                value="$(prompt_value "GPU layers" "${NGL:-99}")"
                [[ -n "$value" ]] || continue
                _validate_set NGL "$value" || continue
                profile_set "$resolved" NGL "$value"
                info "GPU layers set to: $value"
                ;;
            "Devices")
                if ! value="$(select_devices)"; then
                    continue
                fi
                local -a ids=() parts=()
                if [[ "$value" == "none" ]]; then
                    profile_set "$resolved" DEVICE none
                    profile_unset "$resolved" TENSOR_SPLIT
                    profile_unset "$resolved" SPLIT_MODE
                    profile_unset "$resolved" MAIN_GPU
                    info "Devices set to: CPU only"
                    continue
                fi
                profile_set "$resolved" DEVICE "$value"
                if [[ "$value" != *,* ]]; then
                    profile_unset "$resolved" TENSOR_SPLIT
                    profile_unset "$resolved" SPLIT_MODE
                    profile_unset "$resolved" MAIN_GPU
                    info "Devices set to: $value"
                    continue
                fi
                info "Devices set to: $value"
                IFS=',' read -r -a ids <<<"$value"
                if [[ -n "${TENSOR_SPLIT:-}" ]]; then
                    IFS=',' read -r -a parts <<<"$TENSOR_SPLIT"
                fi
                if (( ${#parts[@]} != ${#ids[@]} )); then
                    local auto
                    if auto="$(auto_tensor_split "$value")" && [[ -n "$auto" ]]; then
                        profile_set "$resolved" TENSOR_SPLIT "$auto"
                        info "Tensor split set from VRAM: $auto"
                    fi
                fi
                ;;
            "Split mode")
                value="$(printf '%s\n' none layer row tensor |
                    fzf --height 40% --reverse --border --prompt="Split mode> " || true)"
                [[ -n "$value" ]] || continue
                profile_set "$resolved" SPLIT_MODE "$value"
                info "Split mode set to: $value"
                ;;
            "Tensor split")
                value="$(prompt_value "Tensor split (empty = inherit)" "${TENSOR_SPLIT:-}")"
                if [[ -z "$value" ]]; then
                    profile_unset "$resolved" TENSOR_SPLIT
                    info "Tensor split removed (global value will be used)"
                    continue
                fi
                _validate_set TENSOR_SPLIT "$value" || continue
                profile_set "$resolved" TENSOR_SPLIT "$value"
                info "Tensor split set to: $value"
                ;;
            "Flash attention")
                value="$(printf '%s\n' on off auto |
                    fzf --height 40% --reverse --border --prompt="Flash attention> " || true)"
                [[ -n "$value" ]] || continue
                profile_set "$resolved" FLASH_ATTN "$value"
                info "Flash attention set to: $value"
                ;;
            "Temperature")
                value="$(prompt_value "Temperature (empty = inherit)" "${TEMP:-}")"
                if [[ -n "$value" && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    err "Temperature must be a number"
                    continue
                fi
                if [[ -z "$value" ]]; then
                    profile_unset "$resolved" TEMP
                    info "Temperature removed (global value will be used)"
                else
                    profile_set "$resolved" TEMP "$value"
                    info "Temperature set to: $value"
                fi
                ;;
            "Top-p")
                value="$(prompt_value "Top-p (empty = inherit)" "${TOP_P:-}")"
                if [[ -n "$value" && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    err "Top-p must be a number"
                    continue
                fi
                if [[ -z "$value" ]]; then
                    profile_unset "$resolved" TOP_P
                    info "Top-p removed (global value will be used)"
                else
                    profile_set "$resolved" TOP_P "$value"
                    info "Top-p set to: $value"
                fi
                ;;
            "Extra llama args")
                value="$(prompt_value "Extra llama args (empty = inherit)" "$(extra_args_string)")"
                if [[ -z "$value" ]]; then
                    profile_unset "$resolved" EXTRA_ARGS
                    info "Extra args removed (global value will be used)"
                else
                    profile_set "$resolved" EXTRA_ARGS "$value"
                    info "Extra args set to: $value"
                fi
                ;;
            "Show effective settings")
                models_config_show "$resolved"
                ;;
            "Open profile in editor")
                models_config_edit "$resolved"
                ;;
            "Remove profile")
                models_config_remove "$resolved"
                return 0
                ;;
            ""|"Done")
                return 0
                ;;
        esac
    done
}

models_alias() {
    local remove=0 alias="" model=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove|-r) remove=1 ;;
            -h|--help) help_models; return 0 ;;
            *)
                if [[ -z "$alias" ]]; then
                    alias="$1"
                elif [[ -z "$model" ]]; then
                    model="$1"
                else
                    err "Unexpected argument: $1"
                    return 2
                fi
                ;;
        esac
        shift
    done

    [[ -n "$alias" ]] || {
        err "Usage: llm models alias <alias> <model>"
        err "       llm models alias --remove <alias>"
        return 2
    }
    _alias_valid "$alias" || {
        err "Invalid alias '$alias' (use letters, numbers, dot, underscore, or dash)"
        return 2
    }

    local -a pairs=()
    local pair existing_alias existing_model
    while IFS=$'\t' read -r existing_alias existing_model; do
        [[ "$existing_alias" == "$alias" ]] && continue
        pairs+=("$existing_alias=$existing_model")
    done < <(model_alias_entries)

    if (( remove )); then
        [[ -z "$model" ]] || { err "Usage: llm models alias --remove <alias>"; return 2; }
        if ! model_for_alias "$alias" >/dev/null; then
            warn "Alias not configured: $alias"
        fi
    else
        [[ -n "$model" ]] || {
            err "Usage: llm models alias <alias> <model>"
            return 2
        }
        local resolved
        resolved="$(resolve_model "$model")" || {
            err "Model not found: $model"
            return 1
        }
        [[ -n "$resolved" ]] || return 1
        resolved="$(absolute_model_path "$resolved")" || {
            err "Unable to resolve model path: $resolved"
            return 1
        }
        pairs+=("$alias=${resolved##*/}")
    fi

    local joined=""
    for pair in "${pairs[@]}"; do
        [[ -n "$joined" ]] && joined="$joined,$pair" || joined="$pair"
    done
    config_set MODEL_ALIASES "$joined"

    if (( remove )); then
        info "Removed alias: $alias"
    else
        info "Alias set: $alias -> ${pairs[${#pairs[@]}-1]#*=}"
    fi
}

models_aliases() {
    section "Model aliases"
    local count=0
    local alias model path state
    while IFS=$'\t' read -r alias model; do
        (( count == 0 )) && printf '  %-18s %-44s %s\n' "Alias" "Model" "Status"
        path="$(alias_model_path "$model")"
        if [[ -f "$path" ]]; then
            state="${GREEN}ok${NC}"
        else
            state="${RED}missing${NC}"
        fi
        printf '  %-18s %-44s %s\n' "$alias" "$model" "$state"
        count=$((count + 1))
    done < <(model_alias_entries)

    if (( count == 0 )); then
        info "No aliases configured."
        info "Add one with: llm models alias <alias> <model>"
    fi
}

help_models() {
    cat <<EOF
${BOLD}llm models${NC} <subcommand>

  llm models list                  List local .gguf models
  llm models default               Choose the default model
  llm models info <name>           Show size, path, profile, and settings
  llm models add <path> [--link]   Add a .gguf (copy, or symlink with --link)
  llm models remove <name>         Delete a model
  llm models download <url>        Download a .gguf file
  llm models alias <alias> <model> Set a readable API/OpenCode model alias
  llm models alias --remove <alias> Remove an alias
  llm models aliases               List configured aliases

${BOLD}Per-model config${NC}
  llm models config                Pick a model and edit its settings
  llm models config <model>        Interactive settings for one model
  llm models config <model> show   Show effective settings and sources
  llm models config <model> set K V
  llm models config <model> unset K
  llm models config <model> get K
  llm models config <model> edit   Open the profile in \$EDITOR
  llm models config <model> remove Delete the profile

${DIM}Profiles live in config/profiles/<model>.sh and override the global config
for that model in both 'llm launch' and 'llm serve' (including router mode).${NC}

${DIM}Models directory: ${MODEL_DIR:-unset}${NC}
${DIM}Aliases are used by llama-server and 'llm opencode config'.${NC}
EOF
}
