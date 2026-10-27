# llm-launcher

A small llama.cpp launcher with an fzf interface, per-model settings, and a
health check.

I originally wrote this as a little tool for me to use personally, but I came back to this with my recent rediscovery with local llms. So I'm now beefing it up with Opencode (Mainly Big Pickle, Qwen3.8, and DeepSeek V4.1 Flash) Rest of README written mostly by DeepSeek.

## Requirements

- Linux with a bash shell
- `git`, `cmake`, `make`, a C++ compiler (`g++` or `clang++`), `curl`, `fzf`
- Optional: CUDA toolkit (`nvcc`) and/or a Vulkan runtime for GPU builds

`setup.sh` can install the basic dependencies on xbps, pacman, emerge, and
apt-based systems. (More support should come later)

## Setup

```bash
./setup.sh
```

The setup script:

- installs missing base packages (asks first)
- clones and builds llama.cpp
- lets you choose CPU, CUDA, Vulkan, or CUDA + Vulkan
- writes your personal settings to `config/config.local.sh` (gitignored)
- optionally downloads a default model (Qwen 8b Instruct)
- offers to symlink `llm` into `~/.local/bin`
- non interactive setup if you so desire

Non-interactive example:

```bash
./setup.sh --yes --no-deps --backend=vulkan
```

Options:

```text
-y, --yes             Accept defaults
    --no-deps         Skip package installation
    --backend=NAME    cpu | cuda | vulkan | cuda+vulkan | custom
    --fresh           Delete the llama.cpp build directory first
-h, --help            Show setup help
```

## Usage

```text
llm help                     Full command list
llm help <command>           Help for one command

llm launch                   Launch the default model
llm launch select            Pick a model with fzf
llm launch <model>           Launch a model by filename
llm launch <model> -- ...    Pass extra flags to llama-cli

llm config show              Show the effective configuration
llm config edit              Interactive configuration menu
llm config set <key> <val>   Set a value
llm config default           Choose the default model
llm config device            Choose the GPU/device
llm config context           Choose the context size
llm config ngl               Choose GPU layers offloaded
llm config memory            Choose the long-term memory file

llm health                   Check the installation
llm version                  Show version and paths

llm models list              List local models
llm models download <url>    Download a .gguf file
llm setup                    Run the setup script
```

Examples:

```bash
llm launch select
llm launch Qwen3-1.7B-Q4_K_M.gguf -- --temp 0.2
llm config set CONTEXT_SIZE 32768
llm health
```

## Using `llm` from anywhere

`setup.sh` can create the symlink for you. Manually:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/llm" ~/.local/bin/llm
```

Make sure `~/.local/bin` is in your `PATH`. `llm` resolves symlinks, so it
works when linked.

## Configuration

- `config/config.sh` contains defaults and is never edited by the tools.
- `config/config.local.sh` contains your settings and is gitignored.
- Set values with `llm config set KEY VALUE` or edit them through
  `llm config edit`.

Useful keys:

```text
DEFAULT_MODEL  MODEL_DIR     LLAMA_BIN     LLAMA_HOME
MEMORY_DIR     MEMORY_FILE   MEMORY_ENABLED
CONTEXT_SIZE   NGL           DEVICE
```

## Troubleshooting

```bash
llm health
```

This checks the configuration, llama.cpp binary, models, device, memory file,
and fzf. Re-run `./setup.sh` if a path or build is missing.

## Notes

Backend selection is per build. Switching backends reuses the same
`llama.cpp/build` directory; use `./setup.sh --fresh` if CMake keeps stale
settings.
