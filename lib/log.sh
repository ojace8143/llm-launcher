#!/usr/bin/env bash
# Clean rendering of llama.cpp log lines for `llm serve`.
# This file is meant to be sourced, not executed.

# Strip leading whitespace.
_log_trim() {
    local s="${1-}"
    printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

# Convert a 0..1 progress value to an integer percent.
_log_pct() {
    local p="${1-0}" whole frac
    p="${p//[[:space:]]/}"
    whole="${p%%.*}"
    frac="${p#*.}"
    [[ "$frac" == "$p" ]] && frac=""
    [[ "$whole" =~ ^[0-9]+$ ]] || whole=0
    frac="${frac}00"
    frac="${frac:0:2}"
    [[ "$frac" =~ ^[0-9]+$ ]] || frac=0
    printf '%d' "$(( 10#$whole * 100 + 10#$frac ))"
}

# Convert milliseconds to seconds with one decimal.
_log_sec() {
    local ms="${1-}"
    if [[ "$ms" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v m="$ms" 'BEGIN { printf "%.1f", m / 1000 }'
    else
        printf '%s' "$ms"
    fi
}

_log_set() {
    LOG_KIND="${1:-info}"
    LOG_TAG="${2:-}"
    LOG_TEXT="${3:-}"
    LOG_KEEP=1
}

# Render one llama.cpp line into LOG_KIND/LOG_TAG/LOG_TEXT/LOG_KEEP.
log_render_line() {
    local line="${1-}"
    local rest="" lvl="" tag="" body="" toks="" prog="" tps="" pct="" ms="" sec=""
    local acc="" counts="" mean="" parts=() p="" s="" c="" nm="" n=""

    LOG_KEEP=1
    LOG_KIND="raw"
    LOG_TAG=""
    LOG_TEXT="$line"

    # Router mode prefixes child lines with "[pid] ".
    if [[ "$line" =~ ^\[([0-9]+)\][[:space:]]+(.*)$ ]]; then
        line="${BASH_REMATCH[2]}"
    fi

    # Not a leveled llama.cpp line: pass through unchanged.
    if [[ ! "$line" =~ ^[0-9]+\.[0-9]{2}\.[0-9]{3}\.[0-9]{3}[[:space:]]+([IWED])[[:space:]]+(.*)$ ]]; then
        LOG_TEXT="$line"
        return 0
    fi

    lvl="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"

    case "$lvl" in
        W) tag="[WARN]"; LOG_KIND="warn" ;;
        E) tag="[ERR]";  LOG_KIND="err" ;;
        D) tag="[DBG]";  LOG_KIND="dbg" ;;
        *) tag="[INFO]"; LOG_KIND="info" ;;
    esac

    # Drop the fixed-width component column (srv, cmn, slot).
    if [[ "$rest" =~ ^(srv|cmn|slot)[[:space:]]+(.*)$ ]]; then
        rest="${BASH_REMATCH[2]}"
    fi

    # Router mode dumps the full child command line one argument per line.
    if (( LOG_IN_ARGS )); then
        if [[ "$rest" == load:* && "${rest#load:}" == " "* ]]; then
            LOG_KEEP=0
            return 0
        fi
        LOG_IN_ARGS=0
    fi

    case "$rest" in
        print_timing:*)
            body="$(_log_trim "${rest##*| }")"
            case "$body" in
                *"prompt processing, n_tokens = "*)
                    toks="${body#*n_tokens = }"; toks="${toks%%,*}"; toks="${toks//[[:space:]]/}"
                    prog="${body#*progress = }"; prog="${prog%%,*}"
                    tps="${body##*/ }"; tps="${tps%% tokens per second*}"
                    pct="$(_log_pct "$prog")"
                    _log_set pp "[pp]" "${toks} tok ${pct}% ${tps} t/s ETA: $(_log_eta "$toks" "$prog" "$tps")"
                    ;;
                *"n_gen = "*)
                    toks="${body#*n_gen = }"; toks="${toks%%,*}"; toks="${toks//[[:space:]]/}"
                    tps="${body#*tg = }"; tps="${tps%%,*}"; tps="${tps//[[:space:]]/}"; tps="${tps%t/s}"
                    _log_set gen "[gen]" "${toks} tok ${tps} t/s"
                    ;;
                *"draft acceptance = "*)
                    acc="$(_log_trim "${body#*draft acceptance = }")"; acc="${acc%% *}"
                    counts="${body#*(}"; counts="${counts%%)*}"
                    read -r -a parts <<<"$counts" || true
                    mean="$(_log_trim "${body#*mean len = }")"
                    _log_set mtp "[mtp]" "$(_log_pct "$acc")% accepted (${parts[0]:-?}/${parts[3]:-?}), mean len ${mean}"
                    ;;
                *"prompt eval time = "*)
                    ms="$(_log_trim "${body#*= }")"; ms="${ms%% *}"
                    toks="$(_log_trim "${body#*ms / }")"; toks="${toks%% *}"
                    tps="$(_log_trim "${body##*, }")"; tps="${tps%%)*}"; tps="${tps%% *}"
                    sec="$(_log_sec "$ms")"
                    _log_set pp "[pp]" "${toks} tok in ${sec} s (${tps} t/s)"
                    ;;
                *"eval time = "*)
                    ms="$(_log_trim "${body#*= }")"; ms="${ms%% *}"
                    toks="$(_log_trim "${body#*ms / }")"; toks="${toks%% *}"
                    tps="$(_log_trim "${body##*, }")"; tps="${tps%%)*}"; tps="${tps%% *}"
                    sec="$(_log_sec "$ms")"
                    _log_set gen "[gen]" "${toks} tok in ${sec} s (${tps} t/s)"
                    ;;
                *"total time = "*)
                    ms="$(_log_trim "${body#*= }")"; ms="${ms%% *}"
                    toks="$(_log_trim "${body#*ms / }")"; toks="${toks%% *}"
                    sec="$(_log_sec "$ms")"
                    _log_set "done" "[done]" "${toks} tok in ${sec} s"
                    ;;
                *"graphs reused"*|*"graph reallocs"*)
                    LOG_KEEP=0
                    ;;
                *)
                    _log_set "$LOG_KIND" "$tag" "$body"
                    ;;
            esac
            ;;
        get_availabl:*|launch_slot_:*|release:*)
            LOG_KEEP=0
            ;;
        common_param:*)
            LOG_KEEP=0
            ;;
        llama_server:*)
            _log_set "$LOG_KIND" "$tag" "${rest#llama_server: }"
            ;;
        server_setup:*)
            _log_set "$LOG_KIND" "$tag" "${rest#server_setup: }"
            ;;
        server_run_i:*)
            _log_set "$LOG_KIND" "$tag" "${rest#server_run_i: }"
            ;;
        server_on_li:*)
            _log_set "$LOG_KIND" "$tag" "${rest#server_on_li: }"
            ;;
        load_model:*"loading model '"*)
            p="${rest#*\'}"; p="${p%\'*}"
            _log_set "$LOG_KIND" "$tag" "loading model ${p##*/}"
            ;;
        load_model:*"initializing, n_slots"*)
            s="${rest#*n_slots = }"; s="${s%%,*}"
            c="${rest#*n_ctx_slot = }"; c="${c%%,*}"
            if [[ "$s" == "1" ]]; then
                _log_set "$LOG_KIND" "$tag" "1 slot, ${c} context"
            else
                _log_set "$LOG_KIND" "$tag" "${s} slots, ${c} context"
            fi
            ;;
        common_speculative_init_result:*)
            _log_set "$LOG_KIND" "$tag" "MTP draft context created"
            ;;
        common_fit_params:*"n_gpu_layers already set by user"*)
            n="${rest#*set by user to }"; n="${n%%,*}"
            _log_set warn "[WARN]" "fit skipped: n_gpu_layers already set by user to ${n}"
            ;;
        stop:*)
            LOG_KEEP=0
            ;;
        proxy_reques:*)
            LOG_KEEP=0
            ;;
        join:*"request for name="*)
            nm="${rest#*name=}"; nm="${nm%% *}"
            _log_set "$LOG_KIND" "$tag" "request for ${nm} queued at position ${rest##*position }"
            ;;
        ensure_model:*)
            LOG_KEEP=0
            ;;
        load:*"spawning server instance with name="*)
            nm="${rest#*name=}"; nm="${nm%% *}"
            _log_set "$LOG_KIND" "$tag" "loading ${nm} on port ${rest##*port }"
            ;;
        load:*"spawning server instance with args:"*)
            LOG_KEEP=0
            LOG_IN_ARGS=1
            ;;
        init:*)
            _log_set "$LOG_KIND" "$tag" "${rest#init: }"
            ;;
        *": "*)
            _log_set "$LOG_KIND" "$tag" "${rest#*: }"
            ;;
        *)
            _log_set "$LOG_KIND" "$tag" "$rest"
            ;;
    esac

    return 0
}

