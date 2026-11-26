#!/usr/bin/env bash
# `llm pi` — generate a pi (pi.dev) provider for the local llama-server.

pi_json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

pi_base_url() {
    local host="${1:-${SERVER_HOST:-127.0.0.1}}"
    local port="${2:-${SERVER_PORT:-9931}}"
    case "$host" in
        0.0.0.0|"") host="127.0.0.1" ;;
        ::|"[::]"|::1) host="[::1]" ;;
    esac
    printf 'http://%s:%s/v1' "$host" "$port"
}

pi_agent_dir() {
    local dir="${PI_CODING_AGENT_DIR:-}"
    if [[ -n "$dir" ]]; then
        # Match a literal leading "~" the way pi expands it.
        # shellcheck disable=SC2088
        case "$dir" in
            "~") dir="$HOME" ;;
            "~/"*) dir="$HOME/${dir:2}" ;;
        esac
        printf '%s\n' "$dir"
    else
        printf '%s/.pi/agent\n' "$HOME"
    fi
}

pi_default_config_path() {
    printf '%s/models.json\n' "$(pi_agent_dir)"
}

pi_existing_config_path() {
    local path
    path="$(pi_default_config_path)"
    if [[ -f "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    return 1
}

cmd_pi() {
    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        config) pi_config "$@" ;;
        merge) pi_config --merge "$@" ;;
        ""|help|-h|--help) help_pi ;;
        *)
            err "Unknown pi option: $sub"
            help_pi
            return 2
            ;;
    esac
}

