# Custom LLM launcher using llama.cpp

## How to set up
right now only works if it's in your home directory (gonna fix later)

run:
```bash
./install.sh
```
and go through the prompts. You can change your models directory later, and installing the default model is not required. I reccomending putting llm-launcher in your path or symlinking to your /usr/bin so you can use the "llm" command anywhere.

```bash
sudo ln -s ~/llm-launcher/llm /usr/local/bin/llm
```
<small>This will create a symlink so you can use the "llm" command anywhere.</small>
```bash
export PATH="$HOME/llm-launcher:$PATH"
```
<small>This adds llm-launcher to your path</small>

### Usage
llm {config|launch}
llm config {edit|show}
llm launch (Launches default model)
llm launch select (opens a fzf menu and you select a model which will be launched.)

## Features
Automatic install, fzf menus. You can select a model directory, which gpu to use (if you have multiple), context size, default model, and more.

## Notes

There are still some bugs. If anybody actually uses this then please make some issues I just know it won't work on some random guy's system
