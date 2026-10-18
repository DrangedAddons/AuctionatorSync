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
  ns.Debug("encode failed: %s", tostring(text))
end

function ns.Decode(text)
  if not CAN_ENCODE or type(text) ~= "string" then return nil end
  local ok, tbl = pcall(function()
    local packed = Base64Decode(text)
    local cbor = packed and E.DecompressString(packed, Enum.CompressionMethod.Deflate)
    return cbor and E.DeserializeCBOR(cbor)
  end)
  if ok and type(tbl) == "table" then return tbl end
  ns.Debug("decode failed: %s", tostring(tbl))
end
