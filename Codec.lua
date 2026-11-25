-- Lua table <-> addon-channel-safe text: CBOR, Deflate, then base64 (all Blizzard's
-- C_EncodingUtil, which every Forever client has; base64 falls back to Lua if missing).
local _, ns = ...

local E = C_EncodingUtil
local CAN_ENCODE = E and E.SerializeCBOR and E.DeserializeCBOR and E.CompressString and E.DecompressString
  and Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate
ns.canEncode = CAN_ENCODE and true or false

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_DEC = {}
for i = 1, 64 do B64_DEC[B64:byte(i)] = i - 1 end

local floor, byte, char, concat = math.floor, string.byte, string.char, table.concat

local function LuaBase64Encode(s)
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = floor(v / 262144) % 64, floor(v / 4096) % 64
    local c3, c4 = floor(v / 64) % 64, v % 64
    n = n + 1
    out[n] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return concat(out)
end

local function LuaBase64Decode(s)
  s = s:gsub("[^%w%+/]", "")
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    a, b = B64_DEC[a], B64_DEC[b]
    if not a or not b then break end
    c, d = c and B64_DEC[c], d and B64_DEC[d]
    local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
    n = n + 1
    if d then
      out[n] = char(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
    elseif c then
      out[n] = char(floor(v / 65536) % 256, floor(v / 256) % 256)
    else
      out[n] = char(floor(v / 65536) % 256)
    end
  end
  return concat(out)
end

local Base64Encode = (E and E.EncodeBase64) or LuaBase64Encode
local Base64Decode = (E and E.DecodeBase64) or LuaBase64Decode

function ns.Encode(tbl)
  if not CAN_ENCODE then return nil end
  local ok, text = pcall(function()
    local cbor = E.SerializeCBOR(tbl)
    local packed = E.CompressString(cbor, Enum.CompressionMethod.Deflate)
    return Base64Encode(packed)
  end)
  if ok then return text end
  ns.Detail("encode failed: %s", tostring(text))
end

function ns.Decode(text)
  if not CAN_ENCODE or type(text) ~= "string" then return nil end
  local ok, tbl = pcall(function()
    local packed = Base64Decode(text)
    local cbor = packed and E.DecompressString(packed, Enum.CompressionMethod.Deflate)
    return cbor and E.DeserializeCBOR(cbor)
  end)
  if ok and type(tbl) == "table" then return tbl end
  ns.Detail("decode failed: %s", tostring(tbl))
end

----------------------------------------------------------------------------------------------
-- Compact price records. The outer Encode still deflates and base64s the whole message;
-- this just makes the records small and repetitive enough for that deflate to bite.
--   plain item "12345", gear "g:<id>:<ilvl>", older suffix gear "gr:<id>:<suffix>",
--   anything else kept as its own text (battle pets, "p:...").
-- A batch is one version byte then one record per price:
--   flags: bits 0-1 kind (0 item, 1 g, 2 gr, 3 text), bit 2 has a quantity,
--          bit 3 item id is a delta from the previous id of the same kind
--   varint id (or delta), varint ilvl/suffix for gear, varint price,
--   varint (seen-at minus the batch base), varint quantity if present
-- Varints are 7 bits a byte, high bit set while more bytes follow.

function ns.KeyParts(key)
  key = tostring(key)
  local id = key:match("^(%d+)$")
  if id then return 0, tonumber(id), 0 end
  local gid, extra = key:match("^g:(%d+):(%d+)$")
  if gid then return 1, tonumber(gid), tonumber(extra) end
  local rid, suffix = key:match("^gr:(%d+):(%d+)$")
  if rid then return 2, tonumber(rid), tonumber(suffix) end
  return 3, key, 0
end

function ns.KeyFromParts(kind, id, extra)
  if kind == 0 then return tostring(id) end
  if kind == 1 then return "g:" .. id .. ":" .. extra end
  if kind == 2 then return "gr:" .. id .. ":" .. extra end
  return tostring(id)
end

local function WriteVarint(out, n)
  n = floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  while n >= 128 do
    out[#out + 1] = char(128 + (n % 128))
    n = floor(n / 128)
  end
  out[#out + 1] = char(n)
end

-- list entries are { key, price, available, seen-at }. base is subtracted from seen-at.
function ns.PackItems(list, base)
  local out = { char(1) }
  local prevKind, prevId = -1, 0
  base = floor(tonumber(base) or 0)
  for i = 1, #list do
    local it = list[i]
    local kind, id, extra = ns.KeyParts(it[1])
    local avail = floor(tonumber(it[3]) or 0)
    local flags = kind
    if avail > 0 then flags = flags + 4 end
    local delta = false
    if kind ~= 3 and kind == prevKind and type(id) == "number" and id >= prevId then
      flags = flags + 8
      delta = true
    end
    out[#out + 1] = char(flags)
    if kind == 3 then
      local s = tostring(id)
      WriteVarint(out, #s)
      out[#out + 1] = s
    else
      WriteVarint(out, delta and (id - prevId) or id)
      if kind ~= 0 then WriteVarint(out, extra or 0) end
      prevKind, prevId = kind, id
    end
    WriteVarint(out, it[2])
    local td = floor(tonumber(it[4]) or 0) - base
    if td < 0 then td = 0 end
    WriteVarint(out, td)
    if avail > 0 then WriteVarint(out, avail) end
  end
  return concat(out)
end

-- nil if the blob is truncated or corrupt, so a damaged batch is dropped whole
-- rather than applied as if those were the only prices in it.
function ns.UnpackItems(blob, base)
  if type(blob) ~= "string" or blob:byte(1) ~= 1 then return nil end
  local list, i, n = {}, 2, #blob
  local prevKind, prevId = -1, 0
  base = floor(tonumber(base) or 0)
  local function varint()
    local v, mul = 0, 1
    while i <= n do
      local b = byte(blob, i)
      i = i + 1
      v = v + (b % 128) * mul
      if b < 128 then return v end
      mul = mul * 128
      if mul > 2 ^ 53 then return nil end
    end
    return nil
  end
  while i <= n do
    local flags = byte(blob, i)
    i = i + 1
    if not flags then return nil end
    local kind = flags % 4
    local id, extra
    if kind == 3 then
      local len = varint()
      if not len or i + len - 1 > n then return nil end
      id = blob:sub(i, i + len - 1)
      i = i + len
      extra = 0
    else
      id = varint()
      if not id then return nil end
      if flags >= 8 and kind == prevKind then id = prevId + id end
      extra = 0
      if kind ~= 0 then
        extra = varint()
        if not extra then return nil end
      end
      prevKind, prevId = kind, id
    end
    local price = varint()
    local td = varint()
    if not price or not td then return nil end
    local avail = 0
    if flags % 8 >= 4 then
      avail = varint()
      if not avail then return nil end
    end
    list[#list + 1] = { ns.KeyFromParts(kind, id, extra), price, avail, base + td }
  end
  return list
end
