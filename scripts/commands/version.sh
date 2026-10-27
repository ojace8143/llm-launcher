#!/usr/bin/env bash
# `llm version`

version_backends() {
  local cache="${LLAMA_HOME:-}/build/CMakeCache.txt"
  if [[ ! -f "$cache" ]]; then
    printf 'not built'
    return 0
  fi

  local cuda=0 vulkan=0
  if grep -q '^GGML_CUDA:BOOL=ON' "$cache"; then
    cuda=1
  fi
  if grep -q '^GGML_VULKAN:BOOL=ON' "$cache"; then
    vulkan=1
  fi

  if ((cuda && vulkan)); then
    printf 'CUDA + Vulkan'
  elif ((cuda)); then
    printf 'CUDA'
  elif ((vulkan)); then
    printf 'Vulkan'
  else
    printf 'CPU'
  fi
}

cmd_version() {
  local llama_version="unknown"
  if [[ -d "${LLAMA_HOME:-}/.git" ]] && have_cmd git; then
    llama_version="$(git -C "$LLAMA_HOME" describe --tags --always --dirty 2>/dev/null || echo unknown)"
  fi

  printf '%s%s' "$MAGENTA" "$BOLD"
  llm_ascii_art
  printf '%s' "$NC"

  section "Version Info"
  printf '  %-16s %s\n' "llm-launcher" "$VERSION"
  printf '  %-16s %s\n' "LLM_HOME" "$LLM_HOME"
  printf '  %-16s %s\n' "llama.cpp" "$llama_version"
  printf '  %-16s %s\n' "Backends" "$(version_backends)"
  printf '  %-16s %s\n' "llama-cli" "${LLAMA_BIN:-unset}"
  printf '  %-16s %s\n' "llama-server" "${LLAMA_SERVER_BIN:-unset}"
  printf '  %-16s %s\n' "CUDA toolkit" "${CUDA_HOME:-(system/default)}"
  printf '  %-16s %s\n' "Config" "$LLM_CONFIG"

  if have_cmd "${LLAMA_SERVER_BIN:-}" &&
    "${LLAMA_SERVER_BIN}" --help 2>&1 | grep -q -- "--tools"; then
    printf '  %-16s %s\n' "Agent tools" "supported"
  else
    printf '  %-16s %s\n' "Agent tools" "unavailable"
  fi
}

help_version() {
  cat <<EOF
${BOLD}llm version${NC}

Print the llm-launcher banner, version, build backend, and important paths.
EOF
}
