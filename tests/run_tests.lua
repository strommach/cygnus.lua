-- Pure-Lua headless test suite for cygnus.lua
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/run_tests.lua

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(val, msg)
  if not val then
    error(msg or "expected truthy value, got " .. vim.inspect(val), 2)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write(string.format("  PASS  %s\n", name))
  else
    failed = failed + 1
    io.write(string.format("  FAIL  %s\n        %s\n", name, tostring(err)))
  end
end

local function wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms or 3000, predicate, 15)
end

local config = require("cygnus.config")
local cache = require("cygnus.cache")
local client = require("cygnus.client")
local renderer = require("cygnus.renderer")
local layout = require("cygnus.ui.layout")
local finder = require("cygnus.ui.finder")
local doc_view = require("cygnus.ui.doc_view")
local cygnus = require("cygnus")

io.write("Running cygnus.lua test suite...\n")

-- 1. Config tests
test("config: defaults and deep merge", function()
  local cfg = config.setup()
  assert_eq(cfg.cmd, "cygnus", "default cmd")
  assert_eq(cfg.default_source, nil, "default source should be ALL (nil)")
  assert_eq(cfg.doc_view.split, "split", "default doc_view split")

  local custom = config.setup({
    doc_view = { split = "vsplit" },
    finder = { limit = 25 },
  })
  assert_eq(custom.doc_view.split, "vsplit", "override split")
  assert_eq(custom.finder.limit, 25, "override limit")
  assert_eq(custom.finder.border, "rounded", "preserved default border")

  config.setup()
end)

test("config: validates invalid options", function()
  local ok_split = pcall(config.setup, { doc_view = { split = "invalid" } })
  assert_eq(ok_split, false, "invalid split should error")

  local ok_source = pcall(config.setup, { default_source = "rust" })
  assert_eq(ok_source, false, "invalid source should error")

  config.setup()
end)

-- 2. Cache tests
test("cache: list and doc storage with eviction", function()
  cache.clear()
  config.setup({ cache_max_entries = 2 })

  cache.set_list(nil, 20, { { name = "printf" } })
  assert_eq(cache.get_list(nil, 20)[1].name, "printf", "list cache hit")

  cache.set_doc("a", "c", { name = "a" })
  cache.set_doc("b", "c", { name = "b" })
  cache.set_doc("c", "c", { name = "c" })

  assert_eq(cache.get_doc("a", "c"), nil, "oldest doc evicted")
  assert_eq(cache.get_doc("b", "c").name, "b", "second doc retained")
  assert_eq(cache.get_doc("c", "c").name, "c", "newest doc retained")
  assert_eq(cache.stats().docs, 2, "doc count matches cap")

  cache.clear()
  config.setup()
end)

