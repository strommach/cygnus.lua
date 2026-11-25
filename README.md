# cygnus.lua

A pure-Lua, zero-dependency Neovim plugin for blazingly fast offline C, C++, and POSIX documentation search powered by [`cygnus`](https://github.com/neurd/cygnus).

## Features

- **Blazingly fast async search**: Non-blocking `vim.system()` execution with debouncing, in-flight process cancellation, and in-memory session caching.
- **3-pane floating fuzzy finder**: Live prompt, color-coded symbol list (`[c]`, `[posix]`, `[cpp]`), and live documentation preview that adapts to terminal size.
- **Instant source filter cycling**: Defaults to `[ALL]` and cycles `ALL → C → POSIX → C++` with `<Tab>`.
- **Smart display modes**:
  - Fuzzy / apropos search and compact (`--short`) lookups open in **floating windows**.
  - Full man-page style documentation opens in a **configurable split** (`split` or `vsplit`) with `SEE ALSO` jump navigation and history.
- **C++ scope-aware cursor lookup**: Extracts `std::vector`, `pthread_create`, etc. directly from under your cursor.
- **Zero external plugin dependencies**: Uses only Neovim `>= 0.10` built-in APIs.

## Requirements

- Neovim `>= 0.10`
- `cygnus` CLI installed in `$PATH` with a populated `cygnus.db`

Run `:checkhealth cygnus` after installation to verify your setup.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "neurd/cygnus.lua",
  cmd = { "Cygnus", "CygnusLookup", "CygnusShort" },
  keys = {
    { "<leader>cd", "<cmd>Cygnus<cr>", desc = "Cygnus: Search docs" },
    { "<leader>ck", function() require("cygnus").lookup_cword() end, desc = "Cygnus: Full doc under cursor" },
    { "<leader>cs", function() require("cygnus").lookup_cword({ short = true }) end, desc = "Cygnus: Short doc under cursor" },
  },
  opts = {
    doc_view = {
      split = "vsplit", -- "split" (default) or "vsplit"
    },
  },
}
```

## Configuration

```lua
require("cygnus").setup({
  cmd = "cygnus",
  db_path = nil,          -- optional explicit path to cygnus.db
  default_source = nil,   -- nil = ALL, or "c" | "posix" | "cpp"
  cache_max_entries = 256,
  finder = {
    width = 0.86,
    height = 0.78,
    border = "rounded",
    prompt_prefix = " > ",
    limit = 40,
    debounce_ms = 40,
    preview_debounce_ms = 20,
    preview_ratio = 0.56,
    min_preview_cols = 84,
  },
  doc_view = {
    split = "split",      -- "split" or "vsplit" for full/man docs
    split_size = 0.45,
    short_border = "rounded",
    short_max_width = 88,
    short_max_height = 24,
  },
  keymaps = {
    next = { "<C-j>", "<C-n>", "<Down>" },
    prev = { "<C-k>", "<C-p>", "<Up>" },
    scroll_preview_down = { "<C-d>" },
    scroll_preview_up = { "<C-u>" },
    cycle_source = { "<Tab>" },
    select = { "<CR>" },
    select_short = { "<C-s>" },
    yank_header = { "<C-y>" },
    close = { "<Esc>", "<C-c>" },
  },
})
```

## Usage

### Commands

| Command | Description |
|---|---|
| `:Cygnus [--c\|--posix\|--cpp] [query...]` | Open the floating fuzzy finder (optionally prefilled) |
| `:CygnusLookup [--c\|--posix\|--cpp] [--split\|--vsplit] [--short] [symbol]` | Open full doc in a split (or float with `--short`); defaults to symbol under cursor |
| `:CygnusShort [--c\|--posix\|--cpp] [symbol]` | Open compact doc in a floating window; defaults to symbol under cursor |

### Default Keymaps

**Inside the fuzzy finder:**

| Key | Action |
|---|---|
| `<C-j>` / `<C-n>` / `<Down>` | Next result |
| `<C-k>` / `<C-p>` / `<Up>` | Previous result |
| `<C-d>` / `<C-u>` | Scroll documentation preview down / up |
| `<Tab>` | Cycle source filter (`ALL → C → POSIX → C++`) |
| `<CR>` | Open full documentation in a split |
| `<C-s>` | Open compact documentation in a floating window |
| `<C-y>` | Yank `#include <header>` |
| `<Esc>` / `<C-c>` | Close finder |

**Inside the full documentation split:**

| Key | Action |
|---|---|
| `<CR>` / `K` | Jump to symbol under cursor / `SEE ALSO` entry |
| `<C-o>` / `<BS>` | Navigate back in documentation history |
| `y` | Yank `#include <header>` |
| `q` | Close split |

**Inside the compact floating window:**

| Key | Action |
|---|---|
| `<CR>` | Expand into full documentation split |
| `y` | Yank `#include <header>` |
| `q` / `<Esc>` | Close floating window |

## Testing

```sh
nvim --headless -u tests/minimal_init.lua -l tests/run_tests.lua
```
