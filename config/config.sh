#!/usr/bin/env bash

LLM_HOME="$HOME/llm-launcher"

LLAMA_HOME="$LLM_HOME/llama.cpp"
LLAMA_BIN="$LLAMA_HOME/build/bin/llama-cli"

MODEL_DIR="$LLM_HOME/models"

DEFAULT_MODEL=""

MEMORY_DIR="$LLM_HOME/memory"
MEMORY_FILE="$MEMORY_DIR/memory.md"
