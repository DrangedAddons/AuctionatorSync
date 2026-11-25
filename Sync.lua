-- The sync itself (protocol 5).
--
-- Auctionator keeps, per item, the last seen price (m) and per-day history (h/l/a), but not
-- *when* during the day a price was seen. AuctionatorSync keeps its own timestamp per item:
--   ts[key] = when this price was last seen (by me or a friend) - the newer one always wins
-- Merging is newest-wins per item (ties: the lower price), so merges give the same result in any
-- order: two versions of the list are combined by any exchange between them, nothing is lost.
--
-- The master list: each player has a fingerprint of their whole price list (one sum of every
-- item+price hash, plus the count). The master list is the fingerprint holding the newest
-- price; "in sync" means holding it. A fingerprint says only "same or different". Which price
-- is newer is decided per item. Prices are also split into 4096 sections so two lists can be
-- compared by sending the section stamps (a few kilobytes) and then only the sections that
-- differ - a handful of prices each - instead of both whole lists.
--
-- Two things start a sync:
--   1. Someone comes online whose list differs from the player with the newest prices. The one
--      who is behind sends their section stamps. The other answers with the sections that
--      differ, and both broadcast just those sections, once, for everyone to merge.
--   2. Your Auctionator prices change (a full scan finishes, or you close the auction house
--      after searching): your changed prices go to everyone online.
-- A transfer that stops partway continues from the last batch that went out. Slowness does not
-- throw that progress away. Safety net: still different from the newest list after a short wait,
-- and nothing is already being sent, -> compare again. Only the sections that still differ move.
--
-- Messages (hidden addon data; all carry r = Auctionator's realm key and sid, a per-login ID):
--   HELLO {st, d, os, w, ls, nt, hl, pg}  I'm here -> everyone; answered by STATE
--   STATE {...same}     state, fingerprint, online since, syncing with, last sync, newest price,
--                       hosting load, handshake progress; also a heartbeat every minute
--   SUM   {hb}          the player who is behind -> the one with newer prices: 4096 section
--                       stamps, 4 bytes each (hash of that section's prices, mixed with how many)
--   NEED  {bk}          answer: the section numbers that differ (empty = already in sync)
--   DATA  {x, z, b, k?, fin?, tot?}  prices. z is a packed batch (Codec.lua), b the base time;
--                       k = "sync" (a section exchange) or nil (a scan / search share).
--                       Older batches used e = {key, price, available, ts - b, ...} and still decode.
local _, ns = ...

local BATCH = 2000          -- prices per DATA message; larger packs (and compresses) much better
local HELLO_WAIT = 5        -- seconds to collect answers to a HELLO
local JOIN_TIMEOUT = 600    -- seconds with no batch before a half-received transfer is forgotten
local HEARTBEAT = 60        -- seconds between STATE heartbeats
local HEAL_AFTER = 45       -- seconds out of sync before comparing again (a retry only sends what differs)
local COMPARE_TIMEOUT = 45  -- seconds to answer once the section stamps have actually been sent
local BENCH_TIME = 120      -- didn't answer the compare: not asked again for this long
local WAIT_LIMIT = 60       -- looking for someone to compare with longer than this: carry on, retry later
local SECTIONS = 4096       -- fine sections: one changed price no longer drags hundreds of others with it
local STAMP_MIX = 2654435761
local TS_KEEP_DAYS = 60
local TWO32 = 4294967296

local floor = math.floor

local function DB() return Auctionator and Auctionator.Database end

function ns.RealmKey()
  if Auctionator and Auctionator.State and Auctionator.State.CurrentRealm then
    return Auctionator.State.CurrentRealm
  end
  if Auctionator and Auctionator.Variables and Auctionator.Variables.GetConnectedRealmRoot then
    return Auctionator.Variables.GetConnectedRealmRoot()
  end
end

local function Realm()
  local key = ns.RealmKey()
  if not key then return nil end
  local r = ns.store.realms[key]
  if not r then
    r = { ts = {}, lastCatchUp = 0 }
    ns.store.realms[key] = r
  end
  return r
end

local function DayZero()
  return Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0 or 0
end

-- When this price was seen: our own timestamp, or (for prices from before AuctionatorSync)
-- the start of the newest day in Auctionator's history.
local function SeenAt(r, key, entry)
  local ts = r.ts[key]
  if ts then return ts end
  if type(entry) ~= "table" or type(entry.h) ~= "table" then return 0 end
  local newest
  for day in pairs(entry.h) do
    day = tonumber(day)
    if day and (not newest or day > newest) then newest = day end
  end
  ts = newest and (DayZero() + newest * 86400) or 0
  -- Remember it. Walking every item's history on each sync is what made a megaserver list hitch.
  if ts > 0 then r.ts[key] = ts end
  return ts
end

-- Auctionator keys: "12345" (item), "g:12345:<item level>" (gear), "gr:12345:<suffix>" (older
-- random-suffix gear, e.g. "of the Bear"), "p:..." (battle pet).
function ns.ItemIDFromKey(key)
  key = tostring(key)
  return tonumber(key:match("^(%d+)$") or key:match("^gr?:(%d+)"))
end

-- For the Price List: every priced item as { key, price, seen at, available that day }.
function ns.PriceEntries()
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  for key, entry in pairs(db.db) do
    if type(entry) == "table" and (entry.m or 0) > 0 then
      local ts = SeenAt(r, tostring(key), entry)
      local day = entry.a and tostring(floor((ts - DayZero()) / 86400))
      list[#list + 1] = { tostring(key), entry.m, ts, day and entry.a[day] or nil }
    end
  end
  return list
end

-- The latest price change (the "price check" item in /async). synced = came in through a sync.
local function NoteChange(r, key, price, was, synced)
  if not ns.ItemIDFromKey(key) then return end
  local c = r.lastChange or {}
  c.key, c.price, c.was, c.from, c.at = key, price, was, synced or nil, ns.Now()
  r.lastChange = c
end

function ns.LastChange()
  local key = ns.RealmKey()
  local r = key and ns.store and ns.store.realms[key]
  return r and r.lastChange
end

----------------------------------------------------------------------------------------------
-- Fingerprint: each section is the sum (mod 2^32) of hash(item, price) for its items.
-- The stamp shared on the wire mixes in how many items the section holds, so two sections
-- with the same prices but a different population don't compare equal.

local sections, sectionCount, sectionKeys, itemCount = {}, {}, {}, 0
local newestTs = 0 -- when the newest price in this list was seen (shared as nt)
function ns.NewestPrice() return newestTs end
for i = 0, SECTIONS - 1 do
  sections[i] = 0
  sectionCount[i] = 0
  sectionKeys[i] = {}
end

local function Hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % TWO32 end
  return h
end

local function SectionOf(key) return Hash(key) % SECTIONS end

ns.dataVersion = 0 -- bumped on every price / seen-time change (the Price List rebuilds on it)

local function Track(key, oldPrice, newPrice)
  local original = key
  key = tostring(key)
  local s = SectionOf(key)
  if oldPrice and oldPrice > 0 then
    sections[s] = (sections[s] - Hash(key .. ":" .. oldPrice)) % TWO32
    itemCount = itemCount - 1
    sectionCount[s] = sectionCount[s] - 1
    if sectionCount[s] < 0 then sectionCount[s] = 0 end
    if not (newPrice and newPrice > 0) then sectionKeys[s][key] = nil end
  end
  if newPrice and newPrice > 0 then
    sections[s] = (sections[s] + Hash(key .. ":" .. newPrice)) % TWO32
    itemCount = itemCount + 1
    sectionCount[s] = sectionCount[s] + 1
    sectionKeys[s][key] = original
  end
end

local function Stamp(i)
  return (sections[i] + sectionCount[i] * STAMP_MIX) % TWO32
end

-- 4096 little-endian stamps, one compare for the whole list.
local function PackStamps()
  local chars = {}
  for i = 0, SECTIONS - 1 do
    local n = Stamp(i)
    chars[i + 1] = string.char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
  end
  return table.concat(chars)
end

-- Section numbers whose stamp doesn't match ours, or nil if this isn't our stamp blob.
local function DiffStamps(hb)
  if type(hb) ~= "string" or #hb ~= SECTIONS * 4 then return nil end
  local diff = {}
  for i = 0, SECTIONS - 1 do
    local o = i * 4 + 1
    local b1, b2, b3, b4 = hb:byte(o, o + 3)
    local stamp = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if stamp ~= Stamp(i) then diff[#diff + 1] = i end
  end
  return diff
end

function ns.Fingerprint()
  local total = 0
  for i = 0, SECTIONS - 1 do total = (total + sections[i]) % TWO32 end
  return string.format("%08x-%d", total, itemCount)
end

local function RebuildFingerprint(data)
  for i = 0, SECTIONS - 1 do
    sections[i] = 0
    sectionCount[i] = 0
    wipe(sectionKeys[i])
  end
  itemCount = 0
  for key, entry in pairs(data) do
    if type(entry) == "table" then Track(key, nil, entry.m) end
  end
end

----------------------------------------------------------------------------------------------
-- Watching Auctionator: prices you scan or search

-- What each item's price was before Auctionator's SetPrice overwrote it (the hook runs after).
local known = {}
local hookedDB
local hookFailed -- logged once
local pending = {} -- key -> price before your latest scan/search changed it (to share)

local function OnLocalPrice(key, price, available)
  price = tonumber(price)
  local r = Realm()
  if not r or key == nil or not price then return end
  key = tostring(key)
  r.ts[key] = ns.Now()
  newestTs = math.max(newestTs, r.ts[key])
  ns.dataVersion = ns.dataVersion + 1
  local before = known[key]
  if before == price then return end -- same price seen again: nothing changed
  if pending[key] == nil then pending[key] = before or 0 end
  Track(key, before, price)
  NoteChange(r, key, price, before, nil)
  known[key] = price
end

-- Auctionator can rebuild its database object (e.g. when you clear it), so keep checking.
function ns.HookAuctionator()
  local db = DB()
  if not db or db == hookedDB or type(db.SetPrice) ~= "function" then return end
  hookedDB = db
  wipe(known)
  if type(db.db) == "table" then
    for key, entry in pairs(db.db) do
      if type(entry) == "table" then known[tostring(key)] = entry.m end
    end
    RebuildFingerprint(db.db)
  end
  local r = Realm()
  if r then
    for _, ts in pairs(r.ts) do if ts > newestTs then newestTs = ts end end
  end
  -- Auctionator calls SetPrice from its scan-processing ticker without a pcall: an error here
  -- would make that ticker fail on the same item every frame and the scan never finishes.
  hooksecurefunc(db, "SetPrice", function(self, key, price, available)
    if self ~= hookedDB then return end
    local ok, err = pcall(OnLocalPrice, key, price, available)
    if not ok and not hookFailed then
      hookFailed = true
      ns.Log("couldn't record a price from Auctionator: %s", tostring(err))
    end
  end)
  ns.Detail("watching Auctionator's prices for %s: %s, fingerprint %s",
    tostring(ns.RealmKey()), ns.Plural(itemCount, "price"), ns.Fingerprint())
end

----------------------------------------------------------------------------------------------
-- Writing prices into Auctionator

-- Newest wins. Same time, different price (rare): the lower price wins, the same on every
-- player, so everyone ends up with the same list. force = the host's merged value (a handshake
-- reply), taken as-is.
-- Returns "changed" (written), "same" (only our timestamp moved) or nil (ours kept).
local function Apply(r, key, price, available, ts, force)
  local db = DB()
  local data = db and db.db
  if type(data) ~= "table" then return nil end
  key = tostring(key)
  price, available, ts = tonumber(price), tonumber(available), tonumber(ts)
  if not price or price <= 0 or not ts then return nil end
  ts = math.min(ts, ns.Now())

  local entry = data[key]
  if entry ~= nil and type(entry) ~= "table" then return nil end
  if not entry then entry = { l = {}, h = {}, a = {}, m = 0 } end

  local mine = SeenAt(r, key, entry)
  if not force then
    if ts < mine then return nil end
    if ts == mine and (entry.m or 0) > 0 and price >= entry.m then return nil end
  end
  if ts > mine then
    r.ts[key] = ts
    newestTs = math.max(newestTs, ts)
    ns.dataVersion = ns.dataVersion + 1
  end
  if entry.m == price then return "same" end

  local was = entry.m
  entry.m = price
  entry.l = entry.l or {}
  entry.h = entry.h or {}
  data[key] = entry
  Track(key, was, price)
  known[key] = price
  pending[key] = nil -- a newer price from a friend replaces ours: nothing of ours left to share

  local day = floor((ts - DayZero()) / 86400)
  if not db.cutoffDay or day > db.cutoffDay then
    local d = tostring(day)
    local highest = entry.h[d]
    if highest == nil or price > highest then
      entry.h[d] = price
      highest = price
    end
    if price < highest and (entry.l[d] == nil or price < entry.l[d]) then
      entry.l[d] = price
    end
    if available and available > 0 then
      entry.a = entry.a or {}
      entry.a[d] = math.max(entry.a[d] or 0, available)
    end
  end
  NoteChange(r, key, price, was, true)
  return "changed", was
end

-- One price as sent on the wire: {key, price, available that day, seen at}
local function Item(r, key, entry)
  local ts = SeenAt(r, key, entry)
  local day = entry.a and tostring(floor((ts - DayZero()) / 86400))
  return { key, entry.m, day and entry.a[day] or 0, ts }
end

-- Every price in the given sections (a set of section numbers). The section index is kept as
-- prices change, so this doesn't walk the whole auction database to find them.
local function ItemsInBuckets(set)
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  for b in pairs(set) do
    local keys = sectionKeys[b]
    if keys then
      for skey, original in pairs(keys) do
        local entry = db.db[original]
        if entry == nil and original ~= skey then entry = db.db[skey] end
        if type(entry) == "table" and (entry.m or 0) > 0 then
          list[#list + 1] = Item(r, skey, entry)
        end
      end
    end
  end
  return list
end

-- Stable order so a resumed transfer sends the same sequence, and so item ids delta-pack.
local function SortItems(list)
  for i = 1, #list do
    local kind, id, extra = ns.KeyParts(list[i][1])
    list[i][5], list[i][6], list[i][7] = kind, id, extra
  end
  table.sort(list, function(a, b)
    if a[5] ~= b[5] then return a[5] < b[5] end
    if a[6] ~= b[6] then return a[6] < b[6] end
    return (a[7] or 0) < (b[7] or 0)
  end)
end

-- Length, ends and a sum of the prices and times. Any change and this stops matching, so a
-- resumed transfer never skips a price that wasn't actually sent.
local function ListSig(list)
  if #list == 0 then return "0" end
  local price, ts = 0, 0
  for i = 1, #list do
    price = (price + (tonumber(list[i][2]) or 0)) % TWO32
    ts = (ts + (tonumber(list[i][4]) or 0)) % TWO32
  end
  return string.format("%d:%d:%d:%s:%s", #list, price, ts, tostring(list[1][1]), tostring(list[#list][1]))
end

----------------------------------------------------------------------------------------------
-- Sending prices

local transferCounter = 0

-- One transfer of BATCH-sized DATA messages, the last marked fin. target = nil -> everyone.
-- extra: fields copied onto every message (a handshake piece's bk / pc). Every message carries
-- tot (the transfer's size), and each batch logs when it has actually been sent.
local KIND_WORDS = { join = "handshake piece", reply = "handshake reply", fwd = "share-out",
  neutral = "neutral AH prices", sync = "section sync" }
ns.KIND_WORDS = KIND_WORDS

-- Transfers we're sending right now (for the Sync Monitor): { to, kind, tot, sent, started }
ns.outgoing = {}

function ns.SendEntries(target, list, prio, k, extra, opts)
  opts = opts or {}
  local legacy = k == "neutral" -- the neutral list still speaks the plain quad format
  if not legacy then SortItems(list) end
  local realm = ns.RealmKey()
  local n = #list
  local start = 0
  local r = Realm()
  -- Same list as one we were already sending (same length and ends): continue after the last
  -- batch that actually went out, instead of sending those prices again.
  if opts.remember and r and not legacy then
    local sig = ListSig(list)
    local prev = r.sendCursor
    if type(prev) == "table" and prev.id == opts.remember and prev.sig == sig and (prev.sent or 0) > 0
      and ns.Now() - (prev.time or 0) < 86400 then
      start = math.min(prev.sent, n)
    end
    opts.cursorSig = sig
    opts.cursorTime = (type(prev) == "table" and prev.sig == sig and prev.time) or ns.Now()
  end
  transferCounter = transferCounter + 1
  local x = transferCounter
  local label = string.format("%s -> %s", ns.MyName(), target and (target.name or "?") or "everyone")
  local what = KIND_WORDS[k] or "scan prices"
  local batches = math.max(1, math.ceil(math.max(n - start, 0) / BATCH))
  local out = { to = target and (target.name or "?") or "everyone", toKey = target and target.name and ns.ShortName(target.name),
    kind = k, tot = n, sent = start, started = ns.Now() }
  if start > 0 then
    ns.Log("%s continues a transfer already %s / %s sent", ns.MyName(), ns.Num(start), ns.Num(n))
  end
  if n == 0 then
    -- One empty final batch, so the other side isn't left waiting for prices we don't have.
    local msg = { t = "DATA", r = realm, x = x, b = 0, fin = true, k = k, tot = 0 }
    if legacy then msg.e = {} else msg.z = ns.PackItems({}, 0) end
    for field, value in pairs(extra or {}) do msg[field] = value end
    if target then ns.Send(target, msg, prio) else ns.Broadcast(msg, prio) end
    return out
  end
  if start >= n then
    if r and opts.remember then r.sendCursor = nil end
    return out
  end
  ns.outgoing[out] = true
  -- forget it if the throttle never reports the last batch (e.g. a disconnect)
  C_Timer.After(900, function() ns.outgoing[out] = nil end)

  local function Remember(sent)
    if not (opts.remember and r) then return end
    if sent >= n then
      r.sendCursor = nil
    else
      r.sendCursor = { id = opts.remember, sig = opts.cursorSig, sent = sent, time = opts.cursorTime }
    end
  end

  -- One batch at a time: the next is only queued once this one has actually gone out, so a
  -- transfer can be stopped midway (out.cancelled) instead of the whole thing sitting queued.
  local function SendBatch(i)
    if out.cancelled then
      ns.outgoing[out] = nil
      return
    end
    if i > n then
      ns.outgoing[out] = nil
      Remember(n)
      if ns.OnSendProgress then ns.OnSendProgress() end
      return
    end
    local last = math.min(i + BATCH - 1, n)
    local base = math.huge
    for j = i, last do base = math.min(base, list[j][4] or 0) end
    if base == math.huge then base = 0 end
    local msg = { t = "DATA", r = realm, x = x, b = base, fin = (last >= n) or nil, k = k, tot = n }
    if legacy then
      local e = {}
      for j = i, last do
        local it = list[j]
        e[#e + 1] = tonumber(it[1]) or it[1]
        e[#e + 1] = it[2]
        e[#e + 1] = it[3] or 0
        e[#e + 1] = it[4] - base
      end
      msg.e = e
    else
      local slice = {}
      for j = i, last do slice[#slice + 1] = list[j] end
      msg.z = ns.PackItems(slice, base)
    end
    for field, value in pairs(extra or {}) do msg[field] = value end
    local function onSent(ok)
      if out.cancelled then
        ns.outgoing[out] = nil
        return
      end
      if ok == false then
        out.fails = (out.fails or 0) + 1
        if out.fails >= 8 then
          ns.Log("%s stopped sending to %s (it kept failing)", ns.MyName(), out.to)
          out.cancelled = true
          ns.outgoing[out] = nil
          if ns.OnSendProgress then ns.OnSendProgress() end
          return
        end
        C_Timer.After(2, function() SendBatch(i) end)
        return
      end
      out.sent = math.max(out.sent, last)
      Remember(out.sent)
      if batches > 1 and n > 0 then
        ns.Detail("%s: sent %s / %s (%s, %d%%)", label, ns.Num(last), ns.Plural(n, "price"), what, floor(last / n * 100))
      end
      if out.sent >= n then ns.outgoing[out] = nil end
      if ns.OnSendProgress then ns.OnSendProgress() end
      ns.AnnounceState(true)
      if last < n then SendBatch(last + 1) end
    end
    local sent
    if target then sent = ns.Send(target, msg, prio, nil, onSent) else sent = ns.Broadcast(msg, prio, nil, onSent) end
    if not sent or sent == "" then
      out.fails = (out.fails or 0) + 1
      if out.fails >= 8 then
        ns.Log("%s stopped sending to %s (it kept failing)", ns.MyName(), out.to)
        out.cancelled = true
        ns.outgoing[out] = nil
        if ns.OnSendProgress then ns.OnSendProgress() end
        return
      end
      C_Timer.After(2, function() SendBatch(i) end)
    end
  end
  SendBatch(start + 1)
  return out -- { tot, sent, cancelled } for whoever wants to follow or stop it
end

-- Stop everything still unsent to one player (they reloaded, or went offline).
function ns.CancelTransfersTo(name, why)
  local key = ns.ShortName(name)
  local stopped = 0
  for out in pairs(ns.outgoing) do
    if out.toKey == key and not out.cancelled then
      out.cancelled = true
      ns.outgoing[out] = nil
      stopped = stopped + 1
    end
  end
  if ns.DropHostingFor then ns.DropHostingFor(key) end
  if stopped > 0 then
    ns.Log("%s stopped sending to %s (%s)", ns.MyName(), name, why)
    ns.AnnounceState()
  end
end

----------------------------------------------------------------------------------------------
-- Chat (only you see it, never names anyone; "Show chat messages" turns it off)

local REPORT_DELAY = 10
local reported, reportTimer = 0, nil

local function FlushReport()
  reportTimer = nil
  local total = reported
  reported = 0
  if total > 0 then ns.Notice("Updated %s.", ns.Plural(total, "price")) end
end

local function Report(changed)
  if changed <= 0 then return end
  reported = reported + changed
  if not reportTimer then reportTimer = C_Timer.NewTimer(REPORT_DELAY, FlushReport) end
end

-- The player asked (Sync now) -> always say; automatic -> only if ticked.
local function Say(verbose, fmt, ...)
  if verbose then ns.Print(fmt, ...) else ns.Notice(fmt, ...) end
end

----------------------------------------------------------------------------------------------
-- State, the master list, and who can host

ns.onlineSince = nil
ns.state = "starting" -- "waiting" (looking for hosts) | "syncing" (handshaking) | "ready"
ns.syncingWith = nil  -- "Lexi Ble" or "Lexi Ble +2" while handshaking
ns.syncProgress = nil -- 0..100 while handshaking

-- Last sync: when this character last finished a handshake (either side), received prices
-- from a sync, or shared its own scan. Shown per player in the online list.
local function MarkSynced()
  local r = Realm()
  if r then r.lastSync = ns.Now() end
end

function ns.LastSync()
  local r = Realm()
  return r and (r.lastSync or r.lastCatchUp)
end

-- Handshake pieces this character is serving right now (its "hosting" load).
local hosting = {} -- transfer key -> true
local replies = {} -- "<peerKey>#<piece id>" -> our reply transfer for that piece (stoppable by CANCEL)
local function HostingCount()
  local n = 0
  for _ in pairs(hosting) do n = n + 1 end
  return n
end
ns.HostingCount = HostingCount

local stateTimer
local function StateMsg(t)
  return { t = t or "STATE", r = ns.RealmKey(), st = ns.state, d = ns.Fingerprint(), os = ns.onlineSince,
    w = ns.syncingWith, ls = ns.LastSync(), nt = newestTs, hl = HostingCount(), pg = ns.syncProgress,
    rx = ns.Receiving and ns.Receiving() or 0, ph = ns.state == "syncing" and ns.syncPhase or nil,
    hs = ns.state == "syncing" and ns.syncStep or nil, hd = ns.state == "syncing" and ns.syncDone or nil,
    ht = ns.state == "syncing" and ns.syncTotal or nil, ra = (ns.ReceiveAmounts and select(1, ns.ReceiveAmounts())) or nil,
    rt = (ns.ReceiveAmounts and select(2, ns.ReceiveAmounts())) or nil, sa = (ns.SendAmounts and select(1, ns.SendAmounts())) or nil,
    st2 = (ns.SendAmounts and select(2, ns.SendAmounts())) or nil, hc = ns.MyHostsCount and ns.MyHostsCount() or nil,
    tg = ns.MyTarget and ns.MyTarget() or nil, rp = ns.ReceiveProgress and ns.ReceiveProgress() or nil,
    sp = ns.SendProgress and ns.SendProgress() or nil,
    nh = 1 } -- nh: keeps a neutral auction house list (1.4.0+), so it can answer NREQ
end

-- Tell everyone our state/fingerprint (debounced: several changes in a row send one message).
-- progressOnly: just a progress number moved. Those wait until PROGRESS_EVERY seconds after the
-- last announcement, so status messages don't eat the bandwidth the transfer itself needs.
-- Real changes (state, fingerprint, hosting...) still go out within 2 seconds.
local PROGRESS_EVERY = 10
local lastAnnounced = 0
local stateTimerProgressOnly = false
function ns.AnnounceState(progressOnly)
  if stateTimer then
    if progressOnly or not stateTimerProgressOnly then return end
    stateTimer:Cancel() -- a real change arrived while a progress-only update was waiting: hurry it
  end
  local delay = 2
  if progressOnly then delay = math.max(2, PROGRESS_EVERY - (GetTime() - lastAnnounced)) end
  stateTimer = C_Timer.NewTimer(delay, function()
    stateTimer = nil
    lastAnnounced = GetTime()
    if ns.RealmKey() then ns.Broadcast(StateMsg(), "NORMAL") end
  end)
  stateTimerProgressOnly = progressOnly and true or false
end

local function SetState(st, with)
  if st ~= ns.state then ns.stateSince = ns.Now() end
  ns.state, ns.syncingWith = st, with
  if st ~= "syncing" then ns.syncProgress = nil end
  ns.AnnounceState()
end

local function Compatible(peer)
  return (peer.proto or 1) >= ns.PROTOCOL and ns.VersionAtLeast(peer.version, ns.MIN_VERSION)
    and not peer.otherRealm
end

-- The master list: the version holding the newest price (whoever just scanned leads, and the
-- rest catch up as the share arrives). Equally new: the one most ready players hold, then the
-- smaller fingerprint text, so every player picks the same one. "In sync" means holding it.
-- Nobody owns it: two versions are simply merged by the next handshake.
function ns.Master()
  local votes, newest = {}, {}
  local function Vote(d, nt)
    if not d then return end
    votes[d] = (votes[d] or 0) + 1
    newest[d] = math.max(newest[d] or 0, tonumber(nt) or 0)
  end
  if ns.state == "ready" then Vote(ns.Fingerprint(), newestTs) end
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and Compatible(peer) and peer.st == "ready" then Vote(peer.d, peer.nt) end
  end
  local best
  for d, n in pairs(votes) do
    if not best or newest[d] > newest[best] or (newest[d] == newest[best]
      and (n > votes[best] or (n == votes[best] and d < best))) then
      best = d
    end
  end
  return best
end
ns.MasterFingerprint = ns.Master

-- Didn't answer a compare: left out of the next few, so one silent player doesn't stall the rest.
local benched = {} -- peerKey -> until (server time)

local function IsBenched(peer)
  local untilTs = benched[ns.ShortName(peer.name)]
  return untilTs ~= nil and untilTs > ns.Now()
end

local function Bench(peer, why)
  benched[ns.ShortName(peer.name)] = ns.Now() + BENCH_TIME
  ns.Log("%s isn't being asked to compare for %d min (%s)", peer.name, floor(BENCH_TIME / 60), why)
end

-- For the Sync Monitor: { { name, secondsLeft }, ... }
function ns.BenchedHosts()
  local list = {}
  for key, untilTs in pairs(benched) do
    local left = untilTs - ns.Now()
    if left > 0 then
      local peer = ns.peers[key]
      list[#list + 1] = { name = peer and peer.name or key, left = left }
    else
      benched[key] = nil
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

----------------------------------------------------------------------------------------------
-- Trigger 2: your prices changed (scan finished, or auction house closed after searching)

function ns.ShareChanges(why)
  local r, db = Realm(), DB()
  if not r or not db or type(db.db) ~= "table" or not next(pending) then return end
  local list = {}
  for key, before in pairs(pending) do
    local entry = db.db[key]
    if type(entry) == "table" and (entry.m or 0) > 0 and entry.m ~= before then
      list[#list + 1] = Item(r, key, entry)
    end
  end
  wipe(pending)
  if #list == 0 then return end
  local online = 0
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and Compatible(peer) then online = online + 1 end
  end
  if online == 0 then
    ns.Log("%s changed %s; nobody online, they go into %s's next handshake", why, ns.Plural(#list, "price"), ns.MyName())
    ns.AnnounceState()
    return
  end
  ns.Log("%s changed %s: sharing with %s", why, ns.Plural(#list, "price"), ns.Plural(online, "player"))
  -- A handful of search results jumps ahead of a big sync; a full scan shares the pipe with it.
  ns.SendEntries(nil, list, #list > 200 and "BULK" or "NORMAL")
  MarkSynced()
  ns.AnnounceState()
end

----------------------------------------------------------------------------------------------
-- Trigger 1: coming online. Compare sections with whoever has newer prices.
--
--   1. The player who is behind sends 4,096 section stamps (one small message) to the player
--      with the newest prices. Equal times break by name, so only one side of a pair starts it.
--   2. That player answers with the section numbers that differ and broadcasts their prices for
--      those sections. The asker broadcasts theirs. Everyone else hears both and merges them.
--   3. Several compares that arrive together are answered with one broadcast, not one each.
-- A slow send is left alone to finish. Only silence on the stamps (not a slow transfer) tries
-- someone else. Nothing is resent from the beginning while the same list is still going out.

local join -- { verbose, peer, bad, changed, answered, expectReply, gotReply, up, target }
local transfers = {}

-- Price transfers arriving right now.
function ns.Receiving()
  local n = 0
  for _ in pairs(transfers) do n = n + 1 end
  return n
end

function ns.IsSending()
  for _ in pairs(ns.outgoing) do return true end
  return false
end

-- For the Sync Monitor (and shared in STATE so others can show it too).
function ns.MyHostsCount()
  return join and 1 or nil
end

function ns.MyTarget() return join and join.target or nil end

function ns.ReceiveAmounts()
  local got, tot = 0, 0
  for _, tr in pairs(transfers) do
    if tr.tot then got, tot = got + tr.received, tot + tr.tot end
  end
  return got, tot
end

function ns.ReceiveProgress()
  local got, tot = ns.ReceiveAmounts()
  return tot > 0 and floor(got / tot * 100) or nil
end

-- What we're sending outside the compare itself (a scan share, a section broadcast we host).
function ns.SendAmounts()
  local sent, tot = 0, 0
  local mine = join and join.up
  for out in pairs(ns.outgoing) do
    if out ~= mine then sent, tot = sent + out.sent, tot + out.tot end
  end
  return sent, tot
end

function ns.SendProgress()
  local sent, tot = ns.SendAmounts()
  return tot > 0 and floor(sent / tot * 100) or nil
end

-- My transfers in detail, for my own rows in the Sync Monitor.
function ns.MyTransfers()
  local list = {}
  for out in pairs(ns.outgoing) do
    list[#list + 1] = { dir = "out", who = out.to, kind = out.kind, done = out.sent, tot = out.tot, started = out.started }
  end
  for _, tr in pairs(transfers) do
    if tr.tot then
      list[#list + 1] = { dir = "in", who = tr.from, kind = tr.kind, done = tr.received, tot = tr.tot, started = tr.started }
    end
  end
  return list
end

function ns.Pieces()
  if not join or not join.answered then return {} end
  return { { host = join.peer.name, sections = join.sections or 0, done = join.gotReply,
    got = join.got or 0, tot = join.replyTot } }
end

function ns.IsCompatible(peer) return Compatible(peer) end

-- Progress over the compare: stamps, then our prices out, then theirs back.
local function UpdateProgress()
  if not join then return end
  ns.syncingWith = join.peer and join.peer.name
  if not join.answered then
    ns.syncProgress = 1
    ns.syncPhase = "comparing - waiting for " .. (join.peer and join.peer.name or "them")
    ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
    ns.AnnounceState(true)
    return
  end
  local upDone = join.up and join.up.sent or 0
  local upTot = join.up and join.up.tot or 0
  local inDone = join.got or 0
  local inTot = join.replyTot
  if not join.expectReply then
    ns.syncStep, ns.syncDone, ns.syncTotal = "sending", upDone, upTot
    ns.syncProgress = upTot > 0 and math.min(99, math.max(1, floor(upDone / upTot * 100))) or 1
  elseif not inTot then
    if upDone < upTot then
      ns.syncStep, ns.syncDone, ns.syncTotal = "sending", upDone, upTot
    else
      ns.syncStep, ns.syncDone, ns.syncTotal = "receiving", inDone, nil
    end
    local pct = upTot > 0 and floor(upDone / upTot * 50) or 1
    ns.syncProgress = math.max(1, math.min(50, pct))
  else
    if upDone < upTot then
      ns.syncStep, ns.syncDone, ns.syncTotal = "sending", upDone, upTot
    else
      ns.syncStep, ns.syncDone, ns.syncTotal = "receiving", inDone, inTot
    end
    local total = upTot + inTot
    ns.syncProgress = total > 0 and math.min(99, math.max(1, floor((upDone + inDone) / total * 100))) or 1
  end
  ns.syncPhase = ns.syncTotal and string.format("%s %s / %s", ns.syncStep, ns.Num(ns.syncDone or 0), ns.Num(ns.syncTotal))
    or (ns.syncStep or "syncing")
  ns.AnnounceState(true)
end

local function FinishJoin(verbose, changed, via)
  local r = Realm()
  if join and join.timer then join.timer:Cancel() end
  join = nil
  local master = ns.Master()
  if r and (not master or ns.Fingerprint() == master) then r.lastCatchUp = ns.Now() end
  MarkSynced()
  SetState("ready")
  if via then ns.Log("%s is in sync (via %s)", ns.MyName(), via) end
  if changed and changed > 0 then
    Say(verbose, "Synced: updated %s.", ns.Plural(changed, "price"))
  elseif via then
    Say(verbose, "Up to date.")
  end
end

-- Upload finished (or there was nothing to send) and, when we expect their prices, those have
-- arrived too.
local function MaybeFinish()
  if not join or not join.answered then return end
  local up = join.up
  if up and up.cancelled then return end -- failed or replaced; the watchdog or the new compare owns it
  local upDone = not up or (up.sent >= up.tot)
  if upDone and (join.gotReply or not join.expectReply) then
    FinishJoin(join.verbose, join.changed, join.peer and join.peer.name)
  end
end

ns.OnSendProgress = function()
  if not join then return end
  UpdateProgress()
  MaybeFinish()
end

local RetrySoon
local CompareTimedOut

local function GiveUp()
  local verbose = join and join.verbose
  ns.Log("%s couldn't finish comparing: nobody answered; trying again shortly", ns.MyName())
  Say(verbose, "Couldn't finish syncing; it'll try again shortly.")
  FinishJoin(verbose, join and join.changed, nil)
  RetrySoon()
end

-- The one who is behind starts the compare. Newer prices win the tie; equal times, one name does,
-- so two players never both send their whole differing set at the same moment.
local function ShouldSyncWith(peer)
  if not (ns.IsPeerOnline(peer) and Compatible(peer) and peer.d and peer.d ~= ns.Fingerprint()) then
    return false
  end
  local myNt, theirNt = newestTs, tonumber(peer.nt) or 0
  if myNt ~= theirNt then return myNt < theirNt end
  return ns.MyName() > peer.name
end

local function PickPeer(bad)
  local best
  for _, peer in pairs(ns.peers) do
    if ShouldSyncWith(peer) and not (bad and bad[peer]) and not IsBenched(peer) then
      local nt = tonumber(peer.nt) or 0
      local bestNt = best and (tonumber(best.nt) or 0) or -1
      if not best or nt > bestNt or (nt == bestNt and peer.name < best.name) then best = peer end
    end
  end
  return best
end

local function StartSync(verbose, peer)
  local bad = join and join.bad or {}
  if join then
    if join.up then join.up.cancelled = true end
    if join.timer then join.timer:Cancel() end
  end
  join = { verbose = verbose, peer = peer, bad = bad, changed = 0, started = ns.Now(),
    target = ns.Master(), answered = false, expectReply = false, gotReply = false, got = 0 }
  SetState("syncing", peer.name)
  ns.syncProgress = 0
  ns.Log("%s is comparing prices with %s", ns.MyName(), peer.name)
  ns.syncPhase = "comparing - waiting for " .. peer.name
  ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
  local mine = join
  -- The stamps themselves can take a little while to send. The answer is timed from when they
  -- have gone out; if they never do, give up.
  join.timer = C_Timer.NewTimer(120, function()
    if join == mine and not mine.answered then CompareTimedOut(mine) end
  end)
  ns.Send(ns.ReplyTarget(peer), { t = "SUM", r = ns.RealmKey(), hb = PackStamps() }, "ALERT", nil, function(ok)
    if join ~= mine or mine.answered or ok == false then return end
    mine.sumsSent = true
    if join.timer then join.timer:Cancel() end
    join.timer = C_Timer.NewTimer(COMPARE_TIMEOUT, function() CompareTimedOut(mine) end)
    ns.Detail("%s sent its section stamps to %s", ns.MyName(), peer.name)
  end)
  UpdateProgress()
end

CompareTimedOut = function(mine)
  if join ~= mine or mine.answered then return end
  local peer = mine.peer
  if mine.timer then mine.timer:Cancel(); mine.timer = nil end
  mine.bad[peer] = true
  Bench(peer, string.format("no answer to the compare in %ds", COMPARE_TIMEOUT))
  local nextPeer = PickPeer(mine.bad)
  if nextPeer then
    ns.Log("%s didn't answer; comparing with %s instead", peer.name, nextPeer.name)
    StartSync(mine.verbose, nextPeer)
  else
    GiveUp()
  end
end

local RETRY_AFTER = 20
local retryPending = false
RetrySoon = function()
  if retryPending then return end
  retryPending = true
  C_Timer.After(RETRY_AFTER, function()
    retryPending = false
    if join or ns.state ~= "ready" or ns.IsScanning() or ns.IsSending() then return end
    local peer = PickPeer()
    if peer then
      ns.Log("%s retries comparing with %s", ns.MyName(), peer.name)
      StartSync(false, peer)
    end
  end)
end

-- Answering compares. Held for a few seconds so several people logging in get one broadcast.
local respondQueue = {}
local respondTimer

local function SendSections(set)
  local list = ItemsInBuckets(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  ns.Log("%s shares %s from %d sections", ns.MyName(), ns.Plural(#list, "price"), n)
  return ns.SendEntries(nil, list, "BULK", "sync", nil, { remember = "buckets" })
end

local function FlushResponses()
  respondTimer = nil
  local jobs = respondQueue
  respondQueue = {}
  local union = {}
  for _, job in pairs(jobs) do
    for i = 1, #job.diff do union[job.diff[i]] = true end
  end
  if next(union) then SendSections(union) end
  local realm = ns.RealmKey()
  for _, job in pairs(jobs) do
    ns.Send(ns.ReplyTarget(job.peer), { t = "NEED", r = realm, bk = job.diff }, "ALERT")
  end
end

local function QueueResponse(peer, diff)
  if #diff == 0 then
    ns.Send(ns.ReplyTarget(peer), { t = "NEED", r = ns.RealmKey(), bk = {} }, "ALERT")
    ns.Log("%s's prices already match %s's", peer.name, ns.MyName())
    return
  end
  respondQueue[ns.ShortName(peer.name)] = { peer = peer, diff = diff }
  if not respondTimer then respondTimer = C_Timer.NewTimer(5, FlushResponses) end
end

local function ItemsFromMsg(msg)
  local base = tonumber(msg.b) or 0
  if type(msg.z) == "string" then
    local ok, items = pcall(ns.UnpackItems, msg.z, base)
    if ok and type(items) == "table" then return items end
    ns.Log("couldn't read a price batch; that batch was skipped")
    return nil
  end
  local e = msg.e
  if type(e) ~= "table" then return nil end
  local list = {}
  for i = 1, #e - 3, 4 do
    list[#list + 1] = { tostring(e[i]), tonumber(e[i + 1]), tonumber(e[i + 2]) or 0,
      base + (tonumber(e[i + 3]) or 0) }
  end
  return list
end

-- NEED: which of our sections differ from theirs. Broadcast just those, and wait for theirs.
local function HandleNeed(peer, msg)
  if not join or join.peer ~= peer or join.answered then return end
  join.answered = true
  if join.timer then join.timer:Cancel(); join.timer = nil end
  local bk = type(msg.bk) == "table" and msg.bk or {}
  if #bk == 0 then
    ns.Log("%s's prices already match %s's", ns.MyName(), peer.name)
    FinishJoin(join.verbose, join.changed, peer.name)
    return
  end
  local set, n = {}, 0
  for i = 1, #bk do
    local b = tonumber(bk[i])
    if b and sectionKeys[b] then
      set[b] = true
      n = n + 1
    end
  end
  join.sections = n
  join.expectReply = true
  local list = ItemsInBuckets(set)
  ns.Log("%s is syncing %s across %d sections with %s", ns.MyName(), ns.Plural(#list, "price"), n, peer.name)
  join.up = ns.SendEntries(nil, list, "BULK", "sync", nil, { remember = "buckets" })
  UpdateProgress()
  MaybeFinish()
end

-- DATA, packed or in the older quad layout. Newest-wins; a batch is never forced over a newer price.
local function IngestPrices(msg, peer, r)
  local items = ItemsFromMsg(msg)
  if not items then return end
  local tkey = ns.ShortName(peer.name) .. "/" .. tostring(msg.x)
  local tr = transfers[tkey]
  if not tr then
    tr = { kind = msg.k or "update", changed = 0, received = 0, from = peer.name, started = ns.Now() }
    transfers[tkey] = tr
    ns.AnnounceState()
  end
  for i = 1, #items do
    local it = items[i]
    tr.received = tr.received + 1
    if Apply(r, it[1], it[2], it[3], it[4], false) == "changed" then tr.changed = tr.changed + 1 end
  end
  tr.tot = tonumber(msg.tot) or tr.tot
  local mine = join and peer == join.peer and (tr.kind == "sync" or tr.kind == "reply")
  if mine then
    join.got = tr.received
    join.replyTot = tr.tot
    UpdateProgress()
  elseif tr.kind ~= "join" then
    ns.AnnounceState(true)
  end
  local tot = tr.tot
  if tot and tot > BATCH and tr.received > 0 then
    ns.Detail("%s <- %s: %s / %s (%s, %d%%)", ns.MyName(), peer.name, ns.Num(tr.received),
      ns.Plural(tot, "price"), KIND_WORDS[tr.kind] or "scan prices", floor(tr.received / tot * 100))
  end
  if tr.timer then tr.timer:Cancel() end
  if not msg.fin then
    tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
      if transfers[tkey] == tr then transfers[tkey] = nil end
      ns.Log("prices from %s stopped arriving partway (%s kept)", peer.name, ns.Plural(tr.changed, "change"))
    end)
    return
  end
  transfers[tkey] = nil
  if mine then
    join.gotReply = true
    join.changed = join.changed + tr.changed
    UpdateProgress()
    MaybeFinish()
    return
  end
  if tr.received > 0 then
    if tr.kind == "sync" then
      ns.Log("%s shared %s: %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
    elseif tr.kind ~= "join" then
      ns.Log("%s shared %s from their scan: %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
    end
  end
  MarkSynced()
  Report(tr.changed)
  ns.AnnounceState()
end

-- Login / Sync now: find who's online, then compare with whoever has newer prices.
function ns.CatchUp(verbose)
  local r = Realm()
  if not r then
    Say(verbose, "Auctionator's prices aren't loaded yet; try again in a moment.")
    return
  end
  if ns.IsScanning() then
    ns.Log("%s's sync is waiting for the Auctionator scan to finish", ns.MyName())
    if verbose then ns.Print("Waiting for the Auctionator scan to finish first.") end
    ns.DeferSync(verbose)
    return
  end
  if join then
    Say(verbose, "Already syncing.")
    return
  end
  if verbose then ns.ShareChanges(ns.MyName() .. "'s auction house searches") end
  if ns.state ~= "ready" then SetState("waiting") end
  ns.JoinChannel()
  local routes = ns.Broadcast(StateMsg("HELLO"), "ALERT", true)
  ns.Detail("looking for players with AuctionatorSync (%s)", routes ~= "" and routes or "no routes")
  if verbose then ns.Print("Syncing...") end
  C_Timer.After(HELLO_WAIT, function()
    if join then return end
    local answered = {}
    for _, peer in pairs(ns.peers) do
      if ns.IsPeerOnline(peer) then
        local extra = not Compatible(peer) and ("v" .. tostring(peer.version) .. ", can't sync")
          or ((peer.st or "?") .. ((peer.hl or 0) > 0 and (", hosting " .. peer.hl) or ""))
        answered[#answered + 1] = string.format("%s (%s)", peer.name, extra)
      end
    end
    table.sort(answered)
    if #answered > 0 then
      ns.Detail("online: %s", table.concat(answered, ", "))
    else
      ns.Detail("nobody else online with AuctionatorSync")
    end

    local peer = PickPeer()
    if peer then
      StartSync(verbose, peer)
      return
    end
    -- Nobody is ahead of us (alone, we're the newest, or the only candidates are benched).
    local differs = false
    for _, p in pairs(ns.peers) do
      if ns.IsPeerOnline(p) and Compatible(p) and p.d and p.d ~= ns.Fingerprint() then differs = true end
    end
    if not differs then
      if ns.state == "ready" then
        Say(verbose, "Up to date (holding the master list).")
      else
        ns.Log("%s starts the master list (%s)", ns.MyName(), ns.Plural(itemCount, "price"))
        Say(verbose, #answered > 0 and "Up to date." or "No one online with AuctionatorSync yet. These prices join the next sync.")
      end
      SetState("ready")
    else
      -- They'll compare with us (we have the newer prices), or the one we wanted is benched.
      ns.Log("%s is waiting to compare (%s)", ns.MyName(), ns.Plural(itemCount, "price"))
      SetState("ready")
      RetrySoon()
    end
  end)
end

----------------------------------------------------------------------------------------------
-- Messages

local function NoteState(peer, msg, isHello)
  local was, wasD, wasOffline, wasHl = peer.st, peer.d, peer.lastHeard == nil, peer.hl or 0
  peer.st, peer.d, peer.os, peer.w = msg.st, msg.d, tonumber(msg.os), msg.w
  peer.ls, peer.nt, peer.hl, peer.pg = tonumber(msg.ls), tonumber(msg.nt), tonumber(msg.hl) or 0, tonumber(msg.pg)
  peer.rx = tonumber(msg.rx) or 0
  peer.hc, peer.tg, peer.rp, peer.sp = tonumber(msg.hc), msg.tg, tonumber(msg.rp), tonumber(msg.sp)
  peer.ph = msg.ph
  peer.nh = msg.nh and true or nil
  peer.hs, peer.hd, peer.ht = msg.hs, tonumber(msg.hd), tonumber(msg.ht)
  peer.ra, peer.rt, peer.sa, peer.st2 = tonumber(msg.ra), tonumber(msg.rt), tonumber(msg.sa), tonumber(msg.st2)
  peer.lastHeard = ns.Now()
  if isHello or wasOffline then
    ns.Log("%s came online (v%s)", peer.name, tostring(peer.version))
  end
  if msg.st == "syncing" and was ~= "syncing" and msg.w then
    ns.Log("%s is syncing with %s", peer.name, msg.w)
  end
  if peer.hl > 0 and peer.hl ~= wasHl then
    ns.Detail("%s is hosting %s", peer.name, ns.Plural(peer.hl, "handshake"))
  end
  if msg.st == "ready" and (was ~= "ready" or wasD ~= msg.d) then
    local master = ns.Master()
    if master and msg.d == master then
      ns.Log("%s is in sync", peer.name)
    else
      ns.Detail("%s is ready, but their prices differ from the master list", peer.name)
    end
  end
end

-- A player we were hosting reloaded or left: forget their unfinished pieces.
function ns.DropHostingFor(peerKey)
  local changed = false
  for tkey in pairs(hosting) do
    if tkey:sub(1, #peerKey + 1) == peerKey .. "/" then
      hosting[tkey] = nil
      transfers[tkey] = nil
      changed = true
    end
  end
  if changed then ns.AnnounceState() end
end

-- A handshake piece we're serving has finished (or died): no longer counts as hosting load.
local function DoneHosting(tkey)
  if hosting[tkey] then
    hosting[tkey] = nil
    ns.AnnounceState()
  end
end

-- Telling this player they're out of date: only ever to them, never about anyone else.
-- msg.v is the sender's version, msg.mv the oldest version the sender syncs with (1.4.6+).
local newerSeen, blockedSeen = false, false
local function CheckOwnVersion(msg)
  if ns.VERSION == "?" or not msg.v then return end
  if not blockedSeen and msg.mv and not ns.VersionAtLeast(ns.VERSION, msg.mv) then
    blockedSeen, newerSeen = true, true
    ns.Print("|cffff5555Your AuctionatorSync (v%s) is too old to sync with players on v%s - they ignore it until "
      .. "you update to v%s or newer. Update it in the DrangedAddons manager.|r", ns.VERSION, tostring(msg.v),
      tostring(msg.mv))
  elseif not newerSeen and not ns.VersionAtLeast(ns.VERSION, msg.v) then
    newerSeen = true
    ns.Print("|cffffd100A newer AuctionatorSync (v%s) is out - you have v%s. Update it in the DrangedAddons manager.|r",
      tostring(msg.v), ns.VERSION)
  end
end

function ns.OnMessage(msg, peer)
  CheckOwnVersion(msg) -- anyone with the addon counts, whatever their realm or faction
  local r = Realm()
  if not r or msg.r ~= ns.RealmKey() then
    if not peer.otherRealm then
      ns.Log("%s is on another realm or faction (%s): not syncing with them", peer.name, tostring(msg.r))
    end
    peer.otherRealm = true
    return
  end
  peer.otherRealm = nil
  if not Compatible(peer) then
    -- too old: nothing of theirs is used (before 1.6.0 a compare sent whole sections both ways
    -- and never finished on a megaserver list). Only the log and the online list's "needs
    -- update" say so; their own copy tells them (CheckOwnVersion).
    if not peer.warned then
      peer.warned = true
      ns.Log("%s is on v%s, which can't sync with v%s - they need to update",
        peer.name, tostring(msg.v), ns.VERSION)
    end
    return
  end
  local peerKey = ns.ShortName(peer.name)

  -- the neutral auction house list (Neutral.lua): its own messages, never mixed with this list
  if msg.t == "NDATA" or msg.t == "NREQ" then
    if ns.OnNeutralMessage then ns.OnNeutralMessage(msg, peer) end
    return
  end

  if msg.t == "HELLO" then
    NoteState(peer, msg, true)
    ns.Send(ns.ReplyTarget(peer), StateMsg(), "ALERT")

  elseif msg.t == "STATE" then
    NoteState(peer, msg, false)

  elseif msg.t == "SUM" then
    -- Someone behind us is comparing: which sections differ? Answered together with anyone
    -- else who asks in the next few seconds, so the prices go out once.
    local diff = DiffStamps(msg.hb)
    if not diff then
      ns.Log("%s sent a section compare this version doesn't use; they need AuctionatorSync 1.6.0", peer.name)
      return
    end
    ns.Log("%s is comparing with %s: %d of %d sections differ", peer.name, ns.MyName(), #diff, SECTIONS)
    QueueResponse(peer, diff)

  elseif msg.t == "CANCEL" then
    -- the newcomer dropped us for this piece: stop sending it and stop hosting it
    local key = peerKey .. "#" .. tostring(msg.pc)
    local out = replies[key]
    if out then
      out.cancelled = true
      ns.outgoing[out] = nil
      replies[key] = nil
    end
    for tkey, tr in pairs(transfers) do
      if tr.kind == "join" and tostring(tr.pc) == tostring(msg.pc) and tkey:sub(1, #peerKey + 1) == peerKey .. "/" then
        transfers[tkey] = nil
        DoneHosting(tkey)
      end
    end
    ns.Log("%s dropped %s as a host for a handshake piece; stopped sending it", peer.name, ns.MyName())

  elseif msg.t == "NEED" then
    HandleNeed(peer, msg)

  elseif msg.t == "DATA" then
    IngestPrices(msg, peer, r)
  end
end

----------------------------------------------------------------------------------------------
-- Heartbeat, who went offline, and the safety net

local mismatchSince

-- Watchdog: a compare that lost its timer still ends, and a finished transfer is noticed even
-- if the send callback was skipped. A slow transfer is not abandoned.
local function Watchdog()
  local now = ns.Now()
  if not join then
    if ns.state == "syncing" then
      ns.Log("%s's sync ended without finishing; retrying shortly", ns.MyName())
      SetState("ready")
      RetrySoon()
    elseif ns.state == "waiting" and now - (ns.stateSince or now) >= WAIT_LIMIT + HELLO_WAIT * 2 then
      ns.Log("%s found nobody to compare with in %ds; carrying on and retrying shortly", ns.MyName(), WAIT_LIMIT)
      SetState("ready")
      RetrySoon()
    end
    return
  end
  if join.up and join.up.cancelled then
    GiveUp()
    return
  end
  if not join.answered and now - (join.started or now) > 150 then
    CompareTimedOut(join)
    return
  end
  MaybeFinish()
end
C_Timer.NewTicker(5, function()
  local ok, err = pcall(Watchdog)
  if not ok then
    ns.Log("sync watchdog error: %s; restarting the sync", tostring(err))
    if join then pcall(GiveUp) else SetState("ready") end
  end
end)

C_Timer.NewTicker(30, function()
  if not ns.store or not ns.RealmKey() or ns.state == "starting" then return end
  for _, peer in pairs(ns.peers) do
    if not peer.gone and peer.lastSeen and not ns.IsPeerOnline(peer) then
      peer.gone = true
      peer.lastHeard = nil
      ns.Log("%s went offline", peer.name)
      ns.CancelTransfersTo(peer.name, "they went offline")
    end
  end
  -- Safety net: still different from someone with newer prices, and nothing is already moving.
  -- The compare sends only the sections that differ, so running it again is cheap once the
  -- lists are close, and it's how two versions that met get merged.
  local peer = not join and ns.state == "ready" and not ns.IsScanning() and not next(pending)
    and ns.Receiving() == 0 and not ns.IsSending() and PickPeer()
  if peer then
    mismatchSince = mismatchSince or ns.Now()
    if ns.Now() - mismatchSince >= HEAL_AFTER then
      mismatchSince = nil
      ns.Log("%s's prices have differed for %ds: comparing with %s", ns.MyName(), HEAL_AFTER, peer.name)
      StartSync(false, peer)
    end
  else
    mismatchSince = nil
  end
end)

----------------------------------------------------------------------------------------------
-- Auctionator's scans (its EventBus, listened to from outside) and the auction house closing

local SCAN_TIMEOUT = 900
local scanning, scanTimer = false, nil
local deferred

function ns.IsScanning() return scanning end
function ns.DeferSync(verbose) deferred = deferred or verbose or false end

local function ScanEnded(completed)
  scanning = false
  if scanTimer then scanTimer:Cancel(); scanTimer = nil end
  if completed then
    local r = Realm()
    if r then r.lastFullScan = ns.Now() end
    ns.ShareChanges(ns.MyName() .. "'s scan")
  end
  if deferred ~= nil then
    local verbose = deferred
    deferred = nil
    ns.CatchUp(verbose)
  end
end

local function OnScanEvent(kind)
  if kind == "start" then
    ns.Log("Auctionator scan started")
    scanning = true
    if scanTimer then scanTimer:Cancel() end
    scanTimer = C_Timer.NewTimer(SCAN_TIMEOUT, function() ScanEnded(false) end)
  elseif kind == "complete" then
    ns.Log("Auctionator scan finished")
    ScanEnded(true)
  elseif kind == "failed" then
    ns.Log("Auctionator scan failed")
    ScanEnded(false)
  end
end

-- Auctionator's EventBus calls its listeners in a plain loop and fires ScanComplete from the
-- last step of the scan: an error (or a slow share) here would stop its own listeners and
-- leave the scan stuck at 99%. So the work runs on the next frame, outside its call, guarded.
local scanListener = { kinds = {} }
function scanListener:ReceiveEvent(event)
  local kind = self.kinds[event]
  if not kind then return end
  C_Timer.After(0, function()
    local ok, err = pcall(OnScanEvent, kind)
    if not ok then ns.Log("couldn't handle the Auctionator scan event: %s", tostring(err)) end
  end)
end

local scanEventsRegistered = false
function ns.WatchScans()
  if scanEventsRegistered or not (Auctionator and Auctionator.EventBus) then return end
  local names = {}
  for _, group in ipairs({ Auctionator.FullScan, Auctionator.IncrementalScan }) do
    local ev = group and group.Events
    if ev then
      for field, kind in pairs({ ScanStart = "start", ScanComplete = "complete", ScanFailed = "failed" }) do
        if ev[field] then
          scanListener.kinds[ev[field]] = kind
          names[#names + 1] = ev[field]
        end
      end
    end
  end
  if #names == 0 then return end
  local ok, err = pcall(Auctionator.EventBus.Register, Auctionator.EventBus, scanListener, names)
  scanEventsRegistered = ok
  if not ok then ns.Log("couldn't watch Auctionator scans: %s", tostring(err)) end
end

-- Prices from ordinary searches go out when you close the auction house.
ns.On("AUCTION_HOUSE_CLOSED", function()
  if not scanning then ns.ShareChanges(ns.MyName() .. "'s auction house searches") end
end)

----------------------------------------------------------------------------------------------
-- Login

local function PruneTimestamps()
  local cutoff = ns.Now() - TS_KEEP_DAYS * 86400
  for _, r in pairs(ns.store.realms) do
    for key, ts in pairs(r.ts) do
      if ts < cutoff then r.ts[key] = nil end
    end
    r.ch, r.scanKeys, r.unsent = nil, nil, nil -- left over from older versions
  end
end

ns.On("PLAYER_LOGIN", function()
  ns.onlineSince = ns.Now()
  if not ns.canEncode then return end
  PruneTimestamps()
  ns.HookAuctionator()
  ns.WatchScans()
  C_Timer.NewTicker(10, ns.HookAuctionator)
  C_Timer.NewTicker(HEARTBEAT, function()
    if ns.state ~= "starting" and ns.RealmKey() then ns.Broadcast(StateMsg(), "NORMAL") end
  end)
end)

local greeted = false
ns.On("PLAYER_ENTERING_WORLD", function()
  if greeted then return end
  greeted = true
  C_Timer.After(3, function() if ns.canEncode then ns.JoinChannel() end end)
  -- A few seconds in, so the line isn't lost in the burst of chat that follows a loading screen.
  C_Timer.After(4, function()
    if not ns.canEncode then
      ns.Print("|cffff5555Can't sync: this game client is missing C_EncodingUtil.|r")
      return
    end
    ns.Notice("v%s ready. Syncing prices with everyone online who has AuctionatorSync. |cffffd100/async|r for options.", ns.VERSION)
  end)
  C_Timer.After(8, function()
    if not ns.canEncode then return end
    ns.HookAuctionator()
    ns.Log("%s came online (v%s)", ns.MyName(), ns.VERSION)
    ns.CatchUp(false)
  end)
end)

----------------------------------------------------------------------------------------------
-- Who's online and in sync (the /async list and /async status)

-- rows: { name, version, text, color, rank, lastSync, newest, host, me }. host = hosting a
-- handshake right now (crown, pinned to the top). rank orders statuses for sorting: in sync,
-- handshaking, waiting, not in sync, needs update.
function ns.StatusRows()
  local master = ns.Master()
  local function Text(st, d, with, pg, hl, compatible, rx, ph)
    if not compatible then return "needs update", "808080", 5 end
    if st == "ready" and d ~= master and (rx or 0) > 0 then return "receiving updates", "ffd100", 2 end
    if st == "syncing" then
      return "handshaking" .. (with and (" with " .. with) or "") .. (ph and (" - " .. ph) or "")
        .. (pg and (" (" .. pg .. "%)") or ""), "ffd100", 2
    end
    if st ~= "ready" then return "waiting to sync", "ffd100", 3 end
    if master and d == master then
      return "in sync" .. ((hl or 0) > 0 and (" - hosting " .. hl) or ""), "33ff99", 1
    end
    return "not in sync yet", "ff5555", 4
  end
  local rows = {}
  local myHl = HostingCount()
  local myText, myColor, myRank = Text(ns.state, ns.Fingerprint(), ns.syncingWith, ns.syncProgress, myHl, true,
    ns.Receiving(), ns.syncPhase)
  rows[#rows + 1] = { name = ns.MyName(), version = ns.VERSION, text = myText, color = myColor, rank = myRank,
    lastSync = ns.LastSync(), newest = newestTs > 0 and newestTs or nil, host = myHl > 0, me = true }
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and not peer.otherRealm then
      local t, c, rank = Text(peer.st, peer.d, peer.w, peer.pg, peer.hl, Compatible(peer), peer.rx, peer.ph)
      rows[#rows + 1] = { name = peer.name, version = peer.version, text = t, color = c, rank = rank,
        lastSync = peer.ls, newest = peer.nt, host = (peer.hl or 0) > 0 }
    end
  end
  return rows
end

function ns.PrintStatus()
  ns.Print("v%s on %s: %s, fingerprint %s%s.", ns.VERSION, tostring(ns.RealmKey() or "?"),
    ns.Plural(itemCount, "price"), ns.Fingerprint(), ns.Fingerprint() == ns.Master() and " (the master list)" or "")
  local ls = ns.LastSync()
  ns.Print("Last sync: %s.", (ls or 0) > 0 and date("%d %b %H:%M", ls) or "never")
  local rows = ns.StatusRows()
  table.sort(rows, function(a, b)
    if a.host ~= b.host then return a.host end
    return a.name < b.name
  end)
  for _, row in ipairs(rows) do
    ns.Print("  %s v%s: |cff%s%s|r, last sync %s", row.name, tostring(row.version),
      row.color, row.text, row.lastSync and date("%H:%M", row.lastSync) or "unknown")
  end
end