pi_config() {
    local write=0 merge=0 assume_yes=0 dry_run=0 reasoning=0
    local output="" model_query=""
    local provider="${PI_PROVIDER_ID:-local}"
    local provider_name="llama.cpp (local)"
    local host="${SERVER_HOST:-127.0.0.1}"
    local port="${SERVER_PORT:-9931}"
    local max_output="${PI_MAX_OUTPUT:-8192}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --write) write=1 ;;
            --merge) merge=1 ;;
            --yes|-y) assume_yes=1 ;;
            --dry-run) dry_run=1 ;;
            --reasoning) reasoning=1 ;;
            --output)
                [[ $# -ge 2 ]] || { err "--output requires a value"; return 2; }
                output="$2"; shift ;;
            --model)
                [[ $# -ge 2 ]] || { err "--model requires a value"; return 2; }
                model_query="$2"; shift ;;
            --provider)
                [[ $# -ge 2 ]] || { err "--provider requires a value"; return 2; }
                provider="$2"; shift ;;
            --name)
                [[ $# -ge 2 ]] || { err "--name requires a value"; return 2; }
                provider_name="$2"; shift ;;
            --host)
                [[ $# -ge 2 ]] || { err "--host requires a value"; return 2; }
                host="$2"; shift ;;
            --port)
                [[ $# -ge 2 ]] || { err "--port requires a value"; return 2; }
                port="$2"; shift ;;
            --max-output)
                [[ $# -ge 2 ]] || { err "--max-output requires a value"; return 2; }
                max_output="$2"; shift ;;
            -h|--help) help_pi; return 0 ;;
            *)
                err "Unknown pi config option: $1"
                return 2
                ;;
        esac
        shift
    done

    if ! [[ "$provider" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        err "Invalid provider ID '$provider' (use letters, numbers, dot, underscore, or dash)"
        return 2
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "Invalid port: $port"
        return 2
    fi
    if ! [[ "$max_output" =~ ^[0-9]+$ ]] || (( max_output < 1 )); then
        err "Invalid --max-output: $max_output"
        return 2
    fi
    if (( write && merge )); then
        err "--write and --merge cannot be used together"
        return 2
    fi
    if (( dry_run && ! merge )); then
        err "--dry-run requires --merge"
        return 2
    fi
    if (( assume_yes && ! merge )); then
        err "--yes requires --merge"
        return 2
    fi

    local base_url
    base_url="$(pi_base_url "$host" "$port")"
    validate_aliases || return 1

    if (( merge )); then
        if [[ -n "$output" ]]; then
            if [[ -d "$output" ]]; then
                err "Merge target is a directory: $output"
                return 1
            fi
            if [[ ! -f "$output" ]]; then
                err "No existing config to merge: $output"
                err "Use --write or --output to create a new config instead."
                return 1
            fi
        else
            output="$(pi_existing_config_path)" || {
                err "No existing pi config found."
                err "Use --write or --output to create a new config instead."
                return 1
            }
        fi
        pi_merge_config "$output" "$provider" "$provider_name" \
            "$base_url" "$model_query" "$max_output" "$reasoning" \
            "$assume_yes" "$dry_run"
        return $?
    fi

    if (( write )) && [[ -z "$output" ]]; then
        output="$(pi_default_config_path)"
    fi

    if [[ -n "$output" ]]; then
        if [[ -d "$output" ]]; then
            err "Output path is a directory: $output"
            return 1
        fi

        mkdir -p "$(dirname "$output")" || {
            err "Unable to create directory: $(dirname "$output")"
            return 1
        }
        local tmp
        tmp="$(mktemp "${output}.XXXXXX")" || {
            err "Unable to create a temporary file next to $output"
            return 1
        }
        if ! pi_render_config "$provider" "$provider_name" "$base_url" \
            "$model_query" "$max_output" "$reasoning" >"$tmp"; then
            rm -f "$tmp"
            return 1
        fi

        if [[ -e "$output" ]]; then
            if cmp -s "$tmp" "$output"; then
                rm -f "$tmp"
                info "pi config is already up to date: $output"
                return 0
            fi
            err "Refusing to overwrite existing pi config: $output"
            err "The generated snippet follows on stdout; merge it manually."
            cat "$tmp"
            rm -f "$tmp"
            return 1
        fi

        mv -- "$tmp" "$output" || {
            rm -f "$tmp"
            err "Unable to write $output"
            return 1
        }
        info "Wrote pi config: $output"
        info "Start pi with: pi --provider $provider --model <id>"
        return 0
    fi

    pi_render_config "$provider" "$provider_name" "$base_url" \
        "$model_query" "$max_output" "$reasoning"
}

pi_merge_config() {
    local output="$1" provider="$2" provider_name="$3" base_url="$4"
    local model_query="$5" max_output="$6" reasoning="$7"
    local assume_yes="$8" dry_run="$9"

    if ! have_cmd python3; then
        err "python3 is required for --merge"
        return 1
    fi

    local generated
    generated="$(mktemp "${TMPDIR:-/tmp}/llm-pi.XXXXXX")" || {
        err "Unable to create a temporary file for the generated config"
        return 1
    }
    if ! pi_render_config "$provider" "$provider_name" "$base_url" \
        "$model_query" "$max_output" "$reasoning" >"$generated"; then
        rm -f "$generated"
        return 1
    fi

    if (( ! dry_run && ! assume_yes )); then
        if [[ ! -t 0 ]]; then
            rm -f "$generated"
            err "Refusing to merge without confirmation; use --yes"
            return 1
        fi
        local answer=""
        printf 'Merge provider %q into %s? [y/N] ' "$provider" "$output" >&2
        read -r answer || answer=""
        case "$answer" in
            y|Y|yes|YES) ;;
            *)
                rm -f "$generated"
                info "Aborted"
                return 0
                ;;
        esac
    fi

    local rc=0
    python3 - "$output" "$generated" "$provider" "$dry_run" <<'PY' || rc=$?
import copy
import datetime
import json
import os
import shutil
import stat
import sys
import tempfile


def deep_merge(existing, generated):
    if isinstance(existing, dict) and isinstance(generated, dict):
        merged = dict(existing)
        for key, value in generated.items():
            if key in merged:
                merged[key] = deep_merge(merged[key], value)
            else:
                merged[key] = copy.deepcopy(value)
        return merged
    return copy.deepcopy(generated)


def merge_models(existing, generated):
    if not isinstance(existing, list):
        existing = []
    if not isinstance(generated, list):
        generated = []

    by_id = {}
    order = []
    for entry in existing:
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            by_id[entry["id"]] = entry
            order.append(entry["id"])
        else:
            order.append(None)

    added = []
    updated = []
    for entry in generated:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        model_id = entry["id"]
        if model_id in by_id:
            by_id[model_id] = deep_merge(by_id[model_id], entry)
            updated.append(model_id)
        else:
            by_id[model_id] = copy.deepcopy(entry)
            order.append(model_id)
            added.append(model_id)

    result = []
    for model_id in order:
        if model_id is None:
            continue
        if model_id in by_id:
            result.append(by_id[model_id])
            del by_id[model_id]
    return result, added, updated


def fail(message):
    print(f"llm pi: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    path = os.path.realpath(sys.argv[1])
    generated_path = sys.argv[2]
    provider_id = sys.argv[3]
    dry_run = sys.argv[4] == "1"

    if not os.path.isfile(path):
        fail(f"merge target is not a file: {sys.argv[1]}")

    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        fail(f"unable to read {path}: {exc}")

    try:
        existing = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {path}: {exc}")
    except Exception as exc:
        fail(f"unable to parse {path}: {exc}")

    if not isinstance(existing, dict):
        fail(f"expected a top-level object in {path}")

    try:
        with open(generated_path, "r", encoding="utf-8") as handle:
            generated = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"unable to read generated config: {exc}")

    try:
        generated_provider = generated["providers"][provider_id]
    except (KeyError, TypeError):
        fail(f"generated config is missing provider {provider_id!r}")

    if not isinstance(generated_provider, dict):
        fail(f"generated provider {provider_id!r} is not an object")

    providers = existing.get("providers")
    if providers is None:
        providers = {}
    elif not isinstance(providers, dict):
        fail("existing 'providers' value is not an object")

    old_provider = providers.get(provider_id)
    if old_provider is not None and not isinstance(old_provider, dict):
        fail(f"existing provider {provider_id!r} is not an object")

    old_provider = old_provider or {}

    merged_provider = deep_merge(old_provider, generated_provider)
    merged_provider["models"], added, updated = merge_models(
        old_provider.get("models"), generated_provider.get("models")
    )
    providers[provider_id] = merged_provider
    existing["providers"] = providers

    if "$schema" not in existing and "$schema" in generated:
        existing["$schema"] = generated["$schema"]

    merged_text = json.dumps(existing, indent=2, ensure_ascii=False) + "\n"
    try:
        json.loads(merged_text)
    except json.JSONDecodeError as exc:
        fail(f"merged result is not valid JSON: {exc}")

    def summary(backup=None):
        print(f"provider: {provider_id}", file=sys.stderr)
        if added:
            print("models added: " + ", ".join(added), file=sys.stderr)
        if updated:
            print("models updated: " + ", ".join(updated), file=sys.stderr)
        if not added and not updated:
            print("models: no generated model changes", file=sys.stderr)
        if backup:
            print(f"backup: {backup}", file=sys.stderr)

    if dry_run:
        sys.stdout.write(merged_text)
        summary()
        return 0

    if merged_text == raw:
        print(f"pi config is already up to date: {path}", file=sys.stderr)
        return 0

    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{path}.bak.{timestamp}"
    if os.path.exists(backup):
        counter = 1
        while os.path.exists(f"{backup}.{counter}"):
            counter += 1
        backup = f"{backup}.{counter}"

    try:
        shutil.copy2(path, backup)
    except OSError as exc:
        fail(f"unable to create backup {backup}: {exc}")

    directory = os.path.dirname(path) or "."
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".pi-merge.", dir=directory)
    except OSError as exc:
        fail(f"unable to create a temporary file in {directory}: {exc}")

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(merged_text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(tmp_path, path)
    except Exception as exc:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        fail(f"unable to write {path}: {exc}")

    summary(backup)
    return 0


try:
    raise SystemExit(main())
except KeyboardInterrupt:
    print("llm pi: interrupted", file=sys.stderr)
    raise SystemExit(130)
PY

    if (( rc != 0 )); then
        rm -f "$generated"
        return "$rc"
    fi
    rm -f "$generated"

    if (( dry_run )); then
        info "Dry run: no files were changed" >&2
    else
        info "Merge complete: provider '$provider' -> $output"
        info "Start pi with: pi --provider $provider --model <id>"
    fi
    return 0
}

pi_render_config() {
    local provider="$1" provider_name="$2" base_url="$3"
    local model_query="$4" max_output="$5" reasoning="$6"

    local -a files=()
    if [[ -n "$model_query" ]]; then
        local resolved
        resolved="$(resolve_model_or_alias "$model_query")" || {
            err "Model not found: $model_query"
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
        files=("$resolved")
    else
        local -a names=()
        mapfile -t names < <(list_models)
        if (( ${#names[@]} == 0 )); then
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
        local name
        for name in "${names[@]}"; do
            files+=("$model_dir/$name")
        done
    fi

    local -a ids=() contexts=() displays=()
    local -A seen=()
    local file id stem context
    for file in "${files[@]}"; do
        id="$(alias_for_model "$file")"
        if [[ -n "${seen[$id]:-}" ]]; then
            err "Duplicate model ID '$id' for $file and ${seen[$id]}"
            return 1
        fi
        seen[$id]="$file"

        stem="${file##*/}"
        stem="${stem%.gguf}"
        if [[ "$id" == "$stem" ]]; then
            displays+=("$stem")
        else
            displays+=("$id ($stem)")
        fi
        ids+=("$id")

        context="$(context_for_model "$file")"
        [[ "$context" =~ ^[0-9]+$ ]] || context=""
        contexts+=("$context")
    done

    printf '{\n'
    # "$schema" is a literal JSON key, not a shell variable.
    # shellcheck disable=SC2016
    printf '  "$schema": "https://pi.dev/schemas/models.schema.json",\n'
    printf '  "providers": {\n'
    printf '    "%s": {\n' "$(pi_json_escape "$provider")"
    printf '      "name": "%s",\n' "$(pi_json_escape "$provider_name")"
    printf '      "baseUrl": "%s",\n' "$(pi_json_escape "$base_url")"
    printf '      "api": "openai-completions",\n'
    if [[ -n "${SERVER_API_KEY:-}" ]]; then
        # pi interpolates this literal at runtime.
        # shellcheck disable=SC2016
        printf '      "apiKey": "$LLM_LOCAL_API_KEY",\n'
        printf '      "authHeader": true,\n'
    else
        printf '      "apiKey": "llm-local",\n'
    fi
    printf '      "models": [\n'

    local first=1 i output_limit
    for (( i = 0; i < ${#ids[@]}; i++ )); do
        (( first )) || printf ',\n'
        first=0
        printf '        {\n'
        printf '          "id": "%s",\n' "$(pi_json_escape "${ids[$i]}")"
        printf '          "name": "%s",\n' "$(pi_json_escape "${displays[$i]}")"
        if (( reasoning )); then
            printf '          "reasoning": true,\n'
        fi
        printf '          "input": ["text"]'
        output_limit="$max_output"
        if [[ -n "${contexts[$i]}" ]]; then
            local context_limit="${contexts[$i]}"
            local quarter=$(( context_limit / 4 ))
            (( quarter < 512 )) && quarter=512
            if (( output_limit > quarter )); then
                output_limit="$quarter"
            fi
            printf ',\n          "contextWindow": %s' "$context_limit"
        fi
        printf ',\n          "maxTokens": %s\n' "$output_limit"
        printf '        }'
    done
    printf '\n'
    printf '      ]\n'
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
}

help_pi() {
    cat <<EOF
${BOLD}llm pi${NC} <subcommand>

Generate a pi (pi.dev) provider configuration for the local llama-server.

  llm pi config                 Print a provider snippet for all models
  llm pi config --model NAME    Generate a snippet for one model
  llm pi config --write         Write to ~/.pi/agent/models.json
  llm pi config --merge         Merge into ~/.pi/agent/models.json
  llm pi config --output PATH   Write or merge at PATH
  llm pi config --provider ID   Provider ID (default: local)
  llm pi config --port PORT     Server port (default: 9931)
  llm pi config --max-output N  Output-token limit (default: 8192)
  llm pi config --reasoning     Mark every model as supporting thinking
  llm pi merge                  Alias for config --merge

${BOLD}Merge options${NC}
  --yes, -y                     Skip the confirmation prompt
  --dry-run                     Print the merged config, write nothing

${BOLD}Recommended setup${NC}
  llm models alias fast my-fast.gguf
  llm serve fast --background
  llm pi merge
  pi --provider local --model fast

${DIM}pi reads providers from ~/.pi/agent/models.json. Each model is listed
explicitly with its llama-server alias, context window, and output limit.

If SERVER_API_KEY is set, the snippet uses \$LLM_LOCAL_API_KEY and enables
authHeader; export it before starting pi. Otherwise a literal placeholder key
is written, which pi requires even though llama-server ignores it.

pi reads models.json at startup, so rerun this after changing aliases or
profiles. Set PI_CODING_AGENT_DIR to use a different agent directory.

--write never overwrites an existing config. --merge preserves unrelated
providers and models, creates a timestamped backup, and writes atomically.${NC}
EOF
}
