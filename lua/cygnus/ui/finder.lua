local cache = require("cygnus.cache")
local client = require("cygnus.client")
local config = require("cygnus.config")
local highlights = require("cygnus.highlights")
local layout = require("cygnus.ui.layout")
local renderer = require("cygnus.renderer")

local M = {}

local NS_PROMPT = vim.api.nvim_create_namespace("cygnus_finder_prompt")
local NS_RESULTS = vim.api.nvim_create_namespace("cygnus_finder_results")
local NS_PREVIEW = vim.api.nvim_create_namespace("cygnus_finder_preview")

local SOURCE_CYCLE = { false, "c", "posix", "cpp" }
local SOURCE_BADGE = {
  all = "ALL",
  c = "C",
  posix = "POSIX",
  cpp = "C++",
}

local active_session = nil

---@param source string|nil
---@return string
local function source_label(source)
  return SOURCE_BADGE[source or "all"] or "ALL"
end

---@param source string|nil
---@return string|nil
local function next_source(source)
  local current = source or false
  for i, val in ipairs(SOURCE_CYCLE) do
    if val == current then
      local nxt = SOURCE_CYCLE[(i % #SOURCE_CYCLE) + 1]
      return nxt or nil
    end
  end
  return nil
end

---@param header string|nil
---@return string|nil
local function format_include_lines(header)
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
  if #out == 0 then
    return nil
  end
  return table.concat(out, "\n")
end

---@param timer uv.uv_timer_t|nil
local function stop_timer(timer)
  if timer and not timer:is_closing() then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

---@param buf number|nil
---@return boolean
local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param win number|nil
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param name string
---@return number
local function create_scratch_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = name
  return buf
end

---@param session table
---@param status_text? string
local function update_prompt_chrome(session, status_text)
  if not valid_win(session.prompt_win) then
    return
  end

  local badge = "[" .. source_label(session.source) .. "]"
  local title = {
    { " Cygnus Docs ", "CygnusTitle" },
    { badge .. " ", highlights.source_hl(session.source) },
  }

  local footer_text = status_text or string.format(" %d results ", #session.entries)
  local win_cfg = {
    title = title,
    title_pos = "left",
    footer = { { footer_text, "CygnusPromptCounter" } },
    footer_pos = "right",
  }

  pcall(vim.api.nvim_win_set_config, session.prompt_win, win_cfg)
end

---@param session table
local function apply_prompt_prefix(session)
  if not valid_buf(session.prompt_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(session.prompt_buf, NS_PROMPT, 0, -1)
  local prefix = config.get().finder.prompt_prefix or " > "
  vim.api.nvim_buf_set_extmark(session.prompt_buf, NS_PROMPT, 0, 0, {
    virt_text = { { prefix, "CygnusPromptPrefix" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

---@param session table
---@param message string
---@param hl_group? string
local function render_preview_message(session, message, hl_group)
  if not valid_buf(session.preview_buf) then
    return
  end
  local rendered = {
    lines = { "", "  " .. message },
    highlights = hl_group and {
      { line = 1, col_start = 2, col_end = -1, hl_group = hl_group },
    } or {},
    see_also = {},
  }
  renderer.apply(session.preview_buf, rendered, NS_PREVIEW)
end

---@param session table
local function update_preview(session)
  if not valid_buf(session.preview_buf) or not valid_win(session.preview_win) then
    return
  end

  if session.preview_handle then
    session.preview_handle.cancel()
    session.preview_handle = nil
  end

  local entry = session.entries[session.selected]
  if not entry then
    render_preview_message(session, "No symbol selected.", "CygnusHint")
    return
  end

  local preview_w = vim.api.nvim_win_get_width(session.preview_win) - 2
  local cached = cache.get_doc(entry.name, entry.source)
  if cached then
    local rendered = renderer.render_full(cached, { width = preview_w })
    renderer.apply(session.preview_buf, rendered, NS_PREVIEW)
    pcall(vim.api.nvim_win_set_cursor, session.preview_win, { 1, 0 })
    return
  end

  session.preview_seq = session.preview_seq + 1
  local seq = session.preview_seq

  stop_timer(session.preview_timer)
  session.preview_timer = vim.uv.new_timer()

  local delay = config.get().finder.preview_debounce_ms or 20
  session.preview_timer:start(delay, 0, vim.schedule_wrap(function()
    if session.closed or seq ~= session.preview_seq then
      return
    end
    session.preview_handle = client.lookup(entry.name, { source = entry.source }, function(err, doc)
      if session.closed or seq ~= session.preview_seq then
        return
      end
      session.preview_handle = nil
      if err or not doc then
        render_preview_message(session, err and err.message or "Failed to load documentation.", "CygnusError")
        return
      end
      cache.set_doc(entry.name, entry.source, doc)
      if valid_win(session.preview_win) then
        local w = vim.api.nvim_win_get_width(session.preview_win) - 2
        local rendered = renderer.render_full(doc, { width = w })
        renderer.apply(session.preview_buf, rendered, NS_PREVIEW)
        pcall(vim.api.nvim_win_set_cursor, session.preview_win, { 1, 0 })
      end
    end)
  end))
end

---@param session table
local function render_results(session)
  if not valid_buf(session.results_buf) then
    return
  end

  local entries = session.entries
  if #entries == 0 then
    local msg = session.error_msg or (session.query == "" and "No symbols available." or "No matching symbols.")
    local hl = session.error_msg and "CygnusError" or "CygnusHint"
    renderer.apply(session.results_buf, {
      lines = { "  " .. msg },
      highlights = { { line = 0, col_start = 2, col_end = -1, hl_group = hl } },
      see_also = {},
    }, NS_RESULTS)
    update_prompt_chrome(session, " 0 results ")
    update_preview(session)
    return
  end

  if session.selected < 1 then
    session.selected = 1
  elseif session.selected > #entries then
    session.selected = #entries
  end

  local win_w = valid_win(session.results_win) and vim.api.nvim_win_get_width(session.results_win) or 40
  local max_name = 12
  for _, e in ipairs(entries) do
    if e.name and #e.name > max_name then
      max_name = #e.name
    end
  end
  max_name = math.min(max_name, math.max(16, math.floor(win_w * 0.52)))

  local lines = {}
  local hl_list = {}
  for idx, entry in ipairs(entries) do
    local is_sel = (idx == session.selected)
    local row = renderer.render_result_line(entry, max_name, is_sel)
    table.insert(lines, row.text)
    if is_sel then
      table.insert(hl_list, {
        line = idx - 1,
        col_start = 0,
        col_end = -1,
        hl_group = "CygnusSelection",
      })
    end
    for _, span in ipairs(row.highlights) do
      table.insert(hl_list, {
        line = idx - 1,
        col_start = span.col_start,
        col_end = span.col_end,
        hl_group = span.hl_group,
      })
    end
  end

  renderer.apply(session.results_buf, {
    lines = lines,
    highlights = hl_list,
    see_also = {},
  }, NS_RESULTS)

  if valid_win(session.results_win) then
    pcall(vim.api.nvim_win_set_cursor, session.results_win, { session.selected, 0 })
  end

  update_prompt_chrome(session, string.format(" %d/%d ", session.selected, #entries))
  update_preview(session)
end

---@param query string
---@return string|nil
local function extract_lookup_candidate(query)
  local stripped = query:gsub("^%s*struct%s+", "")
    :gsub("^%s*enum%s+", "")
    :gsub("^%s*union%s+", "")
    :gsub("^%s*class%s+", "")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  if stripped == "" or stripped:find("%s") then
    return nil
  end
  return stripped
end

---@param doc table
---@return table[]
local function doc_to_entries(doc)
  local out = {}
  table.insert(out, {
    name = doc.name,
    source = doc.source,
    header = doc.header or "",
    summary = doc.summary or "",
  })
  if type(doc.alternatives) == "table" then
    for _, alt in ipairs(doc.alternatives) do
      if alt.name and alt.name ~= "" then
        table.insert(out, {
          name = alt.name,
          source = alt.source or doc.source,
          header = alt.header or "",
          summary = "",
        })
      end
    end
  end
  return out
end

---@param primary table[]
---@param secondary table[]
---@param limit number
---@return table[]
local function merge_entries(primary, secondary, limit)
  local merged = {}
  local seen = {}

  local function add(item)
    if #merged >= limit then
      return
    end
    local key = (item.source or "") .. ":" .. (item.name or "")
    if not seen[key] and item.name and item.name ~= "" then
      seen[key] = true
      table.insert(merged, item)
    end
  end

  for _, item in ipairs(primary) do
    add(item)
  end
  for _, item in ipairs(secondary) do
    add(item)
  end
  return merged
end

---@param session table
---@param immediate? boolean
local function trigger_search(session, immediate)
  if session.closed then
    return
  end

  if session.search_handle then
    session.search_handle.cancel()
    session.search_handle = nil
  end
  if session.lookup_handle then
    session.lookup_handle.cancel()
    session.lookup_handle = nil
  end
  stop_timer(session.search_timer)
  session.search_timer = nil

  session.search_seq = session.search_seq + 1
  local seq = session.search_seq
  local query = vim.trim(session.query or "")
  local source = session.source
  local limit = config.get().finder.limit

  if query == "" then
    local cached_list = cache.get_list(source, limit)
    if cached_list then
      session.error_msg = nil
      session.entries = cached_list
      session.selected = 1
      render_results(session)
      return
    end

    update_prompt_chrome(session, " loading... ")
    session.search_handle = client.list({ source = source, limit = limit }, function(err, entries)
      if session.closed or seq ~= session.search_seq then
        return
      end
      session.search_handle = nil
      if err then
        session.error_msg = err.message
        session.entries = {}
      else
        session.error_msg = nil
        session.entries = entries or {}
        cache.set_list(source, limit, session.entries)
      end
      session.selected = 1
      render_results(session)
    end)
    return
  end

  local function execute()
    if session.closed or seq ~= session.search_seq then
      return
    end
    update_prompt_chrome(session, " searching... ")

    local candidate = extract_lookup_candidate(query)
    local lookup_entries = {}
    local search_entries = {}
    local search_err = nil
    local search_done = false

    local function apply_merged()
      if session.closed or seq ~= session.search_seq then
        return
      end
      local combined = merge_entries(lookup_entries, search_entries, limit)
      if #combined > 0 then
        session.error_msg = nil
        session.entries = combined
      elseif search_done then
        session.error_msg = search_err
        session.entries = {}
      else
        return
      end
      session.selected = 1
      render_results(session)
    end

    if candidate then
      session.lookup_handle = client.lookup(candidate, { source = source }, function(err, doc)
        if session.closed or seq ~= session.search_seq then
          return
        end
        session.lookup_handle = nil
        if not err and doc then
          cache.set_doc(doc.name, doc.source, doc)
          lookup_entries = doc_to_entries(doc)
          apply_merged()
          return
        end

        -- When filtering to C, C standard typedefs/structs (e.g. size_t, FILE, timespec)
        -- may live under cppreference as std::<name>; fall back to unscoped lookup if exact.
        if source == "c" and err and err.kind == "not_found" then
          session.lookup_handle = client.lookup(candidate, { source = nil }, function(fb_err, fb_doc)
            if session.closed or seq ~= session.search_seq then
              return
            end
            session.lookup_handle = nil
            if not fb_err and fb_doc then
              cache.set_doc(fb_doc.name, fb_doc.source, fb_doc)
              lookup_entries = doc_to_entries(fb_doc)
              apply_merged()
            end
          end)
        end
      end)
    end

    session.search_handle = client.search(query, { source = source, limit = limit }, function(err, hits)
      if session.closed or seq ~= session.search_seq then
        return
      end
      session.search_handle = nil
      search_done = true
      if err then
        if err.kind == "not_found" then
          search_err = nil
          search_entries = err.suggestions or {}
        else
          search_err = err.message
          search_entries = {}
        end
      else
        search_err = nil
        search_entries = hits or {}
      end
      apply_merged()
    end)
  end

  local delay = immediate and 0 or (config.get().finder.debounce_ms or 40)
  if delay <= 0 then
    execute()
    return
  end

  session.search_timer = vim.uv.new_timer()
  session.search_timer:start(delay, 0, vim.schedule_wrap(execute))
end

---@param session table
---@param delta number
local function move_selection(session, delta)
  local count = #session.entries
  if count == 0 then
    return
  end
  local next_idx = ((session.selected - 1 + delta) % count) + 1
  session.selected = next_idx
  render_results(session)
end

---@param session table
---@param direction number +1 for down, -1 for up
local function scroll_preview(session, direction)
  if not valid_win(session.preview_win) or not valid_buf(session.preview_buf) then
    return
  end
  local win = session.preview_win
  local height = vim.api.nvim_win_get_height(win)
  local step = math.max(1, math.floor(height / 2))
  local line_count = vim.api.nvim_buf_line_count(session.preview_buf)
  local cur_line = vim.api.nvim_win_get_cursor(win)[1]
  local target = math.max(1, math.min(line_count, cur_line + (direction * step)))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

---@param session table
local function close_session(session)
  if not session or session.closed then
    return
  end
  session.closed = true

  if active_session == session then
    active_session = nil
  end

  if session.search_handle then
    session.search_handle.cancel()
    session.search_handle = nil
  end
  if session.lookup_handle then
    session.lookup_handle.cancel()
    session.lookup_handle = nil
  end
  if session.preview_handle then
    session.preview_handle.cancel()
    session.preview_handle = nil
  end
  stop_timer(session.search_timer)
  stop_timer(session.preview_timer)

  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
    session.augroup = nil
  end

  pcall(vim.cmd, "stopinsert")

  for _, win in ipairs({ session.preview_win, session.results_win, session.prompt_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ session.preview_buf, session.results_buf, session.prompt_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if valid_win(session.prev_win) then
    pcall(vim.api.nvim_set_current_win, session.prev_win)
  end
end

---@param session table
---@param win number
---@param is_preview? boolean
local function configure_win_opts(win, is_preview)
  vim.wo[win].winhighlight = "Normal:CygnusNormal,FloatBorder:CygnusBorder"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = is_preview and true or false
  vim.wo[win].linebreak = is_preview and true or false
  vim.wo[win].cursorline = false
end

---@param session table
local function resize_session(session)
  if session.closed then
    return
  end
  local geom = layout.finder()

  if valid_win(session.prompt_win) then
    vim.api.nvim_win_set_config(session.prompt_win, geom.prompt)
  end
  if valid_win(session.results_win) then
    vim.api.nvim_win_set_config(session.results_win, geom.results)
  end

  if geom.preview then
    if valid_win(session.preview_win) then
      vim.api.nvim_win_set_config(session.preview_win, geom.preview)
    elseif valid_buf(session.preview_buf) then
      local preview_cfg = vim.tbl_extend("force", geom.preview, {
        title = { { " Documentation ", "CygnusTitle" } },
        title_pos = "left",
      })
      session.preview_win = vim.api.nvim_open_win(session.preview_buf, false, preview_cfg)
      configure_win_opts(session.preview_win, true)
    end
  else
    if valid_win(session.preview_win) then
      pcall(vim.api.nvim_win_close, session.preview_win, true)
      session.preview_win = nil
    end
  end

  render_results(session)
end

---Close any currently open fuzzy finder.
function M.close()
  if active_session then
    close_session(active_session)
  end
end

---@return boolean
function M.is_open()
  return active_session ~= nil and not active_session.closed
end

---Open the floating Cygnus fuzzy finder.
---@param opts? { query?: string, source?: string|nil }
function M.open(opts)
  opts = opts or {}
  highlights.setup()

  if active_session then
    close_session(active_session)
  end

  local cfg = config.get()
  local prev_win = vim.api.nvim_get_current_win()
  local geom = layout.finder()

  local prompt_buf = create_scratch_buf("cygnus_prompt")
  local results_buf = create_scratch_buf("cygnus_results")
  local preview_buf = create_scratch_buf("cygnus_preview")

  vim.bo[results_buf].modifiable = false
  vim.bo[preview_buf].modifiable = false

  local initial_query = opts.query or ""
  if initial_query ~= "" then
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { initial_query })
  end

  local prompt_cfg = vim.tbl_extend("force", geom.prompt, {
    title = { { " Cygnus Docs ", "CygnusTitle" } },
    title_pos = "left",
  })
  local results_cfg = vim.tbl_extend("force", geom.results, {
    title = { { " Symbols ", "CygnusTitle" } },
    title_pos = "left",
  })

  local results_win = vim.api.nvim_open_win(results_buf, false, results_cfg)
  configure_win_opts(results_win, false)

  local preview_win = nil
  if geom.preview then
    local preview_cfg = vim.tbl_extend("force", geom.preview, {
      title = { { " Documentation ", "CygnusTitle" } },
      title_pos = "left",
    })
    preview_win = vim.api.nvim_open_win(preview_buf, false, preview_cfg)
    configure_win_opts(preview_win, true)
  end

  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, prompt_cfg)
  configure_win_opts(prompt_win, false)

  local session = {
    closed = false,
    prev_win = prev_win,
    prompt_buf = prompt_buf,
    results_buf = results_buf,
    preview_buf = preview_buf,
    prompt_win = prompt_win,
    results_win = results_win,
    preview_win = preview_win,
    source = opts.source ~= nil and opts.source or cfg.default_source,
    query = initial_query,
    entries = {},
    selected = 1,
    error_msg = nil,
    search_seq = 0,
    preview_seq = 0,
    search_handle = nil,
    lookup_handle = nil,
    preview_handle = nil,
    search_timer = nil,
    preview_timer = nil,
    augroup = vim.api.nvim_create_augroup("CygnusFinderSession", { clear = true }),
  }
  active_session = session

  apply_prompt_prefix(session)
  update_prompt_chrome(session, " loading... ")

  -- Bind keymaps on prompt buffer (insert & normal modes)
  local function map_keys(lhs_list, fn, modes)
    for _, lhs in ipairs(lhs_list or {}) do
      vim.keymap.set(modes or { "i", "n" }, lhs, fn, { buffer = prompt_buf, nowait = true, silent = true })
    end
  end

  local km = cfg.keymaps
  map_keys(km.next, function()
    move_selection(session, 1)
  end)
  map_keys(km.prev, function()
    move_selection(session, -1)
  end)
  map_keys(km.scroll_preview_down, function()
    scroll_preview(session, 1)
  end)
  map_keys(km.scroll_preview_up, function()
    scroll_preview(session, -1)
  end)
  map_keys(km.cycle_source, function()
    session.source = next_source(session.source)
    trigger_search(session, true)
  end)
  map_keys(km.select, function()
    local entry = session.entries[session.selected]
    close_session(session)
    if entry then
      require("cygnus.ui.doc_view").open_full(entry.name, { source = entry.source })
    end
  end)
  map_keys(km.select_short, function()
    local entry = session.entries[session.selected]
    close_session(session)
    if entry then
      require("cygnus.ui.doc_view").open_short(entry.name, { source = entry.source })
    end
  end)
  map_keys(km.yank_header, function()
    local entry = session.entries[session.selected]
    if not entry then
      return
    end
    local inc = format_include_lines(entry.header)
    if not inc then
      vim.notify("cygnus.lua: no header listed for " .. (entry.name or "symbol"), vim.log.levels.WARN)
      return
    end
    vim.fn.setreg('"', inc)
    pcall(vim.fn.setreg, "+", inc)
    vim.notify("Yanked: " .. inc:gsub("\n", " "), vim.log.levels.INFO)
  end)
  map_keys(km.close, function()
    close_session(session)
  end)
  vim.keymap.set("n", "q", function()
    close_session(session)
  end, { buffer = prompt_buf, nowait = true, silent = true })

  -- Watch prompt edits via nvim_buf_attach so insert mode, paste, and feedkeys always trigger search
  local function on_prompt_change()
    if session.closed or not valid_buf(prompt_buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
    if #lines > 1 then
      local joined = table.concat(lines, " ")
      vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { joined })
      lines = { joined }
    end
    apply_prompt_prefix(session)
    local new_query = lines[1] or ""
    if new_query ~= session.query then
      session.query = new_query
      trigger_search(session, false)
    end
  end

  vim.api.nvim_buf_attach(prompt_buf, false, {
    on_lines = function()
      if session.closed then
        return true
      end
      vim.schedule(on_prompt_change)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = session.augroup,
    callback = function()
      resize_session(session)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = session.augroup,
    buffer = prompt_buf,
    callback = function()
      -- Close if focus leaves the finder completely
      vim.schedule(function()
        if session.closed then
          return
        end
        local cur = vim.api.nvim_get_current_win()
        if cur ~= session.prompt_win and cur ~= session.results_win and cur ~= session.preview_win then
          close_session(session)
        end
      end)
    end,
  })

  -- Place cursor at end of initial query and enter insert mode
  pcall(vim.api.nvim_win_set_cursor, prompt_win, { 1, #initial_query })
  vim.cmd("startinsert!")

  trigger_search(session, true)
end

return M