# Print the rendered line with colors (terminal view).
log_print_clean() {
    local color=""
    case "${LOG_KIND:-raw}" in
        info) color="$GREEN" ;;
        warn) color="$YELLOW" ;;
        err)  color="$RED" ;;
        dbg)  color="$DIM" ;;
        pp)   color="$BLUE" ;;
        gen)  color="$CYAN" ;;
        mtp)  color="$MAGENTA" ;;
        done) color="$DIM" ;;
    esac
    if [[ -n "${LOG_TAG:-}" ]]; then
        printf '%s%s%s %s\n' "$color" "$LOG_TAG" "$NC" "$LOG_TEXT"
    else
        printf '%s\n' "$LOG_TEXT"
    fi
}

# Map a LOG_KIND to its terminal color code.
log_color_for_kind() {
    case "${1:-raw}" in
        info) printf '%s' "$GREEN" ;;
        warn) printf '%s' "$YELLOW" ;;
        err)  printf '%s' "$RED" ;;
        dbg)  printf '%s' "$DIM" ;;
        pp)   printf '%s' "$BLUE" ;;
        gen)  printf '%s' "$CYAN" ;;
        mtp)  printf '%s' "$MAGENTA" ;;
        done) printf '%s' "$DIM" ;;
        *)    printf '%s' "$NC" ;;
    esac
}

