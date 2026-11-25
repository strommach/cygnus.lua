local config = require("cygnus.config")

local M = {}

local list_cache = {}
local doc_cache = {}
local doc_order = {}

---@param source string|nil
---@param limit number
---@return string
local function list_key(source, limit)
  return (source or "all") .. ":" .. tostring(limit)
end

---@param symbol string
---@param source string|nil
---@return string
local function doc_key(symbol, source)
  return (source or "all") .. ":" .. symbol
end

---@param source string|nil
---@param limit number
---@return table[]|nil
function M.get_list(source, limit)
  return list_cache[list_key(source, limit)]
end

---@param source string|nil
---@param limit number
---@param entries table[]
function M.set_list(source, limit, entries)
  list_cache[list_key(source, limit)] = entries
end

---@param symbol string
---@param source string|nil
---@return table|nil
function M.get_doc(symbol, source)
  return doc_cache[doc_key(symbol, source)]
end

---@param symbol string
---@param source string|nil
---@param doc table
function M.set_doc(symbol, source, doc)
  local key = doc_key(symbol, source)
  if doc_cache[key] == nil then
    table.insert(doc_order, key)
    local max_entries = config.get().cache_max_entries or 256
    while #doc_order > max_entries do
      local oldest = table.remove(doc_order, 1)
      if oldest then
        doc_cache[oldest] = nil
      end
    end
  end
  doc_cache[key] = doc
end

function M.clear()
  list_cache = {}
  doc_cache = {}
  doc_order = {}
end

---@return { lists: number, docs: number }
function M.stats()
  local lists = 0
  for _ in pairs(list_cache) do
    lists = lists + 1
  end
  return {
    lists = lists,
    docs = #doc_order,
  }
end

return M