-- 3. Renderer tests
test("renderer: render_full produces sections, highlights, and see_also links", function()
  local sample = {
    name = "printf",
    source = "c",
    section = "3",
    standard = "C89",
    header = "<stdio.h>",
    synopsis = "int printf(const char *format, ...);",
    summary = "formatted output conversion",
    description = "Writes formatted output to stdout.",
    return_value = "Number of characters printed.",
    errors = "ENOMEM",
    see_also = { "fprintf", "sprintf" },
    alternatives = { { name = "std::printf", source = "cpp", header = "<cstdio>" } },
  }

  local rendered = renderer.render_full(sample, { width = 80 })
  local joined = table.concat(rendered.lines, "\n")
  assert_truthy(joined:find("PRINTF%(3%)"), "title line present")
  assert_truthy(joined:find("HEADER"), "HEADER section present")
  assert_truthy(joined:find("SYNOPSIS"), "SYNOPSIS section present")
  assert_truthy(joined:find("SEE ALSO"), "SEE ALSO section present")
  assert_truthy(joined:find("Also available in: %-%-cpp"), "alternatives hint present")
  assert_truthy(#rendered.highlights > 5, "highlights generated")

  local link_count = 0
  for _, links in pairs(rendered.see_also) do
    link_count = link_count + #links
  end
  assert_eq(link_count, 2, "two see_also links tracked")

  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace("cygnus_test_render")
  renderer.apply(buf, rendered, ns)
  assert_eq(vim.api.nvim_buf_line_count(buf), #rendered.lines, "buffer lines applied")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("renderer: render_short and render_result_line", function()
  local short = renderer.render_short({
    name = "pthread_create",
    source = "posix",
    standard = "POSIX",
    header = "<pthread.h>",
    synopsis = "int pthread_create(...);",
    summary = "create a new thread",
  })
  local joined = table.concat(short.lines, "\n")
  assert_truthy(joined:find("pthread_create %[posix%] %(POSIX%)"), "short header line")
  assert_truthy(joined:find("<pthread.h>"), "short header present")

  local row = renderer.render_result_line({
    name = "printf",
    source = "c",
    header = "<stdio.h>",
  }, 16, true)
  assert_truthy(row.text:find("^> printf"), "selected caret rendered")
  assert_truthy(row.text:find("%[c%]"), "source badge rendered")
end)

-- 4. Layout tests
test("layout: responsive preview toggle on wide vs narrow terminal", function()
  local wide = layout.finder(140, 40)
  assert_truthy(wide.prompt ~= nil, "wide prompt")
  assert_truthy(wide.results ~= nil, "wide results")
  assert_truthy(wide.preview ~= nil, "wide preview shown")
  assert_truthy(wide.results.row > wide.prompt.row, "results below prompt")

  local narrow = layout.finder(70, 30)
  assert_eq(narrow.preview, nil, "narrow terminal hides preview")

  local short_geom = layout.short_float({ "line 1", "line 2", "line 3" }, 120, 40)
  assert_truthy(short_geom.width >= 36, "short float min width")
  assert_truthy(short_geom.height >= 5, "short float min height")
end)

-- 5. Cursor symbol extraction
test("init: symbol_under_cursor preserves C++ scope resolution", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  std::vector<int> v;" })
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  assert_eq(cygnus.symbol_under_cursor(), "std::vector", "extracts std::vector")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- 6. Live CLI client integration tests
if vim.fn.executable("cygnus") == 1 then
  test("client: async version, list, search, lookup, not_found", function()
    local done_ver, ver_out
    client.version(function(err, v)
      assert_eq(err, nil, "version err")
      ver_out = v
      done_ver = true
    end)
    assert_truthy(wait_for(function() return done_ver end), "version timed out")
    assert_truthy(ver_out:find("cygnus"), "version output")

    local done_list, list_out
    client.list({ limit = 5 }, function(err, entries)
      assert_eq(err, nil, "list err")
      list_out = entries
      done_list = true
    end)
    assert_truthy(wait_for(function() return done_list end), "list timed out")
    assert_eq(#list_out, 5, "list respects limit")

    local done_search, search_out
    client.search("thread", { limit = 5 }, function(err, hits)
      assert_eq(err, nil, "search err")
      search_out = hits
      done_search = true
    end)
    assert_truthy(wait_for(function() return done_search end), "search timed out")
    assert_truthy(#search_out > 0, "search returned hits")

    local done_lookup, lookup_out
    client.lookup("printf", { source = "c" }, function(err, doc)
      assert_eq(err, nil, "lookup err")
      lookup_out = doc
      done_lookup = true
    end)
    assert_truthy(wait_for(function() return done_lookup end), "lookup timed out")
    assert_eq(lookup_out.name, "printf", "lookup name")
    assert_eq(lookup_out.source, "c", "lookup source")

    local done_nf, nf_err
    client.lookup("definitely_nonexistent_symbol_xyz_999", {}, function(err, _)
      nf_err = err
      done_nf = true
    end)
    assert_truthy(wait_for(function() return done_nf end), "not_found timed out")
    assert_eq(nf_err.kind, "not_found", "not_found error kind")
  end)

  test("client: request cancellation suppresses callback", function()
    local called = false
    local h = client.search("thread", { limit = 20 }, function()
      called = true
    end)
    h.cancel()
    vim.wait(120)
    assert_eq(called, false, "cancelled request should not invoke callback")
  end)

  test("ui: finder open and close lifecycle without leaked windows", function()
    local wins_before = #vim.api.nvim_list_wins()
    finder.open({ query = "printf" })
    assert_eq(finder.is_open(), true, "finder reports open")
    vim.wait(150)
    finder.close()
    assert_eq(finder.is_open(), false, "finder reports closed")
    assert_eq(#vim.api.nvim_list_wins(), wins_before, "no leaked windows after finder close")
  end)

  test("ui: finder resolves size_t (even in C mode), aliases (snprintf), and struct queries", function()
    local function first_result_line(opts)
      finder.open(opts)
      local first_line = ""
      wait_for(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local b = vim.api.nvim_win_get_buf(win)
          if vim.bo[b].filetype == "cygnus_results" then
            local l = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
            if l ~= "" and not l:find("loading") and not l:find("No matching") then
              first_line = l
              return true
            end
          end
        end
        return false
      end, 2000)
      finder.close()
      return first_line
    end

    local size_t_line = first_result_line({ query = "size_t", source = "c" })
    assert_truthy(size_t_line:find("size_t"), "size_t should appear even under C filter, got: " .. size_t_line)

    local snprintf_line = first_result_line({ query = "snprintf" })
    assert_truthy(snprintf_line:find("printf"), "snprintf alias should pin printf at #1, got: " .. snprintf_line)

    local timespec_line = first_result_line({ query = "struct timespec" })
    assert_truthy(timespec_line:find("timespec"), "struct timespec should pin timespec at #1, got: " .. timespec_line)
  end)

  test("ui: short float and full split doc views", function()
    local wins_before = #vim.api.nvim_list_wins()
    doc_view.open_short("printf", { source = "c" })
    assert_truthy(wait_for(function() return #vim.api.nvim_list_wins() > wins_before end), "short float opened")
    doc_view.close_short()
    assert_eq(#vim.api.nvim_list_wins(), wins_before, "short float closed cleanly")

    doc_view.open_full("printf", { source = "c", split = "vsplit" })
    assert_truthy(wait_for(function() return #vim.api.nvim_list_wins() > wins_before end), "full split opened")
    vim.cmd("close")
    assert_eq(#vim.api.nvim_list_wins(), wins_before, "full split closed cleanly")
  end)
end

io.write(string.format("\nResults: %d passed, %d failed\n", passed, failed))
if failed > 0 then
  vim.cmd("cq 1")
end
vim.cmd("qa!")
