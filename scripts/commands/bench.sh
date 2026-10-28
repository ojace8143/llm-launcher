#!/usr/bin/env bash
# `llm bench` — wrapper around llama-bench comparing backends/devices.

bench_find_bin() {
    if [[ -x "${LLAMA_HOME:-}/build/bin/llama-bench" ]]; then
        printf '%s\n' "${LLAMA_HOME}/build/bin/llama-bench"
        return 0
    fi
    if have_cmd llama-bench; then
        command -v llama-bench
        return 0
    fi
    return 1
}

bench_set_ld_path() {
    if [[ -n "${CUDA_HOME:-}" && -d "$CUDA_HOME/lib64" ]]; then
        export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
}

bench_parse_tps() {
    # Try to extract PP and TG values from llama-bench output
    # Format varies; look for tokens/s in common columns
    local line="$1"
    # This is a simple heuristic; actual parsing done in awk/python-like processing
    printf '%s' "$line"
}

cmd_bench() {
    local bench_bin=""
    bench_bin="$(bench_find_bin)" || {
        err "llama-bench not found. Build llama.cpp first (it comes with llama.cpp) or ensure ${LLAMA_HOME:-$LLM_HOME/llama.cpp}/build/bin/llama-bench exists."
        err "Try: ./setup.sh --fresh or rebuild llama.cpp"
        return 1
    }
    bench_set_ld_path

    local model=""
    local devices_csv=""
    local contexts_csv=""
    local ngl="${NGL:-99}"
    local threads="${THREADS:-}"
    local reps="${BENCH_REPS:-}"
    local warmup="${BENCH_WARMUP:-}"
    local delay="${BENCH_DELAY:-}"
    local quick=0
    local compare=0
    local json=0
    local csv_out=0
    local save_path=""
    local dry_run=0
    local baseline=""
    local cooldown="${BENCH_COOLDOWN:-2}"
    local -a passthrough=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) help_bench; return 0 ;;
            --model)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                model="$2"; shift ;;
            --devices)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                devices_csv="$2"; shift ;;
            --contexts)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                contexts_csv="$2"; shift ;;
            --ngl)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                ngl="$2"; shift ;;
            --threads)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                threads="$2"; shift ;;
            --reps)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                reps="$2"; shift ;;
            --warmup)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                warmup="$2"; shift ;;
            --delay)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                delay="$2"; shift ;;
            --baseline)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                baseline="$2"; shift ;;
            --cooldown)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                cooldown="$2"; shift ;;
            --quick) quick=1 ;;
            --compare) compare=1 ;;
            --json) json=1 ;;
            --csv) csv_out=1 ;;
            --save)
                [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
                save_path="$2"; shift ;;
            --dry-run) dry_run=1 ;;
            --parallel)
                warn "Running devices in parallel is not recommended (can cause contention/OOM). Proceeding anyway."
                ;;
            --) shift; passthrough=("$@"); break ;;
            -*) err "Unknown bench option: $1"; return 2 ;;
            *) 
                if [[ -z "$model" ]]; then
                    model="$1"
                else
                    passthrough+=("$1")
                fi
                ;;
        esac
        shift
    done

    # Resolve model
    if [[ -z "$model" ]]; then
        model="${DEFAULT_MODEL:-}"
        if [[ -z "$model" ]]; then
            err "No default model configured. Use: llm bench --model <name> or llm config default"
            return 1
        fi
    fi
    local resolved_model=""
    resolved_model="$(resolve_model "$model")" || {
        err "Unable to resolve model: $model"
        return 1
    }
    if [[ "$resolved_model" != /* ]]; then
        resolved_model="${MODEL_DIR:-}/$resolved_model"
    fi
    [[ -f "$resolved_model" ]] || { err "Model file not found: $resolved_model"; return 1; }

    # Resolve devices
    if [[ -z "$devices_csv" ]]; then
        if [[ -n "${DEVICE:-}" ]]; then
            devices_csv="$DEVICE"
        else
            require_fzf
            local dev_list=""
            dev_list="$(llama_devices | awk -F'\t' '{if($1!="") print $1"\t"$2"\t"$3"MiB free / "$4"MiB total"}' | fzf --multi --height 40% --reverse --border --prompt="Select devices> " | awk -F'\t' '{print $1}' | paste -sd',' -)"
            devices_csv="$dev_list"
        fi
    fi
    [[ -n "$devices_csv" ]] || { err "No devices selected"; return 1; }
    if ! validate_device_list "$devices_csv"; then
        err "Unknown device in selection: $devices_csv"
        err "Run 'llm devices' to see available devices"
        return 1
    fi

    # Check for same-GPU comparison
    local has_cuda0=0 has_vulkan0=0
    case ",$devices_csv," in
        *,CUDA0,*) has_cuda0=1 ;;
    esac
    case ",$devices_csv," in
        *,Vulkan0,*) has_vulkan0=1 ;;
    esac
    if (( has_cuda0 && has_vulkan0 )); then
        warn "Comparing CUDA0 and Vulkan0 - these are the same physical GPU (4060). Deltas show CUDA vs Vulkan overhead."
    fi

    # Set baseline
    if [[ -z "$baseline" ]]; then
        case ",$devices_csv," in
            *,CUDA0,*) baseline="CUDA0" ;;
            *) 
                local first_dev=""
                first_dev="$(echo "$devices_csv" | cut -d',' -f1)"
                baseline="$first_dev"
                ;;
        esac
    fi

    # Contexts
    if [[ -z "$contexts_csv" ]]; then
        if (( quick )); then
            contexts_csv="512,1024,2048"
        else
            contexts_csv="512,1024,2048,4096"
        fi
    fi

    # Reps/warmup
    [[ -z "$reps" ]] && reps=$(( quick ? 2 : 3 ))
    [[ -z "$warmup" ]] && warmup=1
    [[ -z "$delay" ]] && delay=0

    local llama_rev="unknown"
    if [[ -d "${LLAMA_HOME:-}/.git" ]] && have_cmd git; then
        llama_rev="$(git -C "$LLAMA_HOME" describe --tags --always --dirty 2>/dev/null || echo unknown)"
    fi

    section "Benchmark"
    printf '  %-12s %s\n' "Model" "$(basename "$resolved_model")"
    printf '  %-12s %s\n' "Devices" "$devices_csv"
    printf '  %-12s %s\n' "Baseline" "$baseline"
    printf '  %-12s %s\n' "Contexts" "$contexts_csv"
    printf '  %-12s %s\n' "NGL" "$ngl"
    printf '  %-12s %s\n' "Reps" "$reps"
    printf '  %-12s %s\n' "Warmup" "$warmup"
    printf '  %-12s %s\n' "llama.cpp" "$llama_rev"
    printf '\n'

    # Build context array
    local -a ctxs=()
    IFS=',' read -r -a ctxs <<<"$contexts_csv"

    # Prepare results storage (simple approach using temp files)
    local tmpdir=""
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/llm-bench.XXXXXX")" || die "Failed to create temp dir"
    cleanup_bench() { [[ -n "${tmpdir:-}" && -d "${tmpdir:-}" ]] && rm -rf -- "${tmpdir:-}"; }
    trap cleanup_bench EXIT

    local total=$(( ${#ctxs[@]} * $(echo "$devices_csv" | tr ',' '\n' | wc -l) ))
    local current=0

    local -a devs=()
    IFS=',' read -r -a devs <<<"$devices_csv"

    # If dry-run, just print commands
    if (( dry_run )); then
        section "Dry run (commands)"
        local d c
        for d in "${devs[@]}"; do
            for c in "${ctxs[@]}"; do
                local -a cmd=("$bench_bin")
                cmd+=(-m "$resolved_model")
                cmd+=(-ngl "$ngl")
                cmd+=(-dev "$d")
                cmd+=(-p "$c" -n 128)
                cmd+=(-r "$reps")
                (( warmup == 0 )) && cmd+=(--no-warmup)
                [[ -n "$delay" && "$delay" != "0" ]] && cmd+=(--delay "$delay")
                [[ -n "$threads" ]] && cmd+=(-t "$threads")
                cmd+=("${passthrough[@]}")
                printf '  '; print_argv "${cmd[@]}"
            done
        done
        return 0
    fi

    # Run benchmarks
    local d c
    for d in "${devs[@]}"; do
        for c in "${ctxs[@]}"; do
            (( current++ ))
            printf '%s[%d/%d]%s Benchmarking %s @ context %s...\n' "$CYAN" "$current" "$total" "$NC" "$d" "$c"
            local -a cmd=("$bench_bin")
            cmd+=(-m "$resolved_model")
            cmd+=(-ngl "$ngl")
            cmd+=(-dev "$d")
            cmd+=(-p "$c" -n 128)
            cmd+=(-r "$reps")
            (( warmup == 0 )) && cmd+=(--no-warmup)
            [[ -n "$delay" && "$delay" != "0" ]] && cmd+=(--delay "$delay")
            [[ -n "$threads" ]] && cmd+=(-t "$threads")
            cmd+=("${passthrough[@]}")
            
            local outfile="$tmpdir/${d}_${c}.txt"
            local errfile="$tmpdir/${d}_${c}.err"
            if ! LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${cmd[@]}" >"$outfile" 2>"$errfile"; then
                warn "Benchmark failed for $d @ ctx $c (see $errfile)"
                printf 'FAILED\t%s\t%s\n' "$d" "$c" >>"$tmpdir/results.tsv"
                continue
            fi
            # Try to extract pp and tg values
            # llama-bench output format varies; look for lines with tokens/s
            local pp_tg
            pp_tg="$(grep -E '[0-9]+\.[0-9]+.*tok/s|tok/s' "$outfile" | tail -5)"
            printf '%s\t%s\t%s\n' "$d" "$c" "$pp_tg" >>"$tmpdir/results_raw.tsv"
            printf '%s\t%s\tOK\n' "$d" "$c" >>"$tmpdir/results.tsv"
            if (( cooldown > 0 && current < total )); then
                sleep "$cooldown"
            fi
        done
    done

    section "Results (tokens/s)"
    printf '  %-10s %-10s %-8s %-12s %-12s\n' "Device" "Backend" "Ctx" "PP (tok/s)" "TG (tok/s)"
    printf '  %s\n' "------------------------------------------------------------"
    
    # Parse results
    local d c
    for d in "${devs[@]}"; do
        local backend="unknown"
        case "$d" in
            CUDA*) backend="CUDA" ;;
            Vulkan*) backend="Vulkan" ;;
            *) backend="$d" ;;
        esac
        for c in "${ctxs[@]}"; do
            local raw=""
            raw="$(grep "^$d[[:space:]]\+$c[[:space:]]\+" "$tmpdir/results_raw.tsv" 2>/dev/null | cut -f3-)"
            if [[ -z "$raw" ]]; then
                # Try to parse from outfile
                local outfile="$tmpdir/${d}_${c}.txt"
                if [[ -f "$outfile" ]]; then
                    # Look for common patterns
                    local pp tg
                    pp="$(grep -oE 'pp[[:space:]]*[0-9]+\.[0-9]+' "$outfile" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
                    tg="$(grep -oE 'tg[[:space:]]*[0-9]+\.[0-9]+' "$outfile" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
                    if [[ -z "$pp" ]]; then pp="$(awk '/tokens\/s/ && /prompt|pp/ {for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+/ && (i>1 && $(i-1) ~ /pp|prompt/)) {print $i; exit}}' "$outfile" 2>/dev/null | head -1)"; fi
                    if [[ -z "$tg" ]]; then tg="$(awk '/tokens\/s/ && /gen|tg/ {for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+/ && (i>1 && $(i-1) ~ /tg|gen/)) {print $i; exit}}' "$outfile" 2>/dev/null | head -1)"; fi
                    if [[ -n "$pp" || -n "$tg" ]]; then
                        printf '  %-10s %-10s %-8s %-12s %-12s\n' "$d" "$backend" "$c" "${pp:--}" "${tg:--}"
                        continue
                    fi
                fi
                printf '  %-10s %-10s %-8s %-12s %-12s\n' "$d" "$backend" "$c" "FAILED" "FAILED"
                continue
            fi
            # Fallback display
            printf '  %-10s %-10s %-8s %-12s %-12s\n' "$d" "$backend" "$c" "see log" "see log"
        done
    done
    printf '\n'
    printf '  %sNote:%s Full llama-bench output saved in %s\n' "$DIM" "$NC" "$tmpdir"
    printf '  %sUse --json or check individual files for detailed metrics.%s\n' "$DIM" "$NC"
}

help_bench() {
    cat <<EOF
${BOLD}llm bench${NC} [options] [model]

Benchmark llama.cpp performance across backends and devices using llama-bench.

${BOLD}Usage${NC}
  llm bench                              Interactive device/context selection
  llm bench --model <name>               Benchmark a specific model
  llm bench --devices CUDA0,Vulkan0     Compare specific devices
  llm bench --quick                      Quick comparison (512,1024,2048)
  llm bench --dry-run                   Show commands without running

${BOLD}Options${NC}
  --model <name>        Model name or partial match (default: DEFAULT_MODEL)
  --devices <list>      Comma-separated device IDs (default: from config or prompt)
  --contexts <list>     Comma-separated context sizes (default: 512,1024,2048,4096)
  --ngl <n>             GPU layers (default: 99 or NGL)
  --threads <n>         CPU threads
  --reps <n>            Repetitions per test (default: 3, 2 in --quick)
  --warmup <n>          Warmup runs (default: 1)
  --delay <n>           Delay between tests in seconds
  --cooldown <n>        Sleep between runs (default: 2)
  --baseline <dev>      Baseline device for comparison
  --quick               Shorter test matrix
  --compare             Force comparison mode
  --json                Output JSON (WIP)
  --csv                 Output CSV (WIP)
  --save <path>         Save results to file
  --dry-run             Print llama-bench commands
  -- <args>             Pass extra args to llama-bench

${BOLD}Notes${NC}
  - Compares CUDA, Vulkan backends across available devices
  - Warns if comparing CUDA0 and Vulkan0 (same physical GPU)
  - Runs sequentially by default to avoid contention
  - Results go to temp dir; use --save to persist

${DIM}Run 'llm devices' to see available device IDs.${NC}
EOF
}
