#!/usr/bin/env bash
# `llm devices` — list llama.cpp devices.

cmd_devices() {
    local json=0
    case "${1:-}" in
        -h|--help) help_devices; return 0 ;;
        --json) json=1 ;;
        "") ;;
        *) err "Unknown devices option: $1"; return 2 ;;
    esac

    local -a rows=()
    mapfile -t rows < <(llama_devices)

    if (( json )); then
        printf '['
        local first=1 id desc free total
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r id desc free total <<<"$row"
            (( first )) || printf ','
            first=0
            desc="${desc//\\/\\\\}"
            desc="${desc//\"/\\\"}"
            printf '{"id":"%s","description":"%s","free_mib":%s,"total_mib":%s}' \
                "$id" "$desc" "${free:-null}" "${total:-null}"
        done
        printf ']\n'
        return 0
    fi

    section "Devices"
    if (( ${#rows[@]} == 0 )); then
        warn "No devices reported. The current build is CPU-only, or llama.cpp is not built."
        return 0
    fi

    printf '  %-12s %-42s %10s %10s\n' "ID" "Description" "Free MiB" "Total MiB"
    local id desc free total
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id desc free total <<<"$row"
        printf '  %-12s %-42s %10s %10s\n' "$id" "${desc:0:42}" "${free:--}" "${total:--}"
    done

    if [[ -n "${DEVICE:-}" ]]; then
        printf '\n  %sConfigured:%s %s\n' "$DIM" "$NC" "$DEVICE"
    else
        printf '\n  %sConfigured:%s CPU / auto\n' "$DIM" "$NC"
    fi
}

help_devices() {
    cat <<EOF
${BOLD}llm devices${NC} [--json]

List the devices reported by llama.cpp, including free/total memory.

  llm devices             Human-readable table
  llm devices --json      JSON for scripting

${DIM}Configure with: llm config device${NC}
EOF
}
