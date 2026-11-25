local config = require("cygnus.config")

local M = {}

---@class CygnusRequestHandle
---@field cancel fun()

---@class CygnusClientError
---@field code number
---@field kind "not_found"|"db_error"|"cli_error"|"spawn_error"|"parse_error"
---@field message string
---@field suggestions table[]|nil

---@param source string|nil
---@param db_path string|nil
---@return string[]
local function base_args(source, db_path)
  local cfg = config.get()
  local argv = { cfg.cmd }

  local resolved_db = db_path or cfg.db_path
  if resolved_db and resolved_db ~= "" then
    table.insert(argv, "--db")
    table.insert(argv, resolved_db)
  end

  if source == "c" then
    table.insert(argv, "--c")
  elseif source == "posix" then
    table.insert(argv, "--posix")
  elseif source == "cpp" then
    table.insert(argv, "--cpp")
  end

  return argv
end

---@param argv string[]
---@param expect_json boolean
---@param cb fun(err: CygnusClientError|nil, data: any)
---@return CygnusRequestHandle
local function run_async(argv, expect_json, cb)
  local cancelled = false
  local proc = nil

  local handle = {
    cancel = function()
      if cancelled then
        return
      end
      cancelled = true
      if proc then
        pcall(proc.kill, proc, 15)
      end
    end,
  }

  local ok, result = pcall(vim.system, argv, { text = true }, function(res)
    if cancelled then
      return
    end

    vim.schedule(function()
      if cancelled then
        return
      end

      local stdout = res.stdout or ""
      local stderr = vim.trim(res.stderr or "")

      if res.code == 0 then
        if not expect_json then
          cb(nil, vim.trim(stdout))
          return
        end

        local decoded_ok, decoded = pcall(vim.json.decode, stdout)
        if not decoded_ok then
          cb({
            code = -1,
            kind = "parse_error",
            message = "Failed to decode cygnus JSON output: " .. tostring(decoded),
          }, nil)
          return
        end

        cb(nil, decoded)
        return
      end

      if res.code == 1 then
        local suggestions = {}
        local msg = stderr ~= "" and stderr or "Symbol not found"
        if expect_json and stdout ~= "" then
          local decoded_ok, decoded = pcall(vim.json.decode, stdout)
          if decoded_ok and type(decoded) == "table" then
            if type(decoded.suggestions) == "table" then
              suggestions = decoded.suggestions
            end
            if type(decoded.query) == "string" and decoded.query ~= "" then
              msg = ("No documentation found for '%s'"):format(decoded.query)
            end
          end
        end
        cb({
          code = 1,
          kind = "not_found",
          message = msg,
          suggestions = suggestions,
        }, nil)
        return
      end

      local kind = res.code == 3 and "db_error" or "cli_error"
      cb({
        code = res.code,
        kind = kind,
        message = stderr ~= "" and stderr or ("cygnus exited with code " .. tostring(res.code)),
      }, nil)
    end)
  end)

  if not ok then
    vim.schedule(function()
      if cancelled then
        return
      end
      cb({
        code = -1,
        kind = "spawn_error",
        message = "Failed to spawn cygnus: " .. tostring(result),
      }, nil)
    end)
    return handle
  end

  proc = result
  return handle
end

---List available symbols from the cygnus database.
---@param opts? { source?: string|nil, limit?: number, db_path?: string|nil }
---@param cb fun(err: CygnusClientError|nil, entries: table[]|nil)
---@return CygnusRequestHandle
function M.list(opts, cb)
  opts = opts or {}
  local cfg = config.get()
  local limit = opts.limit or cfg.finder.limit
  local argv = base_args(opts.source, opts.db_path)
  table.insert(argv, "--list")
  table.insert(argv, "--json")
  table.insert(argv, "--limit")
  table.insert(argv, tostring(limit))
  return run_async(argv, true, cb)
end

---Run fuzzy + FTS5 apropos search via `cygnus search`.
---@param query string
---@param opts? { source?: string|nil, limit?: number, db_path?: string|nil }
---@param cb fun(err: CygnusClientError|nil, hits: table[]|nil)
---@return CygnusRequestHandle
function M.search(query, opts, cb)
  opts = opts or {}
  local cfg = config.get()
  local limit = opts.limit or cfg.finder.limit
  local argv = base_args(opts.source, opts.db_path)
  table.insert(argv, "--json")
  table.insert(argv, "--limit")
  table.insert(argv, tostring(limit))
  table.insert(argv, "--")
  table.insert(argv, "search")
  table.insert(argv, query)
  return run_async(argv, true, cb)
end

---Look up full documentation JSON for a specific symbol.
---@param symbol string
---@param opts? { source?: string|nil, db_path?: string|nil }
---@param cb fun(err: CygnusClientError|nil, doc: table|nil)
---@return CygnusRequestHandle
function M.lookup(symbol, opts, cb)
  opts = opts or {}
  local argv = base_args(opts.source, opts.db_path)
  table.insert(argv, "--json")
  table.insert(argv, "--")
  table.insert(argv, symbol)
  return run_async(argv, true, cb)
end

---Query the installed cygnus version string.
---@param cb fun(err: CygnusClientError|nil, version: string|nil)
---@return CygnusRequestHandle
function M.version(cb)
  local cfg = config.get()
  return run_async({ cfg.cmd, "--version" }, false, cb)
end

return M
