-- Round-trip and size check for the packed price records in Codec.lua.
--   lua tools/test_pack.lua
local chunk, err = loadfile("Codec.lua")
if not chunk then error(err) end
local ns = {}
chunk("AuctionatorSync", ns)

local function eq(a, b, msg)
  if a ~= b then error(msg .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2) end
end

local function roundtrip(list, base, label)
  local blob = ns.PackItems(list, base)
  local back = ns.UnpackItems(blob, base)
  if not back then error(label .. ": unpack failed") end
  eq(#back, #list, label .. " count")
  for i = 1, #list do
    eq(back[i][1], tostring(list[i][1]), label .. " key " .. i)
    eq(back[i][2], list[i][2], label .. " price " .. i)
    eq(back[i][3], (list[i][3] or 0) > 0 and list[i][3] or 0, label .. " avail " .. i)
    local ts = list[i][4]
    if ts < base then ts = base end
    eq(back[i][4], ts, label .. " ts " .. i)
  end
  return blob
end

roundtrip({}, 0, "empty")
assert(ns.UnpackItems("", 0) == nil, "empty string should fail")
assert(ns.UnpackItems(string.char(1) .. "garbage", 0) == nil, "truncated should fail")

roundtrip({
  { "25", 100, 0, 1000 },
  { "30", 250000, 4, 1005 },
  { "100000", 9999999999, 0, 1500 },
  { "g:12345:63", 50000, 1, 1600 },
  { "g:12345:70", 80000, 0, 1600 },
  { "gr:999:5", 10, 2, 1700 },
  { "p:123:456", 77, 0, 1800 },
}, 1000, "mixed")

-- Times before the batch base are stored as the base (the sender always uses the minimum).
local clamped = ns.UnpackItems(ns.PackItems({ { "1", 5, 0, 10 } }, 50), 50)
eq(clamped[1][4], 50, "clamped ts")

-- A few thousand, including runs of gear, to exercise deltas.
local many, base = {}, 1700000000
for i = 1, 4000 do
  local ts = base + (i * 17) % 500000
  if i % 5 == 0 then
    many[i] = { string.format("g:%d:%d", 10000 + (i % 800), i % 40), 1000 + i * 13, i % 7, ts }
  elseif i % 5 == 1 then
    many[i] = { string.format("gr:%d:%d", 20000 + (i % 300), i % 12), 50 + i, 0, ts }
  else
    many[i] = { tostring(i), 10000 + i * 97, (i % 11 == 0) and 3 or 0, ts }
  end
end
local blob = roundtrip(many, base, "many")
print(string.format("round-trip ok, 4000 prices pack to %d bytes (%.2f each)", #blob, #blob / 4000))

-- Megaserver-sized list: plain ids plus gear, the shape a full faction scan has.
math.randomseed(1)
local big = {}
local nPlain, nGear = 56000, 24000
for i = 1, nPlain do
  big[i] = { tostring(i), math.random(50, 5000000), (i % 9 == 0) and math.random(1, 20) or 0,
    base + math.random(0, 60 * 86400) }
end
for i = 1, nGear do
  big[nPlain + i] = { string.format("g:%d:%d", math.random(1, 30000), math.random(1, 90)),
    math.random(1000, 20000000), 0, base + math.random(0, 60 * 86400) }
end
-- Sort the way SendEntries does, so deltas apply.
for i = 1, #big do
  local k, id, ex = ns.KeyParts(big[i][1])
  big[i][5], big[i][6], big[i][7] = k, id, ex
end
table.sort(big, function(a, b)
  if a[5] ~= b[5] then return a[5] < b[5] end
  if a[6] ~= b[6] then return a[6] < b[6] end
  return (a[7] or 0) < (b[7] or 0)
end)
local t0 = os.clock()
local bigBlob = ns.PackItems(big, base)
local back = ns.UnpackItems(bigBlob, base)
if not back or #back ~= #big then error("big round-trip count") end
for i = 1, #big, 997 do
  if back[i][1] ~= big[i][1] or back[i][2] ~= big[i][2] or back[i][4] ~= big[i][4] then
    error("big round-trip mismatch at " .. i)
  end
end
print(string.format("%d prices pack to %d bytes (%.2f each) in %.2fs", #big, #bigBlob, #bigBlob / #big, os.clock() - t0))

local f = assert(io.open("/tmp/aucsync_pack.bin", "wb"))
f:write(bigBlob)
f:close()

-- A stand-in for the old quad array: one CBOR-ish integer per field, no delta, no deflate yet.
local function varint(n, out)
  n = math.floor(n)
  if n < 0 then n = 0 end
  while n >= 128 do
    out[#out + 1] = string.char(128 + (n % 128))
    n = math.floor(n / 128)
  end
  out[#out + 1] = string.char(n)
end
local old = {}
for i = 1, #big do
  local kind, id, extra = ns.KeyParts(big[i][1])
  if kind == 0 then
    varint(id, old)
  else
    local s = big[i][1]
    varint(#s, old)
    old[#old + 1] = s
  end
  varint(big[i][2], old)
  varint(big[i][3] or 0, old)
  varint(big[i][4] - base, old)
end
local oldBlob = table.concat(old)
local g = assert(io.open("/tmp/aucsync_old.bin", "wb"))
g:write(oldBlob)
g:close()
print(string.format("old-style quad (no deflate) %d bytes (%.2f each)", #oldBlob, #oldBlob / #big))
