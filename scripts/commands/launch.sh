#!/usr/bin/env bash
# `llm launch` — start llama-cli.

cmd_launch() {
    local target=""
    local dry_run=0
    local -a passthrough=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) help_launch; return 0 ;;
            --dry-run) dry_run=1 ;;
            -c|--ctx|--context)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                CONTEXT_SIZE="$2"; shift ;;
            --ngl|--gpu-layers)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                NGL="$2"; shift ;;
            --device)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                DEVICE="$2"; shift ;;
            --split-mode)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                SPLIT_MODE="$2"; shift ;;
            --tensor-split)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                TENSOR_SPLIT="$2"; shift ;;
            --main-gpu)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                MAIN_GPU="$2"; shift ;;
            --temp)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                TEMP="$2"; shift ;;
            --no-memory) MEMORY_ENABLED="false" ;;
            --) shift; passthrough=("$@"); break ;;
            -*) err "Unknown launch option: $1"; return 2 ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                else
                    passthrough+=("$1")
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$target" ]]; then
        target="default"
    fi

    if [[ "$target" == "select" ]]; then
        require_fzf
        target="$(pick_model)" || return 1
        [[ -n "$target" ]] || return 0
    elif [[ "$target" == "default" ]]; then
        target="${DEFAULT_MODEL:-}"
        if [[ -z "$target" ]]; then
            err "No default model configured."
            echo "Choose one with: llm config default" >&2
            echo "Or launch one now with: llm launch select" >&2
            return 1
        fi
    fi

    local resolved=""
    local -a args=()
    prepare_launch args resolved "$target" || {
        err "Unable to launch model: $target"
        return 1
    }

    if (( dry_run )); then
        print_argv "$LLAMA_BIN" "${args[@]}" "${passthrough[@]}"
        return 0
    fi

    exec "$LLAMA_BIN" "${args[@]}" "${passthrough[@]}"
}

help_launch() {
    cat <<EOF
${BOLD}llm launch${NC} [default|select|<model>] [options] [-- <llama-cli flags>]

Launch llama.cpp with the configured context size, GPU layers, device,
split settings, and long-term memory settings.

  llm launch                     Launch the default model
  llm launch default             Launch the default model
  llm launch select              Pick a model with fzf
  llm launch <model>             Launch a model by full or partial name
  llm launch <model> -- -t 8     Pass flags through to llama-cli

${BOLD}Options${NC}
  --dry-run                      Print the command instead of running it
  -c, --ctx N                    Override context size
      --ngl N                    Override GPU layers
      --device LIST              Override devices, e.g. CUDA0,CUDA1
      --split-mode MODE          none | layer | row | tensor
      --tensor-split LIST        e.g. 3,1
      --main-gpu N               Main GPU index
      --temp N                   Override temperature
      --no-memory                Disable long-term memory for this launch

${DIM}Configure defaults with: llm config edit${NC}
EOF
}
