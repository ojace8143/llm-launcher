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

help_models() {
    cat <<EOF
${BOLD}llm models${NC} <subcommand>

  llm models list                  List local .gguf models
  llm models default               Choose the default model
  llm models download <url>        Download a .gguf file

${DIM}Models directory: ${MODEL_DIR:-unset}${NC}
EOF
}