# Compute ETA in seconds from cumulative processed tokens, progress (0..1), and tokens-per-second speed.
# Usage: _log_eta "$toks" "$prog" "$tps"
# Output: "26.0s" (seconds, one decimal) or "--" (if rate is zero).
# Formula: total = t / p, remaining = total - t = t * (1 - p) / p, eta = remaining / r
_log_eta() {
    local tokens="${1:-0}" progress="${2:-0}" rate="${3:-0}"
    awk -v t="$tokens" -v p="$progress" -v r="$rate" 'BEGIN {
        if (r+0 <= 0) { printf "%s", "--"; exit }
        if (p+0 <= 0) { printf "%s", "--"; exit }
        remaining = t * (1 - p) / p
        if (remaining + 0 <= 0) { printf "%s", "0.0s"; exit }
        printf "%.1fs", remaining / r
    }'
}

# Log rotation: 50 MiB per file with three older copies kept.
LLM_LOG_MAX_BYTES="${LLM_LOG_MAX_BYTES:-52428800}"
LLM_LOG_KEEP="${LLM_LOG_KEEP:-3}"

# Rotate FILE once it reaches MAX bytes, keeping up to KEEP older copies
# (FILE.1 is the newest). Writers open FILE per line, so rotating under a live
# append handle is safe: the next write recreates FILE.
log_rotate() {
    local file="${1-}" max="${2:-$LLM_LOG_MAX_BYTES}" keep="${3:-$LLM_LOG_KEEP}"
    local size=0 i=0

    [[ -n "$file" && -f "$file" ]] || return 0
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    (( max > 0 )) || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=1
    (( keep >= 1 )) || keep=1

    size="$(stat -c %s -- "$file" 2>/dev/null || printf '0')"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    (( size >= max )) || return 0

    for (( i = keep - 1; i >= 1; i-- )); do
        if [[ -f "$file.$i" ]]; then
            mv -f -- "$file.$i" "$file.$((i + 1))"
        fi
    done
    mv -f -- "$file" "$file.1"
    return 0
}

