local M = {}

local HIGHLIGHTS = {
  CygnusTitle = { link = "Title", default = true },
  CygnusBorder = { link = "FloatBorder", default = true },
  CygnusNormal = { link = "NormalFloat", default = true },
  CygnusPromptPrefix = { link = "Special", default = true },
  CygnusPromptCounter = { link = "Comment", default = true },
  CygnusSelection = { link = "Visual", default = true },
  CygnusSelectionCaret = { link = "Statement", default = true },
  CygnusSymbol = { link = "Function", default = true },
  CygnusHeader = { link = "String", default = true },
  CygnusSummary = { link = "Comment", default = true },
  CygnusSection = { link = "Keyword", default = true },
  CygnusStandard = { link = "Type", default = true },
  CygnusSynopsis = { link = "Special", default = true },
  CygnusSeeAlso = { link = "Underlined", default = true },
  CygnusHint = { link = "DiagnosticHint", default = true },
  CygnusError = { link = "DiagnosticError", default = true },
  CygnusSourceC = { link = "Constant", default = true },
  CygnusSourcePosix = { link = "Type", default = true },
  CygnusSourceCpp = { link = "Identifier", default = true },
  CygnusSourceAll = { link = "Special", default = true },
}

---Register default highlight groups without overriding user colorscheme definitions.
function M.setup()
  for name, spec in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

---@param source string|nil
---@return string
function M.source_hl(source)
  if source == "c" then
    return "CygnusSourceC"
  elseif source == "posix" then
    return "CygnusSourcePosix"
  elseif source == "cpp" then
    return "CygnusSourceCpp"
  end
  return "CygnusSourceAll"
end

return M
