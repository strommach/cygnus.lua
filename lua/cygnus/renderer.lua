local highlights = require("cygnus.highlights")

local M = {}

---@class CygnusHighlightSpan
---@field line number 0-indexed line number
---@field col_start number 0-indexed byte start
---@field col_end number 0-indexed byte end (-1 for end of line)
---@field hl_group string

---@class CygnusSeeAlsoLink
---@field col_start number 0-indexed byte start
---@field col_end number 0-indexed byte end
---@field symbol string

---@class CygnusRenderedDoc
---@field lines string[]
---@field highlights CygnusHighlightSpan[]
---@field see_also table<number, CygnusSeeAlsoLink[]> 1-indexed line -> links

local SOURCE_LABELS = {
  c = "C Standard Library",
  posix = "POSIX Programmer's Manual",
  cpp = "C++ Standard Library",
}

---@param text string|nil
---@param max_len number
---@return string
function M.truncate_one_line(text, max_len)
  if not text or text == "" then
    return ""
  end
  local flat = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #flat <= max_len then
    return flat
  end
  if max_len <= 3 then
    return flat:sub(1, max_len)
  end
  return flat:sub(1, max_len - 3):gsub("%s+$", "") .. "..."
end

---@param lines string[]
---@param hl_list CygnusHighlightSpan[]
---@param text string
---@param hl_group string|nil
local function push_line(lines, hl_list, text, hl_group)
  local line_idx = #lines
  table.insert(lines, text)
  if hl_group and text ~= "" then
    table.insert(hl_list, {
      line = line_idx,
      col_start = 0,
      col_end = -1,
      hl_group = hl_group,
    })
  end
end

---@param lines string[]
---@param hl_list CygnusHighlightSpan[]
---@param heading string
---@param body string|nil
---@param body_hl string|nil
local function push_section(lines, hl_list, heading, body, body_hl)
  if not body or body == "" then
    return
  end
  push_line(lines, hl_list, heading, "CygnusSection")
  local split_lines = vim.split(body, "\n", { plain = true })
  for _, raw in ipairs(split_lines) do
    local line = raw ~= "" and ("    " .. raw) or ""
    push_line(lines, hl_list, line, body_hl)
  end
  push_line(lines, hl_list, "", nil)
end

---@param doc table
---@param lines string[]
---@param hl_list CygnusHighlightSpan[]
local function push_alternatives(doc, lines, hl_list)
  local alts = doc.alternatives
  if type(alts) ~= "table" or #alts == 0 then
    return
  end
  local parts = {}
  for _, alt in ipairs(alts) do
    table.insert(parts, string.format("--%s (%s)", alt.source or "", alt.name or ""))
  end
  push_line(lines, hl_list, "Also available in: " .. table.concat(parts, ", "), "CygnusHint")
end

