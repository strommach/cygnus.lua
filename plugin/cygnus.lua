if vim.g.loaded_cygnus_lua then
  return
end
vim.g.loaded_cygnus_lua = 1

---@param fargs string[]
---@return { source: string|nil, short: boolean, split: string|nil, positionals: string[] }
local function parse_args(fargs)
  local parsed = {
    source = nil,
    short = false,
    split = nil,
    positionals = {},
  }
  for _, arg in ipairs(fargs) do
    if arg == "--c" or arg == "-c" then
      parsed.source = "c"
    elseif arg == "--posix" or arg == "-p" then
      parsed.source = "posix"
    elseif arg == "--cpp" or arg == "--c++" then
      parsed.source = "cpp"
    elseif arg == "--short" or arg == "-s" then
      parsed.short = true
    elseif arg == "--split" then
      parsed.split = "split"
    elseif arg == "--vsplit" then
      parsed.split = "vsplit"
    else
      table.insert(parsed.positionals, arg)
    end
  end
  return parsed
end

vim.api.nvim_create_user_command("Cygnus", function(cmd)
  local parsed = parse_args(cmd.fargs)
  local query = table.concat(parsed.positionals, " ")
  require("cygnus").open({
    query = query,
    source = parsed.source,
  })
end, {
  nargs = "*",
  desc = "Open Cygnus floating fuzzy finder for C/C++/POSIX docs",
})

vim.api.nvim_create_user_command("CygnusLookup", function(cmd)
  local parsed = parse_args(cmd.fargs)
  local cygnus = require("cygnus")
  local symbol = parsed.positionals[1]
  local opts = {
    source = parsed.source,
    short = parsed.short,
    split = parsed.split,
  }
  if symbol and symbol ~= "" then
    cygnus.lookup(symbol, opts)
  else
    cygnus.lookup_cword(opts)
  end
end, {
  nargs = "*",
  desc = "Look up full Cygnus docs in a split (or float with --short)",
})

vim.api.nvim_create_user_command("CygnusShort", function(cmd)
  local parsed = parse_args(cmd.fargs)
  local cygnus = require("cygnus")
  local symbol = parsed.positionals[1]
  local opts = {
    source = parsed.source,
    short = true,
  }
  if symbol and symbol ~= "" then
    cygnus.lookup(symbol, opts)
  else
    cygnus.lookup_cword(opts)
  end
end, {
  nargs = "*",
  desc = "Look up compact Cygnus docs in a floating window",
})
