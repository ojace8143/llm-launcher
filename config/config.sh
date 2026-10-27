#!/usr/bin/env bash

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_HOME="$(cd "$CONFIG_DIR/.." && pwd)"

LLAMA_HOME="$LLM_HOME/llama.cpp"
LLAMA_BIN="$LLAMA_HOME/build/bin/llama-cli"

MODEL_DIR="$LLM_HOME/models"

DEFAULT_MODEL="${DEFAULT_MODEL:-}"

MEMORY_DIR="$LLM_HOME/memory"
MEMORY_FILE="$MEMORY_DIR/example.md"

CONTEXT_SIZE="16384"

DEVICE=""

