#!/usr/bin/env bash
# `llm completion` — shell completion.

cmd_completion() {
    case "${1:-}" in
        bash) completion_bash ;;
        zsh) completion_zsh ;;
        -h|--help|"") help_completion ;;
        *) err "Unsupported shell: $1 (use bash or zsh)"; return 2 ;;
    esac
}

completion_bash() {
    cat <<'EOF'
_llm_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="help launch config health version models devices serve agent setup completion bench"
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
    fi
    case "${COMP_WORDS[1]}" in
        config)
            COMPREPLY=( $(compgen -W "show edit get set unset reset path open check default device split tensor-split main-gpu cuda context ngl threads flash parallel temp top-p extra-args memory host port api-key tools workspace mcp" -- "$cur") )
            ;;
        serve)
            COMPREPLY=( $(compgen -W "status stop logs restart --background --open --no-open --agent --tools --mcp --sandbox --model --host --port --api-key --workspace --no-ui --dry-run --device --split-mode --tensor-split --parallel --ctx --ngl" -- "$cur") )
            ;;
        agent)
            COMPREPLY=( $(compgen -W "--workspace --shell --full --tools --mcp --sandbox --model --port --host --api-key --no-open --background --dry-run" -- "$cur") )
            ;;
        models)
            COMPREPLY=( $(compgen -W "list default info add remove download" -- "$cur") )
            ;;
        devices)
            COMPREPLY=( $(compgen -W "--json" -- "$cur") )
            ;;
        bench)
            COMPREPLY=( $(compgen -W "--model --devices --contexts --ngl --threads --reps --warmup --delay --baseline --cooldown --quick --compare --json --csv --save --dry-run --parallel" -- "$cur") )
            ;;
    esac
}
complete -F _llm_complete llm
EOF
}

completion_zsh() {
    cat <<'EOF'
#compdef llm
_llm() {
    local -a commands
    commands=(
        'help:Show help'
        'launch:Launch a model'
        'config:View or change configuration'
        'health:Check the installation'
        'version:Show version and paths'
        'models:Manage models'
        'devices:List devices'
        'serve:Run llama-server'
        'agent:Run the Web UI agent'
        'setup:Run setup.sh'
        'completion:Generate shell completion'
        'bench:Benchmark across backends and devices'
    )
    if (( CURRENT == 2 )); then
        _describe 'command' commands
        return
    fi
    case "${words[2]}" in
        config) _values 'config' show edit get set unset reset path open check default device split tensor-split main-gpu cuda context ngl threads flash parallel temp top-p extra-args memory host port api-key tools workspace mcp ;;
        models) _values 'models' list default info add remove download ;;
        serve) _values 'serve' status stop logs restart --background --open --agent --tools --model --host --port --workspace --mcp --sandbox --no-ui --dry-run ;;
        agent) _values 'agent' --workspace --shell --full --tools --mcp --sandbox --model --port --host --no-open --background --dry-run ;;
        bench) _values 'bench' --model --devices --contexts --ngl --threads --reps --warmup --delay --baseline --cooldown --quick --compare --json --csv --save --dry-run --parallel ;;
    esac
}
_llm "$@"
EOF
}

help_completion() {
    cat <<EOF
${BOLD}llm completion${NC} <bash|zsh>

Print a completion script.

  # bash
  llm completion bash > ~/.local/share/bash-completion/completions/llm

  # zsh
  llm completion zsh > "\${fpath[1]}/_llm"
EOF
}