# Describe the rotation limit for terminal output.
log_rotation_label() {
    local max="${1:-$LLM_LOG_MAX_BYTES}" keep="${2:-$LLM_LOG_KEEP}"
    if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 && max % 1048576 == 0 )); then
        printf '%s MiB, keep %s' "$(( max / 1048576 ))" "$keep"
    elif [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        printf '%s bytes, keep %s' "$max" "$keep"
    else
        printf 'disabled'
    fi
}

# How many appended bytes may pass between size checks: an eighth of the limit,
# clamped so tiny limits still rotate and large ones are not stat'ed per line.
_log_check_bytes() {
    local max="${1-0}" check=0
    check=$(( max / 8 ))
    if (( check > 1048576 )); then
        check=1048576
    fi
    if (( check < 4096 )); then
        check=4096
    fi
    if (( check > max )); then
        check="$max"
    fi
    if (( check < 1 )); then
        check=1
    fi
    printf '%d' "$check"
}

# Copy stdin to FILE line by line, rotating FILE as it grows.
log_tee_stream() {
    local file="${1-}" max="${2:-$LLM_LOG_MAX_BYTES}" keep="${3:-$LLM_LOG_KEEP}"
    local line="" pending=0 check=1 limit=0

    if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        limit="$max"
        check="$(_log_check_bytes "$max")"
    fi

    while IFS= read -r line; do
        printf '%s\n' "$line" >>"$file"
        printf '%s\n' "$line"
        pending=$(( pending + ${#line} + 1 ))
        if (( limit > 0 && pending >= check )); then
            pending=0
            log_rotate "$file" "$limit" "$keep"
        fi
    done
    return 0
}

# Read llama.cpp output on stdin, append clean text to CLEANFILE, and print
# either the clean view or the raw line to stdout.
log_filter_stream() {
    local cleanfile="${1-}" mode="${2:-clean}" line=""
    local max="${3:-$LLM_LOG_MAX_BYTES}" keep="${4:-$LLM_LOG_KEEP}"
    local pending=0 check=1 limit=0
    if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        limit="$max"
        check="$(_log_check_bytes "$max")"
    fi
    LOG_IN_ARGS=0
    while IFS= read -r line; do
        log_render_line "$line"
        (( LOG_KEEP )) || continue
        if [[ -n "${LOG_TAG:-}" ]]; then
            local color=""
            case "$LOG_KIND" in
                info) color="$GREEN" ;; warn) color="$YELLOW" ;; err) color="$RED" ;;
                dbg) color="$DIM" ;; pp) color="$BLUE" ;; gen) color="$CYAN" ;;
                mtp) color="$MAGENTA" ;; done) color="$DIM" ;;
            esac
            printf '%s%s%s %s\n' "$color" "$LOG_TAG" "$NC" "$LOG_TEXT" >>"$cleanfile" || true
        else
            printf '%s\n' "$LOG_TEXT" >>"$cleanfile" || true
        fi
        pending=$(( pending + ${#LOG_TAG} + ${#LOG_TEXT} + 2 ))
        if (( limit > 0 && pending >= check )); then
            pending=0
            log_rotate "$cleanfile" "$limit" "$keep"
        fi
        if [[ "$mode" == "raw" ]]; then
            printf '%s\n' "$line"
        else
            log_print_clean
        fi
    done
    return 0
}
