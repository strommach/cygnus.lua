local config = require("cygnus.config")

local M = {}

function M.check()
  local health = vim.health
  health.start("cygnus.lua")

  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    health.ok(string.format("Neovim %d.%d.%d (>= 0.10 required)", v.major, v.minor, v.patch))
  else
    health.error("Neovim >= 0.10 is required for vim.system and inline extmarks")
    return
  end

  local cfg = config.get()
  local cmd = cfg.cmd
  if vim.fn.executable(cmd) == 1 then
    health.ok(string.format("Found cygnus executable: %s", vim.fn.exepath(cmd)))
  else
    health.error(string.format("cygnus executable '%s' not found in $PATH", cmd), {
      "Install cygnus and ensure it is in your $PATH, or set `cmd` in `require('cygnus').setup()`.",
    })
    return
  end

  local ver = vim.system({ cmd, "--version" }, { text = true }):wait()
  if ver.code == 0 then
    health.ok("cygnus version: " .. vim.trim(ver.stdout or ""))
  else
    health.warn("Could not determine cygnus version: " .. vim.trim(ver.stderr or ""))
  end

  local list_argv = { cmd, "--list", "--json", "--limit", "1" }
  if cfg.db_path and cfg.db_path ~= "" then
    table.insert(list_argv, "--db")
    table.insert(list_argv, cfg.db_path)
  end

  local db_res = vim.system(list_argv, { text = true }):wait()
  if db_res.code == 0 then
    local ok, decoded = pcall(vim.json.decode, db_res.stdout or "")
    if ok and type(decoded) == "table" and #decoded > 0 then
      health.ok("cygnus database is accessible and populated")
    else
      health.warn("cygnus database responded, but no symbols were returned")
    end
  else
    health.error("cygnus database check failed: " .. vim.trim(db_res.stderr or "unknown error"), {
      "Run `make db` in the cygnus repo or set `CYGNUS_DB` / `db_path` in setup().",
    })
  end
end

return M
