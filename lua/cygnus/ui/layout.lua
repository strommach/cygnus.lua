local config = require("cygnus.config")

local M = {}

---@param val number
---@param max_val number
---@return number
local function resolve_size(val, max_val)
  if val > 0 and val <= 1 then
    return math.floor(max_val * val)
  end
  return math.floor(math.min(val, max_val))
end

---@param border string|table|nil
---@return number
local function border_thickness(border)
  if border == nil or border == "none" or border == "" then
    return 0
  end
  return 2
end

---@class CygnusWinGeometry
---@field relative string
---@field row number
---@field col number
---@field width number
---@field height number
---@field border string|table
---@field style string

---@class CygnusFinderLayout
---@field prompt CygnusWinGeometry
---@field results CygnusWinGeometry
---@field preview CygnusWinGeometry|nil
---@field total_width number
---@field total_height number

---Calculate responsive 3-pane floating window geometry for the fuzzy finder.
---@param editor_cols? number
---@param editor_lines? number
---@param opts? table
---@return CygnusFinderLayout
function M.finder(editor_cols, editor_lines, opts)
  local cfg = opts or config.get().finder
  local cols = editor_cols or vim.o.columns
  local lines = editor_lines or (vim.o.lines - vim.o.cmdheight - 1)
  local border = cfg.border or "rounded"
  local b = border_thickness(border)

  local total_w = math.max(36, math.min(cols - 4, resolve_size(cfg.width or 0.86, cols)))
  local total_h = math.max(12, math.min(lines - 4, resolve_size(cfg.height or 0.78, lines)))

  local start_col = math.max(0, math.floor((cols - total_w) / 2))
  local start_row = math.max(0, math.floor((lines - total_h) / 2))

  -- Prompt occupies 1 content line + border thickness
  local prompt_h = 1
  local prompt_total_h = prompt_h + b
  local body_row = start_row + prompt_total_h
  local body_h = math.max(6, total_h - prompt_total_h - b)

  local prompt = {
    relative = "editor",
    row = start_row,
    col = start_col,
    width = math.max(20, total_w - b),
    height = prompt_h,
    border = border,
    style = "minimal",
  }

  local show_preview = total_w >= (cfg.min_preview_cols or 84)
  if not show_preview then
    local results = {
      relative = "editor",
      row = body_row,
      col = start_col,
      width = math.max(20, total_w - b),
      height = body_h,
      border = border,
      style = "minimal",
    }
    return {
      prompt = prompt,
      results = results,
      preview = nil,
      total_width = total_w,
      total_height = total_h,
    }
  end

  local gap = 1
  local preview_ratio = cfg.preview_ratio or 0.56
  local available_w = total_w - (2 * b) - gap
  local preview_w = math.max(24, math.floor(available_w * preview_ratio))
  local results_w = math.max(20, available_w - preview_w)

  local results = {
    relative = "editor",
    row = body_row,
    col = start_col,
    width = results_w,
    height = body_h,
    border = border,
    style = "minimal",
  }

  local preview = {
    relative = "editor",
    row = body_row,
    col = start_col + results_w + b + gap,
    width = preview_w,
    height = body_h,
    border = border,
    style = "minimal",
  }

  return {
    prompt = prompt,
    results = results,
    preview = preview,
    total_width = total_w,
    total_height = total_h,
  }
end

---Calculate centered floating window geometry for compact/short documentation.
---@param content_lines string[]
---@param editor_cols? number
---@param editor_lines? number
---@param opts? table
---@return CygnusWinGeometry
function M.short_float(content_lines, editor_cols, editor_lines, opts)
  local cfg = opts or config.get().doc_view
  local cols = editor_cols or vim.o.columns
  local lines = editor_lines or (vim.o.lines - vim.o.cmdheight - 1)
  local border = cfg.short_border or "rounded"
  local b = border_thickness(border)

  local max_line_w = 40
  for _, l in ipairs(content_lines) do
    local w = vim.fn.strdisplaywidth(l)
    if w > max_line_w then
      max_line_w = w
    end
  end

  local max_w = math.min(cfg.short_max_width or 88, cols - 4 - b)
  local max_h = math.min(cfg.short_max_height or 24, lines - 4 - b)

  local width = math.max(36, math.min(max_line_w + 2, max_w))
  local height = math.max(5, math.min(#content_lines, max_h))

  local row = math.max(0, math.floor((lines - height - b) / 2))
  local col = math.max(0, math.floor((cols - width - b) / 2))

  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = border,
    style = "minimal",
  }
end

return M