---Render full man-page style documentation from a cygnus JSON lookup payload.
---@param doc table
---@param opts? { width?: number }
---@return CygnusRenderedDoc
function M.render_full(doc, opts)
  opts = opts or {}
  local width = opts.width or 78
  local lines = {}
  local hl_list = {}
  local see_also = {}

  local name = doc.name or ""
  local source = doc.source or "c"
  local sec_tag = (doc.section and doc.section ~= "") and doc.section or source
  local title = string.upper(name) .. "(" .. sec_tag .. ")"
  local center = SOURCE_LABELS[source] or source
  if doc.standard and doc.standard ~= "" then
    center = center .. " (" .. doc.standard .. ")"
  end

  local content_len = (#title * 2) + #center
  if content_len + 4 <= width then
    local total_pad = width - content_len
    local left_pad = math.floor(total_pad / 2)
    local right_pad = total_pad - left_pad
    local header_line = title .. string.rep(" ", left_pad) .. center .. string.rep(" ", right_pad) .. title
    local line_idx = #lines
    table.insert(lines, header_line)
    table.insert(hl_list, { line = line_idx, col_start = 0, col_end = #title, hl_group = "CygnusTitle" })
    table.insert(hl_list, {
      line = line_idx,
      col_start = #title + left_pad,
      col_end = #title + left_pad + #center,
      hl_group = "CygnusStandard",
    })
    table.insert(hl_list, {
      line = line_idx,
      col_start = #header_line - #title,
      col_end = #header_line,
      hl_group = "CygnusTitle",
    })
  else
    local header_line = title .. "  " .. center
    local line_idx = #lines
    table.insert(lines, header_line)
    table.insert(hl_list, { line = line_idx, col_start = 0, col_end = #title, hl_group = "CygnusTitle" })
    table.insert(hl_list, { line = line_idx, col_start = #title + 2, col_end = -1, hl_group = "CygnusStandard" })
  end
  push_line(lines, hl_list, "", nil)

  -- NAME
  push_line(lines, hl_list, "NAME", "CygnusSection")
  local name_line = "    " .. name
  local name_line_idx = #lines
  if doc.summary and doc.summary ~= "" then
    name_line = name_line .. " - " .. doc.summary
  end
  table.insert(lines, name_line)
  table.insert(hl_list, { line = name_line_idx, col_start = 4, col_end = 4 + #name, hl_group = "CygnusSymbol" })
  push_line(lines, hl_list, "", nil)

  -- HEADER
  push_section(lines, hl_list, "HEADER", doc.header, "CygnusHeader")

  -- SYNOPSIS
  push_section(lines, hl_list, "SYNOPSIS", doc.synopsis, "CygnusSynopsis")

  -- DESCRIPTION
  push_section(lines, hl_list, "DESCRIPTION", doc.description, nil)

  -- PARAMETERS
  push_section(lines, hl_list, "PARAMETERS", doc.parameters, nil)

  -- RETURN VALUE
  push_section(lines, hl_list, "RETURN VALUE", doc.return_value, nil)

  -- ERRORS / EXCEPTIONS
  local err_heading = source == "cpp" and "EXCEPTIONS" or "ERRORS"
  push_section(lines, hl_list, err_heading, doc.errors, nil)

  -- SEE ALSO
  if type(doc.see_also) == "table" and #doc.see_also > 0 then
    push_line(lines, hl_list, "SEE ALSO", "CygnusSection")
    local line_idx = #lines
    local line_num_1based = line_idx + 1
    local parts = {}
    local links = {}
    local col = 4
    for i, ref in ipairs(doc.see_also) do
      if i > 1 then
        table.insert(parts, ", ")
        col = col + 2
      end
      local start_col = col
      local end_col = col + #ref
      table.insert(parts, ref)
      table.insert(hl_list, { line = line_idx, col_start = start_col, col_end = end_col, hl_group = "CygnusSeeAlso" })
      table.insert(links, { col_start = start_col, col_end = end_col, symbol = ref })
      col = end_col
    end
    table.insert(lines, "    " .. table.concat(parts))
    see_also[line_num_1based] = links
    push_line(lines, hl_list, "", nil)
  end

  push_alternatives(doc, lines, hl_list)

  -- Trim trailing blank line for cleaner display
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end

  return {
    lines = lines,
    highlights = hl_list,
    see_also = see_also,
  }
end

---Render compact documentation (ideal for quick floating windows).
---@param doc table
---@return CygnusRenderedDoc
function M.render_short(doc)
  local lines = {}
  local hl_list = {}

  local name = doc.name or ""
  local source = doc.source or "c"
  local badge = "[" .. source .. "]"
  local header_line = name .. " " .. badge
  local line_idx = #lines

  local std_start = nil
  if doc.standard and doc.standard ~= "" then
    std_start = #header_line + 1
    header_line = header_line .. " (" .. doc.standard .. ")"
  end

  table.insert(lines, header_line)
  table.insert(hl_list, { line = line_idx, col_start = 0, col_end = #name, hl_group = "CygnusSymbol" })
  table.insert(hl_list, {
    line = line_idx,
    col_start = #name + 1,
    col_end = #name + 1 + #badge,
    hl_group = highlights.source_hl(source),
  })
  if std_start then
    table.insert(hl_list, { line = line_idx, col_start = std_start, col_end = -1, hl_group = "CygnusStandard" })
  end
  push_line(lines, hl_list, "", nil)

  push_section(lines, hl_list, "Header:", doc.header, "CygnusHeader")
  push_section(lines, hl_list, "Synopsis:", doc.synopsis, "CygnusSynopsis")

  if doc.summary and doc.summary ~= "" then
    for _, raw in ipairs(vim.split(doc.summary, "\n", { plain = true })) do
      push_line(lines, hl_list, raw, nil)
    end
    push_line(lines, hl_list, "", nil)
  end

  push_alternatives(doc, lines, hl_list)

  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end

  return {
    lines = lines,
    highlights = hl_list,
    see_also = {},
  }
end

---Format a single result row for the fuzzy finder results list.
---@param entry table
---@param name_width number
---@param is_selected boolean
---@return { text: string, highlights: CygnusHighlightSpan[] }
function M.render_result_line(entry, name_width, is_selected)
  local hl_list = {}
  local prefix = is_selected and "> " or "  "
  local name = entry.name or ""
  local display_name = #name > name_width and (name:sub(1, math.max(1, name_width - 1)) .. "…") or name
  local pad = string.rep(" ", math.max(0, name_width - #display_name))
  local source = entry.source or "c"
  local badge = "[" .. source .. "]"
  local header = (entry.header and entry.header ~= "") and (" " .. entry.header) or ""

  local text = prefix .. display_name .. pad .. " " .. badge .. header

  local col = 0
  if is_selected then
    table.insert(hl_list, { line = 0, col_start = 0, col_end = #prefix, hl_group = "CygnusSelectionCaret" })
  end
  col = #prefix

  table.insert(hl_list, { line = 0, col_start = col, col_end = col + #display_name, hl_group = "CygnusSymbol" })
  col = col + #display_name + #pad + 1

  table.insert(hl_list, { line = 0, col_start = col, col_end = col + #badge, hl_group = highlights.source_hl(source) })
  col = col + #badge

  if header ~= "" then
    table.insert(hl_list, { line = 0, col_start = col + 1, col_end = col + #header, hl_group = "CygnusHeader" })
  end

  return {
    text = text,
    highlights = hl_list,
  }
end

---Apply rendered lines and highlight spans to a scratch buffer.
---@param bufnr number
---@param rendered CygnusRenderedDoc
---@param ns_id number
function M.apply(bufnr, rendered, ns_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered.lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  local line_count = #rendered.lines
  for _, span in ipairs(rendered.highlights) do
    if span.line >= 0 and span.line < line_count then
      local line_len = #rendered.lines[span.line + 1]
      local end_col = span.col_end == -1 and line_len or math.min(span.col_end, line_len)
      local start_col = math.min(span.col_start, end_col)
      if end_col > start_col then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, span.line, start_col, {
          end_row = span.line,
          end_col = end_col,
          hl_group = span.hl_group,
        })
      end
    end
  end
end

return M
