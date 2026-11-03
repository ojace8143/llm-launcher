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
    local m
    for m in "${models[@]}"; do
        if [[ "$m" == "${DEFAULT_MODEL:-}" ]]; then
            printf '  %s* %s%s\n' "$GREEN" "$m" "$NC"
        else
            printf '    %s\n' "$m"
        fi
    done
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
    resolved="$(resolve_model "$name")" || { err "Model not found: $name"; return 1; }
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
  llm models info <name>           Show size, path, and profile
  llm models add <path> [--link]   Add a .gguf (copy, or symlink with --link)
  llm models remove <name>         Delete a model
  llm models download <url>        Download a .gguf file
  llm models alias <alias> <model> Set a readable API/OpenCode model alias
  llm models alias --remove <alias> Remove an alias
  llm models aliases               List configured aliases

${DIM}Models directory: ${MODEL_DIR:-unset}${NC}
${DIM}Aliases are used by llama-server and 'llm opencode config'.${NC}
EOF
}
