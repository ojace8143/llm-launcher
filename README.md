# llm-launcher

A small llama.cpp launcher with an fzf interface, per-model settings, and a
health check.

I originally wrote this as a little tool for me to use personally, but I came back to this with my recent rediscovery with local llms. So I'm now beefing it up with Opencode (Mainly Big Pickle, Qwen3.8, and DeepSeek V4.1 Flash) Rest of README written mostly by DeepSeek.

To clear things up: The actual llm backend was NOT created by me (it's llama.cpp). This is supposed to be a tool for quality of life and convenience, with configs and stuff.

Note: original project was created a few months ago, and llama.cpp has progressed a lot, so this tool isn't as useful as it was back then.

## Requirements

- Linux with a bash shell
- `git`, `cmake`, `make`, a C++ compiler (`g++` or `clang++`), `curl`, `fzf`
- Optional: CUDA toolkit (`nvcc`) and/or a Vulkan runtime for GPU builds
- Optional: OpenCode for the local OpenAI-compatible provider setup
- Optional: `python3` if you use `llm opencode merge`

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
- optionally configures single-GPU or multi-GPU device selection
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
llm launch <model>           Launch by full or partial model name
llm launch <model> -- ...    Pass extra flags to llama-cli
llm launch --dry-run         Print the command without running it

llm config show [--json]     Show the effective configuration
llm config edit              Interactive configuration menu
llm config get <key>         Print a value
llm config set <key> <val>   Set a value
llm config unset <key>       Remove an override
llm config reset             Reset local config (backs up first)
llm config check             Validate the configuration

llm health                   Check the installation
llm version                  Show version and paths

llm devices                  List GPUs and free VRAM
llm serve                    Run llama-server (OpenAI-compatible API + UI)
llm serve --all              Serve every installed model (router mode)
llm opencode config          Print an OpenCode provider snippet
llm opencode merge           Merge it into an existing OpenCode config
llm agent                    Web UI agent with read/search/edit tools

llm models list              List local models
llm models info <name>       Show size/path/profile/settings
llm models config [model]    Per-model context, GPU, and split settings
llm models add <path>        Add a .gguf to the models directory
llm models download <url>    Download a .gguf file
llm models alias <a> <m>     Set a readable model alias
llm models aliases           List model aliases
llm completion bash|zsh      Print shell completion
llm setup                    Run the setup script
```

Examples:

```bash
llm launch select
llm launch Qwen3-1.7B-Q4_K_M.gguf -- --temp 0.2
llm config set CONTEXT_SIZE 32768
llm models alias coder Qwen3VL-8B-Instruct-Q4_K_M.gguf
llm models config coder set CONTEXT_SIZE 32768
llm models config general set DEVICE CUDA0,Vulkan1
llm serve --all --background --no-tools
llm opencode merge
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

## CUDA toolkit outside the package manager

If `nvcc` is not available from your distro repositories, install the NVIDIA
runfile toolkit somewhere user-writable (for example `~/Src/cuda-13.2.2`):

```bash
CUDA_VERSION=13.2.2
CUDA_RUNFILE=cuda_${CUDA_VERSION}_595.71.05_linux.run

mkdir -p ~/Src
cd ~/Src
curl -fLO "https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${CUDA_RUNFILE}"

# --silent implies EULA acceptance; --toolkit skips the driver
env -u DISPLAY sh "$CUDA_RUNFILE" \
  --silent --toolkit \
  --toolkitpath="$HOME/Src/cuda-$CUDA_VERSION" \
  --no-opengl-libs --no-man-page --override \
  --tmpdir="$HOME/Src/.cuda-tmp"
```

Then point llm-launcher at it:

```bash
llm config set CUDA_HOME "$HOME/Src/cuda-13.2.2"
./setup.sh --backend=cuda --fresh
```

`CUDA_HOME` adds `$CUDA_HOME/bin` to `PATH` and `$CUDA_HOME/lib64` to
`LD_LIBRARY_PATH` for setup and launches. Setup also auto-detects
`~/Src/cuda-*/bin/nvcc` if `CUDA_HOME` is not set.

## Multi-GPU

List devices and their free memory:

```bash
llm devices
```

Select one or more devices with fzf (TAB multi-selects):

```bash
llm config device
```

Then choose how layers are split:

```bash
llm config split          # none | layer | row | tensor
llm config tensor-split   # auto (by free VRAM) | even | manual
llm config main-gpu
```

`llm config device` automatically writes a VRAM-proportional tensor split when
more than one device is selected. You can also set everything directly:

```bash
llm config set DEVICE "CUDA0,CUDA1"
llm config set SPLIT_MODE layer
llm config set TENSOR_SPLIT "3,1"
```

One-off launches:

```bash
llm launch --device CUDA0,CUDA1 --split-mode layer
llm launch --dry-run        # verify the generated flags
```

## Per-model configuration

Global settings are the fallback. A profile overrides them for one model, and
command-line flags override both.

Create or edit a profile interactively:

```bash
llm models config                    # pick a model with fzf
llm models config Qwen3VL-8B         # partial name works
llm models config coder              # aliases work too
```

Scriptable commands:

```bash
llm models config <model> show       # effective values and where they come from
llm models config <model> set CONTEXT_SIZE 32768
llm models config <model> set DEVICE CUDA0
llm models config <model> unset TEMP
llm models config <model> edit       # open the profile in $EDITOR
llm models config <model> remove
```

Profiles live in `config/profiles/<model-name-without-.gguf>.sh` and are
gitignored. A typical pair looks like this:

```bash
# config/profiles/Qwen3VL-8B-Instruct-Q4_K_M.sh
# Small model: everything on the 4060, 32k context.
CONTEXT_SIZE=32768
DEVICE="CUDA0"
NGL=99
```

```bash
# config/profiles/Qwen3.8-27B-UD-Q4_K_M.sh
# Large model: 40/60 across both GPUs, 256k context.
CONTEXT_SIZE=262144
DEVICE="CUDA0,Vulkan1"
SPLIT_MODE="layer"
TENSOR_SPLIT="40,60"
NGL=99
```

Allowed profile keys:

```text
CONTEXT_SIZE  NGL  THREADS  THREADS_BATCH  FLASH_ATTN  PARALLEL
TEMP  TOP_P  EXTRA_ARGS  DEVICE  SPLIT_MODE  TENSOR_SPLIT  MAIN_GPU  FIT
```

Behavior worth knowing:

- A single device ignores `SPLIT_MODE`, `TENSOR_SPLIT`, and `MAIN_GPU`. The
  profile above can therefore sit on top of a global two-GPU configuration
  without clearing the split values.
- `DEVICE="none"` forces CPU-only for one model.
- Router mode generates a section per model, so `llm serve --all` honors the
  profiles. Server options such as host, port, API key, and tools remain global.
- `llm serve <model>` and `llm launch <model>` load the profile after the global
  configuration.
- `llm opencode config` uses the per-model context size when generating
  OpenCode model limits.

`llm config check` validates every profile, and `llm serve --all --dry-run`
prints the generated preset.

## Benchmarking

Compare backends and devices with `llm bench` (uses `llama-bench`):

```bash
llm bench                        # Interactive device/context selection
llm bench --quick                # Fast comparison (512,1024,2048)
llm bench --devices CUDA0,Vulkan0,Vulkan1
llm bench --contexts 512,1024,2048,4096
llm bench --dry-run              # Print llama-bench commands
```

Notes:
- Compares CUDA and Vulkan across available devices
- Warns if comparing `CUDA0` and `Vulkan0` (same physical GPU)
- Runs sequentially by default to avoid contention
- Results are written to a temp directory during the run; use `--save <path>` to persist

## Server mode

`llm serve` starts `llama-server` with the same model and GPU settings:

```bash
llm serve                      # foreground, default model
llm serve <model>              # foreground, one model
llm serve --background         # background
llm serve status
llm serve logs -f
llm serve stop
llm serve restart
```

The server listens on `127.0.0.1:9931` by default and exposes an
OpenAI-compatible API at `/v1`, plus the llama.cpp Web UI.

```bash
curl http://127.0.0.1:9931/v1/models
curl http://127.0.0.1:9931/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"hello"}],"stream":true}'
```

### Multiple models

`llama-server` supports a router mode that loads models on demand and unloads
them when they are no longer needed. llm-launcher exposes this with:

```bash
llm serve --all --background
```

Router mode uses a generated preset in `run/models.ini`. Every installed model
is listed through `/v1/models` and can be requested by name. With
`SERVER_MODELS_MAX=1` (the default), only one model is loaded at a time, which
is the sensible choice for an 8 GB GPU.

```bash
llm models alias coder Qwen3VL-8B-Instruct-Q4_K_M.gguf
llm models alias general Qwen3.8-27B-UD-Q4_K_M.gguf
llm serve --all --background --no-tools
```

Aliases become preset section names, `--alias` values for single-model mode,
and OpenCode model IDs. Without an alias, the GGUF filename stem is sanitized
and used as the model ID.

Router mode applies each model's profile when it loads that model, so context,
device, split, and generation settings can differ per model. Configure them with
`llm models config`. Server-level options such as host, port, and tools remain
global.

The first request for a model waits for it to load. Switching models can take
several seconds while the previous model is unloaded.

## OpenCode integration

OpenCode can use the local server through its OpenAI-compatible provider
package. The recommended setup is router mode plus explicit aliases:

```bash
llm models alias coder Qwen3VL-8B-Instruct-Q4_K_M.gguf
llm models alias general Qwen3.8-27B-UD-Q4_K_M.gguf
llm serve --all --background --no-tools
llm opencode merge
```

`llm opencode config` prints a valid OpenCode V2 configuration snippet. It does
not modify your OpenCode config unless you ask it to:

```bash
llm opencode merge                   # merge into the existing global config
llm opencode config --merge --yes    # non-interactive
llm opencode config --merge --dry-run
llm opencode config --write          # write only if no global config exists
llm opencode config --output FILE    # write or merge at FILE
llm opencode config --model NAME     # one model instead of all
```

`llm opencode merge` merges the generated provider into an existing
`~/.config/opencode/opencode.json` or `opencode.jsonc`:

- unrelated top-level settings are preserved
- unrelated providers and models are preserved
- matching generated model entries are updated
- `settings.baseURL`, `name`, `package`, and `env` are updated when generated
- a timestamped backup is created before writing
- the write is atomic and keeps the original file permissions
- JSONC comments are not preserved in the rewritten file; the backup keeps the
  original

The merge prompts before writing. Use `--yes` for scripts. Use
`--dry-run` to print the merged config without changing anything.

`--write` still refuses to overwrite an existing config and prints the snippet
for manual merging instead.

Merging requires `python3`; the rest of llm-launcher does not.

The generated provider looks like this:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "local": {
      "name": "llama.cpp (local)",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:9931/v1"
      },
      "models": {
        "general": {
          "name": "general (Qwen3.8-27B-UD-Q4_K_M)",
          "modelID": "general",
          "limit": { "context": 64000, "output": 8192 },
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          }
        },
        "coder": {
          "name": "coder (Qwen3VL-8B-Instruct-Q4_K_M)",
          "modelID": "coder",
          "limit": { "context": 64000, "output": 8192 },
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          }
        }
      }
    }
  }
}
```

OpenCode does not auto-discover custom OpenAI-compatible providers, so each
model is listed explicitly. The server still exposes `/v1/models` for clients
that do use discovery.

### API key

If `SERVER_API_KEY` is set, the generated provider uses
`LLM_LOCAL_API_KEY`:

```jsonc
"env": ["LLM_LOCAL_API_KEY"]
```

Export the key in the environment that launches OpenCode:

```bash
export LLM_LOCAL_API_KEY='your-key'
```

Start llm-launcher with the same `SERVER_API_KEY`.

### OpenCode notes

- Use `llm serve --all --no-tools`, not `llm agent`. OpenCode supplies its own
  tools; enabling llama-server's built-in tools creates a second, competing
  tool layer.
- `limit.context` comes from the model profile, or from the global
  `CONTEXT_SIZE` when the model has no profile. llama.cpp reports the model's
  maximum context in `/v1/models`, not the configured value, so OpenCode needs
  this explicitly.
- Tool calling depends on the model's chat template and on `--jinja`, which is
  enabled by default in the current llama.cpp build.
- Changing models in OpenCode may trigger a load and unload cycle. This is
  normal in router mode.

## Agent mode

`llm agent` starts the server with llama.cpp's built-in file tools and opens
the Web UI:

```bash
llm agent
llm agent --workspace ~/Projects/my-app
llm agent --shell                 # also allow shell commands
llm agent --sandbox docker:ubuntu # run tools in a container
llm agent --mcp config/mcp.example.json
```

By default the agent can read files, search with glob/grep, write files, and
edit files. Shell execution is opt-in.

> **Security:** `--agent`/`--tools` grant file read/write access. The server
> binds to loopback by default. Set `SERVER_API_KEY` before binding to a
> non-loopback address.

MCP servers can add tools. See `config/mcp.example.json`.

## Configuration

- `config/config.sh` contains defaults and is never edited by the tools.
- `config/config.local.sh` contains your settings and is gitignored.
- Set values with `llm config set KEY VALUE` or edit them through
  `llm config edit`.
- Per-model overrides live in `config/profiles/<model>.sh` (gitignored; see
  `config/profiles/example.sh`). Manage them with `llm models config`.
- Model aliases are stored as `MODEL_ALIASES="alias=model,..."` in the local
  config. Prefer `llm models alias <alias> <model>` over editing the string by
  hand.

Useful keys:

```text
DEFAULT_MODEL  MODEL_DIR       LLAMA_BIN        LLAMA_SERVER_BIN
MEMORY_DIR     MEMORY_FILE     MEMORY_ENABLED
CONTEXT_SIZE   NGL             THREADS          FLASH_ATTN
DEVICE         SPLIT_MODE      TENSOR_SPLIT     MAIN_GPU
SERVER_HOST    SERVER_PORT     SERVER_API_KEY
SERVER_TOOLS   AGENT_WORKSPACE MCP_CONFIG
SERVER_MODELS_MAX  SERVER_MEMORY_MARGIN  SERVER_START_TIMEOUT
MODEL_ALIASES  OPENCODE_PROVIDER_ID  OPENCODE_MAX_OUTPUT
```

Environment overrides are available for temporary changes:
`LLM_MODEL`, `LLM_CTX`, `LLM_NGL`, `LLM_DEVICE`, `LLM_SPLIT`,
`LLM_TENSOR_SPLIT`, `LLM_THREADS`, `LLM_TEMP`, `LLM_HOST`, `LLM_PORT`.

## Shell completion

```bash
# bash
llm completion bash > ~/.local/share/bash-completion/completions/llm

# zsh
llm completion zsh > "${fpath[1]}/_llm"
```

## Troubleshooting

```bash
llm health
```

This checks the configuration, llama.cpp binaries, models, devices, GPU split
settings, memory file, server/agent paths, and fzf. Also run:

```bash
llm config check
llm devices
llm serve status
llm serve logs
```

If a port is already occupied, `llm serve` refuses to start rather than
attaching to an unrelated process. Stale PID files are detected and removed
automatically. Use `llm serve --port <port>` to run another instance on a
different port.

Re-run `./setup.sh` if a path or build is missing.

## Notes

Backend selection is per build. Switching backends reuses the same
`llama.cpp/build` directory; use `./setup.sh --fresh` if CMake keeps stale
settings.

Device selection depends on the built backend. A CPU-only build reports no
devices, so `llm devices` will be empty.
