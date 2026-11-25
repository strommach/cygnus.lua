local cache = require("cygnus.cache")
local client = require("cygnus.client")
local config = require("cygnus.config")
local highlights = require("cygnus.highlights")
local layout = require("cygnus.ui.layout")
local renderer = require("cygnus.renderer")

local M = {}

local NS_DOC = vim.api.nvim_create_namespace("cygnus_doc_view")

local state = {
  split_win = nil,
  split_buf = nil,
  split_history = {},
  split_current = nil,
  split_see_also = {},
  short_win = nil,
  short_buf = nil,
}

---@param win number|nil
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param buf number|nil
---@return boolean
local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param header string|nil
---@return string|nil
local function format_include(header)
  if not header or header == "" then
    return nil
  end
  local out = {}
  for part in header:gmatch("[^,]+") do
    local trimmed = vim.trim(part)
    if trimmed ~= "" then
      if trimmed:match("^<.+>$") or trimmed:match('^".+"$') then
        table.insert(out, "#include " .. trimmed)
      else
        table.insert(out, "#include <" .. trimmed .. ">")
      end
    end
  end
  return #out > 0 and table.concat(out, "\n") or nil
end

---@param doc table|nil
local function yank_doc_header(doc)
  if not doc then
    return
  end
  local inc = format_include(doc.header)
  if not inc then
    vim.notify("cygnus.lua: no header listed for " .. (doc.name or "symbol"), vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('"', inc)
  pcall(vim.fn.setreg, "+", inc)
  vim.notify("Yanked: " .. inc:gsub("\n", " "), vim.log.levels.INFO)
end

---@param err CygnusClientError
---@return CygnusRenderedDoc
local function render_error_doc(err)
  local lines = { err.message or "Documentation not found." }
  local hl_list = {
    { line = 0, col_start = 0, col_end = -1, hl_group = "CygnusError" },
  }
  local see_also = {}

  if err.suggestions and #err.suggestions > 0 then
    table.insert(lines, "")
    table.insert(lines, "Did you mean:")
    table.insert(hl_list, { line = 2, col_start = 0, col_end = -1, hl_group = "CygnusSection" })
    for _, s in ipairs(err.suggestions) do
      local idx = #lines
      local name = s.name or ""
      local src = s.source and (" [" .. s.source .. "]") or ""
      local summary = (s.summary and s.summary ~= "") and (" - " .. renderer.truncate_one_line(s.summary, 64)) or ""
      table.insert(lines, "  " .. name .. src .. summary)
      table.insert(hl_list, { line = idx, col_start = 2, col_end = 2 + #name, hl_group = "CygnusSeeAlso" })
      see_also[idx + 1] = {
        { col_start = 2, col_end = 2 + #name, symbol = name },
      }
    end
  end

  return {
    lines = lines,
    highlights = hl_list,
    see_also = see_also,
  }
end

---@param symbol string
---@return string
local function normalize_symbol(symbol)
  return (symbol:gsub("^%s*struct%s+", "")
    :gsub("^%s*enum%s+", "")
    :gsub("^%s*union%s+", "")
    :gsub("^%s*class%s+", "")
    :gsub("^%s+", "")
    :gsub("%s+$", ""))
end

---@param symbol string
---@param source string|nil
---@param cb fun(err: CygnusClientError|nil, doc: table|nil)
local function fetch_doc(symbol, source, cb)
  local normalized = normalize_symbol(symbol)
  local query = normalized ~= "" and normalized or symbol

  local cached = cache.get_doc(query, source)
  if cached then
    cb(nil, cached)
    return
  end
  client.lookup(query, { source = source }, function(err, doc)
    if not err and doc then
      cache.set_doc(query, source, doc)
      cb(nil, doc)
      return
    end
    if source == "c" and err and err.kind == "not_found" then
      client.lookup(query, { source = nil }, function(fb_err, fb_doc)
        if not fb_err and fb_doc then
          cache.set_doc(query, nil, fb_doc)
          cb(nil, fb_doc)
          return
        end
        cb(err, nil)
      end)
      return
    end
    cb(err, doc)
  end)
end

---@param split_mode "split"|"vsplit"
---@return number, number
local function ensure_split_window(split_mode)
  local cfg = config.get().doc_view

  if valid_win(state.split_win) and valid_buf(state.split_buf) then
    vim.api.nvim_set_current_win(state.split_win)
    return state.split_win, state.split_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "cygnus_doc"
  vim.bo[buf].modifiable = false

  if split_mode == "vsplit" then
    vim.cmd("botright vsplit")
    local win = vim.api.nvim_get_current_win()
    local size = cfg.split_size or 0.45
    local width = size <= 1 and math.floor(vim.o.columns * size) or math.floor(size)
    vim.api.nvim_win_set_width(win, math.max(40, width))
    vim.api.nvim_win_set_buf(win, buf)
    state.split_win = win
  else
    vim.cmd("botright split")
    local win = vim.api.nvim_get_current_win()
    local size = cfg.split_size or 0.45
    local height = size <= 1 and math.floor(vim.o.lines * size) or math.floor(size)
    vim.api.nvim_win_set_height(win, math.max(10, height))
    vim.api.nvim_win_set_buf(win, buf)
    state.split_win = win
  end

  state.split_buf = buf

  local win = state.split_win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldcolumn = "0"

  -- Keymaps for full doc buffer
  vim.keymap.set("n", "q", function()
    if valid_win(state.split_win) then
      pcall(vim.api.nvim_win_close, state.split_win, true)
    end
    state.split_win = nil
    state.split_buf = nil
    state.split_history = {}
    state.split_current = nil
  end, { buffer = buf, nowait = true, silent = true, desc = "Close Cygnus doc split" })

  vim.keymap.set("n", "y", function()
    yank_doc_header(state.split_current and state.split_current.doc or nil)
  end, { buffer = buf, nowait = true, silent = true, desc = "Yank #include header" })

  local function jump_to_ref()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1], cursor[2]
    local links = state.split_see_also[row]
    local target = nil
    if links then
      for _, link in ipairs(links) do
        if col >= link.col_start and col <= link.col_end then
          target = link.symbol
          break
        end
      end
      if not target and #links == 1 then
        target = links[1].symbol
      end
    end
    if not target then
      target = vim.fn.expand("<cword>")
    end
    if target and target ~= "" then
      M.open_full(target, {
        source = state.split_current and state.split_current.source or nil,
        push_history = true,
      })
    end
  end

  vim.keymap.set("n", "<CR>", jump_to_ref, { buffer = buf, nowait = true, silent = true, desc = "Open symbol under cursor" })
  vim.keymap.set("n", "K", jump_to_ref, { buffer = buf, nowait = true, silent = true, desc = "Open symbol under cursor" })

  local function go_back()
    local prev = table.remove(state.split_history)
    if prev then
      M.open_full(prev.symbol, { source = prev.source, push_history = false })
    end
  end

  vim.keymap.set("n", "<C-o>", go_back, { buffer = buf, nowait = true, silent = true, desc = "Previous Cygnus doc" })
  vim.keymap.set("n", "<BS>", go_back, { buffer = buf, nowait = true, silent = true, desc = "Previous Cygnus doc" })

  return state.split_win, state.split_buf
end

---Open full man-page style documentation in a configurable split (split or vsplit).
---@param symbol string
---@param opts? { source?: string|nil, split?: "split"|"vsplit", push_history?: boolean }
function M.open_full(symbol, opts)
  opts = opts or {}
  highlights.setup()

  if opts.push_history and state.split_current and state.split_current.symbol ~= symbol then
    table.insert(state.split_history, {
      symbol = state.split_current.symbol,
      source = state.split_current.source,
    })
  end

  local split_mode = opts.split or config.get().doc_view.split or "split"
  local win, buf = ensure_split_window(split_mode)

  renderer.apply(buf, {
    lines = { "Loading documentation for " .. symbol .. "..." },
    highlights = { { line = 0, col_start = 0, col_end = -1, hl_group = "CygnusHint" } },
    see_also = {},
  }, NS_DOC)

  fetch_doc(symbol, opts.source, function(err, doc)
    if not valid_buf(buf) then
      return
    end
    if err or not doc then
      local rendered = render_error_doc(err or { code = 1, kind = "not_found", message = "Not found" })
      state.split_see_also = rendered.see_also
      state.split_current = { symbol = symbol, source = opts.source, doc = nil }
      renderer.apply(buf, rendered, NS_DOC)
      return
    end

    local width = valid_win(win) and (vim.api.nvim_win_get_width(win) - 2) or 78
    local rendered = renderer.render_full(doc, { width = width })
    state.split_see_also = rendered.see_also
    state.split_current = { symbol = doc.name or symbol, source = doc.source or opts.source, doc = doc }
    renderer.apply(buf, rendered, NS_DOC)
    if valid_win(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end
  end)
end

---Close any active compact floating documentation window.
function M.close_short()
  if valid_win(state.short_win) then
    pcall(vim.api.nvim_win_close, state.short_win, true)
  end
  if valid_buf(state.short_buf) then
    pcall(vim.api.nvim_buf_delete, state.short_buf, { force = true })
  end
  state.short_win = nil
  state.short_buf = nil
end

---Open compact (--short style) documentation in a floating window.
---@param symbol string
---@param opts? { source?: string|nil }
function M.open_short(symbol, opts)
  opts = opts or {}
  highlights.setup()
  M.close_short()

  fetch_doc(symbol, opts.source, function(err, doc)
    local rendered
    local title_text
    if err or not doc then
      rendered = render_error_doc(err or { code = 1, kind = "not_found", message = "Not found" })
      title_text = " Cygnus: " .. symbol .. " "
    else
      rendered = renderer.render_short(doc)
      title_text = " Cygnus: " .. (doc.name or symbol) .. " "
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "cygnus_short"
    vim.bo[buf].modifiable = false

    renderer.apply(buf, rendered, NS_DOC)

    local geom = layout.short_float(rendered.lines)
    local win_cfg = vim.tbl_extend("force", geom, {
      title = { { title_text, "CygnusTitle" } },
      title_pos = "left",
      footer = { { " <CR> full docs | y yank header | q close ", "CygnusPromptCounter" } },
      footer_pos = "right",
    })

    local win = vim.api.nvim_open_win(buf, true, win_cfg)
    vim.wo[win].winhighlight = "Normal:CygnusNormal,FloatBorder:CygnusBorder"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true

    state.short_win = win
    state.short_buf = buf

    vim.keymap.set("n", "q", M.close_short, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", M.close_short, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "y", function()
      yank_doc_header(doc)
    end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<CR>", function()
      local target_name = (doc and doc.name) or symbol
      local target_src = (doc and doc.source) or opts.source
      M.close_short()
      M.open_full(target_name, { source = target_src })
    end, { buffer = buf, nowait = true, silent = true })
  end)
end

return M
