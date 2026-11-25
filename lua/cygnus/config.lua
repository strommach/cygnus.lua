---@class CygnusFinderConfig
---@field width number Fraction of editor columns (0.0 - 1.0) or absolute columns (> 1)
---@field height number Fraction of editor lines (0.0 - 1.0) or absolute lines (> 1)
---@field border string|table Floating window border style
---@field prompt_prefix string Prefix shown in the prompt buffer
---@field limit number Maximum results returned per query/list
---@field debounce_ms number Debounce delay in milliseconds for live search
---@field preview_debounce_ms number Debounce delay in milliseconds for preview updates
---@field preview_ratio number Width fraction allocated to preview pane (0.0 - 1.0)
---@field min_preview_cols number Minimum total columns required to show the preview pane

---@class CygnusDocViewConfig
---@field split "split"|"vsplit" Split direction for full/man-style documentation
---@field split_size number Fraction (0.0 - 1.0) or absolute rows/cols (> 1) for split
---@field short_border string|table Floating window border for short/quick docs
---@field short_max_width number Maximum width for short doc floating window
---@field short_max_height number Maximum height for short doc floating window

---@class CygnusKeymapsConfig
---@field next string[] Move selection down
---@field prev string[] Move selection up
---@field scroll_preview_down string[] Scroll preview down
---@field scroll_preview_up string[] Scroll preview up
---@field cycle_source string[] Cycle source filter (all -> c -> posix -> cpp)
---@field select string[] Open full documentation in a split
---@field select_short string[] Open compact documentation in a floating window
---@field yank_header string[] Yank #include <header> to register
---@field close string[] Close the finder

---@class CygnusConfig
---@field cmd string Path or name of the cygnus binary
---@field db_path string|nil Optional explicit path to cygnus.db
---@field default_source "c"|"posix"|"cpp"|nil Default source filter (nil = all)
---@field cache_max_entries number Maximum cached symbol doc entries
---@field finder CygnusFinderConfig
---@field doc_view CygnusDocViewConfig
---@field keymaps CygnusKeymapsConfig

local M = {}

---@type CygnusConfig
M.defaults = {
  cmd = "cygnus",
  db_path = nil,
  default_source = nil,
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
    split = "split",
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
}

---@type CygnusConfig
M.options = vim.deepcopy(M.defaults)

local VALID_SOURCES = { c = true, posix = true, cpp = true }
local VALID_SPLITS = { split = true, vsplit = true }

---@param opts CygnusConfig
local function validate(opts)
  if type(opts.cmd) ~= "string" or opts.cmd == "" then
    error("cygnus.lua: 'cmd' must be a non-empty string")
  end
  if opts.db_path ~= nil and (type(opts.db_path) ~= "string" or opts.db_path == "") then
    error("cygnus.lua: 'db_path' must be nil or a non-empty string")
  end
  if opts.default_source ~= nil and not VALID_SOURCES[opts.default_source] then
    error("cygnus.lua: 'default_source' must be nil, 'c', 'posix', or 'cpp'")
  end
  if not VALID_SPLITS[opts.doc_view.split] then
    error("cygnus.lua: 'doc_view.split' must be 'split' or 'vsplit'")
  end
  if type(opts.finder.limit) ~= "number" or opts.finder.limit < 1 then
    error("cygnus.lua: 'finder.limit' must be a positive number")
  end
  if type(opts.finder.debounce_ms) ~= "number" or opts.finder.debounce_ms < 0 then
    error("cygnus.lua: 'finder.debounce_ms' must be >= 0")
  end
end

---@param user_opts table|nil
---@return CygnusConfig
function M.setup(user_opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  validate(merged)
  M.options = merged
  return M.options
end

---@return CygnusConfig
function M.get()
  return M.options
end

return M
