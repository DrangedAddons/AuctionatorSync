-- The sync itself.
--
-- Auctionator keeps, per item, the last seen price (m) and per-day history (h/l/a), but not
-- *when* during the day a price was seen. AuctionatorSync keeps two timestamps per item:
--   ts[key] = when this price was last seen (by me or a friend) - the newer one wins
--   ch[key] = when the price last CHANGED in my database - decides what gets sent
-- Only changed prices travel: a rescan that finds the same price sends nothing.
--
-- Messages (all carry r = Auctionator's realm key, so other realms/factions are ignored):
--   HELLO {since?}   "I'm here"; with since, "and I'd like what changed since then"
--   PONG  {n?}       answer to HELLO; n = how many prices changed here since `since`
--   REQ   {since}    sent to the peer with the most to offer
--   DATA  {x, e, b, fin?, cu?}  one batch of a transfer x: e = {key, price, available, ts - b, ...}
--                    fin marks the last batch; cu marks a catch-up reply
local _, ns = ...

local BATCH = 1500          -- prices per DATA message
local SHARE_DELAY = 10      -- seconds of quiet after a scan before sending it
local PONG_WAIT = 5         -- seconds to collect answers to a catch-up HELLO
local CATCHUP_MARGIN = 600  -- re-ask a little before the last catch-up, for clock drift
local ANNOUNCE_FALLBACK = 60 -- print a transfer's summary anyway if its last batch never arrives
local TS_KEEP_DAYS = 60

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
    r = { ts = {}, ch = {}, lastCatchUp = 0 }
    ns.store.realms[key] = r
  end
  r.ch = r.ch or {}
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
  return newest and (DayZero() + newest * 86400) or 0
end

local function ChangedAt(r, key, entry)
  return r.ch[key] or SeenAt(r, key, entry)
end

----------------------------------------------------------------------------------------------
-- Watching Auctionator's own scans

-- What each item's price was before the current scan touched it. The hook runs after
-- Auctionator's SetPrice has already overwritten m, so we keep our own copy (memory only).
local known = {}
local pending, shareTimer = {}, nil
local hookedDB

local function FlushShared()
  shareTimer = nil
  local r = Realm()
  if not r or not ns.db.shareScans then wipe(pending); return end
  local targets = ns.PeerTargets()
  if #targets == 0 then wipe(pending); return end
  local list = {}
  for key, info in pairs(pending) do
    list[#list + 1] = { key, info[1], info[2], r.ts[key] or ns.Now() }
  end
  wipe(pending)
  if #list == 0 then return end
  ns.SendEntries(targets, list, "NORMAL")
  ns.Debug("shared %d changed prices", #list)
end

local function OnLocalPrice(key, price, available)
  local r = Realm()
  if not r or not key or not price then return end
  key = tostring(key)
  local now = ns.Now()
  r.ts[key] = now
  if known[key] == price then return end -- same price as before: seen again, nothing to send
  known[key] = price
  r.ch[key] = now
  pending[key] = { price, available or 0 }
  if shareTimer then shareTimer:Cancel() end
  shareTimer = C_Timer.NewTimer(SHARE_DELAY, FlushShared)
end

-- Auctionator can rebuild its database object (e.g. when you clear it), so keep checking.
function ns.HookAuctionator()
  local db = DB()
  if not db or db == hookedDB or type(db.SetPrice) ~= "function" then return end
  hookedDB = db
  wipe(known)
  if type(db.db) == "table" then
    for key, entry in pairs(db.db) do
      if type(entry) == "table" then known[key] = entry.m end
    end
  end
  hooksecurefunc(db, "SetPrice", function(self, key, price, available)
    if self == hookedDB then OnLocalPrice(key, price, available) end
  end)
  ns.Debug("watching Auctionator's price database (%s)", tostring(ns.RealmKey()))
end

----------------------------------------------------------------------------------------------
-- Writing friends' prices into Auctionator

-- Returns "changed" (newer and a different price), "same" (newer, same price: only the
-- timestamp moves), "older" (mine is newer AND different) or nil.
-- History uses the same per-day rules as Auctionator's SetPrice, on the day the price was seen.
local function Apply(r, key, price, available, ts)
  local db = DB()
  local data = db and db.db
  if type(data) ~= "table" then return nil end
  key = tostring(key)
  price, available, ts = tonumber(price), tonumber(available), tonumber(ts)
  if not price or price <= 0 or not ts then return nil end
  ts = math.min(ts, ns.Now())

  local entry = data[key]
  if entry ~= nil and type(entry) ~= "table" then return nil end
  if not entry then
    entry = { l = {}, h = {}, a = {}, m = 0 }
    data[key] = entry
  end
  entry.l = entry.l or {}
  entry.h = entry.h or {}

  local result
  if ts > SeenAt(r, key, entry) then
    r.ts[key] = ts
    if entry.m ~= price then
      entry.m = price
      known[key] = price
      r.ch[key] = ns.Now()
      result = "changed"
    else
      result = "same"
    end
  elseif (entry.m or 0) > 0 and entry.m ~= price then
    result = "older"
  end

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
  return result
end

----------------------------------------------------------------------------------------------
-- Sending prices

local transferCounter = 0

-- list = { {key, price, available, ts}, ... }; sent as one transfer of BATCH-sized messages,
-- the last one marked fin. opts.cu marks a catch-up reply.
function ns.SendEntries(targets, list, prio, opts)
  local realm = ns.RealmKey()
  transferCounter = transferCounter + 1
  local x = transferCounter
  local cu = opts and opts.cu or nil
  local n = #list
  if n == 0 then
    for _, t in ipairs(targets) do
      ns.Send(t, { t = "DATA", r = realm, x = x, e = {}, b = 0, fin = true, cu = cu }, prio)
    end
    return
  end
  local i = 1
  while i <= n do
    local last = math.min(i + BATCH - 1, n)
    local base = math.huge
    for j = i, last do base = math.min(base, list[j][4]) end
    local e = {}
    for j = i, last do
      local it = list[j]
      e[#e + 1] = it[1]
      e[#e + 1] = it[2]
      e[#e + 1] = it[3] or 0
      e[#e + 1] = it[4] - base
    end
    local msg = { t = "DATA", r = realm, x = x, e = e, b = base, fin = (last == n) or nil, cu = cu }
    for _, t in ipairs(targets) do ns.Send(t, msg, prio) end
    i = last + 1
  end
end

-- Prices that changed here after `since` and were seen within maxAgeDays.
local function Collect(since)
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  since = since or 0
  local oldest = ns.Now() - ns.db.maxAgeDays * 86400
  for key, entry in pairs(db.db) do
    if type(entry) == "table" and (entry.m or 0) > 0 and ChangedAt(r, key, entry) > since then
      local ts = SeenAt(r, key, entry)
      if ts > oldest then
        local day = entry.a and tostring(floor((ts - DayZero()) / 86400))
        list[#list + 1] = { key, entry.m, day and entry.a[day] or 0, ts }
      end
    end
  end
  return list
end

----------------------------------------------------------------------------------------------
-- Catching up

local catchUp -- { started, since, offers = { [peerKey] = n }, chosen, verbose }

-- One chat line per transfer, when its last batch lands (not one per batch).
local transfers = {} -- peerKey .. "/" .. x -> { name, changed, corrections = {}, timer }

local function FinishTransfer(tkey, peer)
  local tr = transfers[tkey]
  if not tr then return end
  transfers[tkey] = nil
  if tr.timer then tr.timer:Cancel() end
  if ns.db.announce and tr.changed > 0 then
    ns.Print("%d changed price%s from %s.", tr.changed, tr.changed == 1 and "" or "s", tr.name)
  elseif tr.verbose then
    ns.Print("Nothing new from %s - your prices match.", tr.name)
  end
  -- They sent prices that are older than ours and different: send ours back so they're fixed too.
  if peer and #tr.corrections > 0 then
    ns.SendEntries({ ns.ReplyTarget(peer) }, tr.corrections, "BULK")
    ns.Debug("sent %d newer prices back to %s", #tr.corrections, tr.name)
  end
end

function ns.CatchUp(verbose)
  local r = Realm()
  if not r then
    if verbose then ns.Print("Auctionator's price database isn't ready yet.") end
    return
  end
  local since = math.max(0, (r.lastCatchUp or 0) - CATCHUP_MARGIN)
  catchUp = { started = ns.Now(), since = since, offers = {}, verbose = verbose }
  local targets = ns.AllTargets()
  if #targets == 0 then
    if verbose then ns.Print("No one to sync with (no guild, friends or Battle.net friends online).") end
    catchUp = nil
    return
  end
  for _, t in ipairs(targets) do
    ns.Send(t, { t = "HELLO", r = ns.RealmKey(), since = since }, "ALERT")
  end
  if verbose then ns.Print("Asking %d place%s for changed prices...", #targets, #targets == 1 and "" or "s") end
  local mine = catchUp
  C_Timer.After(PONG_WAIT, function()
    if catchUp ~= mine then return end
    local bestKey, bestN = nil, 0
    for key, n in pairs(mine.offers) do
      if n > bestN then bestKey, bestN = key, n end
    end
    if not bestKey then
      if verbose then ns.Print("You're up to date.") end
      r.lastCatchUp = mine.started
      catchUp = nil
      return
    end
    mine.chosen = bestKey
    local peer = ns.peers[bestKey]
    if verbose then ns.Print("Getting up to %d price%s from %s.", bestN, bestN == 1 and "" or "s", peer.name) end
    ns.Send(ns.ReplyTarget(peer), { t = "REQ", r = ns.RealmKey(), since = mine.since }, "ALERT")
  end)
end

-- Just say hello (no catch-up), so friends know to send us their scans.
function ns.Hello()
  for _, t in ipairs(ns.AllTargets()) do
    ns.Send(t, { t = "HELLO", r = ns.RealmKey() }, "NORMAL")
  end
end

local serving = {} -- peerKey -> true while we send them a catch-up

function ns.OnMessage(msg, peer)
  local r = Realm()
  if not r or msg.r ~= ns.RealmKey() then
    peer.otherRealm = true
    return
  end
  peer.otherRealm = nil
  local peerKey = ns.ShortName(peer.name)

  if msg.t == "HELLO" then
    local reply = { t = "PONG", r = ns.RealmKey() }
    if msg.since then reply.n = #Collect(tonumber(msg.since) or 0) end
    ns.Send(ns.ReplyTarget(peer), reply, "ALERT")

  elseif msg.t == "PONG" then
    if catchUp and msg.n then catchUp.offers[peerKey] = tonumber(msg.n) or 0 end

  elseif msg.t == "REQ" then
    if serving[peerKey] then return end
    serving[peerKey] = true
    local list = Collect(tonumber(msg.since) or 0)
    ns.SendEntries({ ns.ReplyTarget(peer) }, list, "BULK", { cu = true })
    ns.Debug("sending %d changed prices to %s", #list, peer.name)
    C_Timer.After(120, function() serving[peerKey] = nil end)

  elseif msg.t == "DATA" then
    local e, base = msg.e, tonumber(msg.b) or 0
    if type(e) ~= "table" then return end
    local tkey = peerKey .. "/" .. tostring(msg.x)
    local tr = transfers[tkey]
    if not tr then
      tr = { name = peer.name, changed = 0, corrections = {},
        verbose = msg.cu and catchUp and catchUp.chosen == peerKey and catchUp.verbose }
      transfers[tkey] = tr
    end
    local entries = DB() and DB().db
    for i = 1, #e - 3, 4 do
      local key = e[i]
      local result = Apply(r, key, e[i + 1], e[i + 2], base + (tonumber(e[i + 3]) or 0))
      if result == "changed" then
        tr.changed = tr.changed + 1
      elseif result == "older" and msg.cu and entries then
        -- only for catch-up replies: a guild broadcast would get a correction from everyone
        key = tostring(key)
        local mine = entries[key]
        tr.corrections[#tr.corrections + 1] = { key, mine.m, 0, SeenAt(r, key, mine) }
      end
    end
    if tr.timer then tr.timer:Cancel() end
    if msg.fin then
      FinishTransfer(tkey, peer)
      if msg.cu and catchUp and catchUp.chosen == peerKey then
        r.lastCatchUp = catchUp.started
        catchUp = nil
      end
    else
      tr.timer = C_Timer.NewTimer(ANNOUNCE_FALLBACK, function() FinishTransfer(tkey, peer) end)
    end
  end
end

----------------------------------------------------------------------------------------------

local function PruneTimestamps()
  local cutoff = ns.Now() - TS_KEEP_DAYS * 86400
  for _, r in pairs(ns.store.realms) do
    for key, ts in pairs(r.ts) do
      if ts < cutoff then r.ts[key] = nil end
    end
    for key, ts in pairs(r.ch or {}) do
      if ts < cutoff then r.ch[key] = nil end
    end
  end
end

ns.On("PLAYER_LOGIN", function()
  if not ns.canEncode then
    ns.Print("|cffff5555this client has no C_EncodingUtil; syncing is off.|r")
    return
  end
  PruneTimestamps()
  ns.HookAuctionator()
  C_Timer.NewTicker(10, ns.HookAuctionator)
  -- Give the guild roster and friends list a moment to arrive.
  C_Timer.After(10, function()
    ns.HookAuctionator()
    ns.RefreshRosters()
    if ns.db.catchUpOnLogin then ns.CatchUp(false) else ns.Hello() end
  end)
end)

function ns.PrintStatus()
  local r = Realm()
  ns.Print("v%s, realm %s", ns.VERSION, tostring(ns.RealmKey()))
  if r then
    local count = 0
    for _ in pairs(r.ts) do count = count + 1 end
    ns.Print("%d prices with sync timestamps; last catch-up %s", count,
      (r.lastCatchUp or 0) > 0 and date("%Y-%m-%d %H:%M", r.lastCatchUp) or "never")
  end
  local any = false
  for _, peer in pairs(ns.peers) do
    any = true
    ns.Print("  %s (%s, v%s)%s", peer.name, peer.via, tostring(peer.version),
      peer.otherRealm and " - other realm/faction" or "")
  end
  if not any then ns.Print("  no one else with AuctionatorSync seen yet") end
end
