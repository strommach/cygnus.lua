local cache = require("cygnus.cache")
local config = require("cygnus.config")
local highlights = require("cygnus.highlights")

local M = {}

---Extract symbol under cursor, preserving C++ scope resolution (e.g. `std::vector`).
---@return string
function M.symbol_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed byte position
  if col < 1 or col > #line then
    return vim.fn.expand("<cword>")
  end

  local is_sym_char = function(ch)
    return ch ~= "" and ch:match("[%w_:]") ~= nil
  end

  if not is_sym_char(line:sub(col, col)) then
    return vim.fn.expand("<cword>")
  end

  local s = col
  while s > 1 and is_sym_char(line:sub(s - 1, s - 1)) do
    s = s - 1
  end
  local e = col
  while e < #line and is_sym_char(line:sub(e + 1, e + 1)) do
    e = e + 1
  end

  local token = line:sub(s, e):gsub("^:+", ""):gsub(":+$", "")
  if token == "" then
    return vim.fn.expand("<cword>")
  end
  return token
end

---Configure cygnus.lua with optional user overrides.
---@param opts? table
---@return CygnusConfig
function M.setup(opts)
  local cfg = config.setup(opts)
  highlights.setup()
  return cfg
end

---Open the floating fuzzy finder window.
---@param opts? { query?: string, source?: "c"|"posix"|"cpp"|nil }
function M.open(opts)
  require("cygnus.ui.finder").open(opts)
end

---Alias for `open()` — quick apropos/fuzzy search in a floating window.
M.search = M.open

---Look up documentation for a symbol.
---By default opens full man-page docs in a split (configurable split/vsplit).
---Pass `{ short = true }` to display compact docs in a floating window.
---@param symbol string
---@param opts? { source?: "c"|"posix"|"cpp"|nil, short?: boolean, split?: "split"|"vsplit" }
function M.lookup(symbol, opts)
  opts = opts or {}
  if not symbol or vim.trim(symbol) == "" then
    vim.notify("cygnus.lua: symbol name is required", vim.log.levels.WARN)
    return
  end
  local doc_view = require("cygnus.ui.doc_view")
  if opts.short then
    doc_view.open_short(symbol, opts)
  else
    doc_view.open_full(symbol, opts)
  end
end

---Look up compact documentation for a symbol in a floating window.
---@param symbol string
---@param opts? { source?: "c"|"posix"|"cpp"|nil }
function M.lookup_short(symbol, opts)
  opts = vim.tbl_extend("force", opts or {}, { short = true })
  M.lookup(symbol, opts)
end

---Look up documentation for the symbol under the cursor.
---@param opts? { source?: "c"|"posix"|"cpp"|nil, short?: boolean, split?: "split"|"vsplit" }
function M.lookup_cword(opts)
  local sym = M.symbol_under_cursor()
  if not sym or sym == "" then
    vim.notify("cygnus.lua: no symbol under cursor", vim.log.levels.WARN)
    return
  end
  M.lookup(sym, opts)
end

---Close active floating finder and compact doc float.
function M.close()
  require("cygnus.ui.finder").close()
  require("cygnus.ui.doc_view").close_short()
end

---Clear in-memory symbol and documentation cache.
function M.clear_cache()
  cache.clear()
end

return M
