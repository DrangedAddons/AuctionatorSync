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
--   REQ   {since, after?, cov?}  sent to the peer with the most to offer. If I've done a full
--                    scan since my last catch-up: after = when it finished, cov = the items it
--                    covered. The peer skips covered items it saw before `after` (mine are
--                    newer); everything else that changed since `since` still comes.
-- Every message also carries sid (a random per-login ID) so our own echoes are dropped.
--   DATA  {x, e, b, fin?, cu?}  one batch of a transfer x: e = {key, price, available, ts - b, ...}
--                    fin marks the last batch; cu marks a catch-up reply
local _, ns = ...

local BATCH = 1500          -- prices per DATA message
-- Changes are collected and sent as one update every SHARE_INTERVAL seconds.
-- 60 while testing; set back to 300 (5 minutes) for the live release.
local SHARE_INTERVAL = 60
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
    r = { ts = {}, ch = {}, unsent = {}, lastCatchUp = 0 }
    ns.store.realms[key] = r
  end
  r.ch = r.ch or {}
  r.unsent = r.unsent or {}
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

-- Auctionator keys: "12345" (item), "g:12345:..." (gear by item level), "p:..." (battle pet).
function ns.ItemIDFromKey(key)
  key = tostring(key)
  return tonumber(key:match("^(%d+)$") or key:match("^g:(%d+)"))
end

-- The latest price change (shown as the "price check" item in /async). Only real items, so
-- it can be shown with an icon and tooltip. synced = true when it came in through a sync,
-- nil for your own scan (no names: it just came from AuctionatorSync).
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
-- Watching Auctionator's own scans

-- What each item's price was before the current scan touched it. The hook runs after
-- Auctionator's SetPrice has already overwritten m, so we keep our own copy (memory only).
local known = {}
local hookedDB

-- The send queue: r.unsent[key] = the price at the last update we sent (0 if none). Saved with
-- the realm, so changes made while nobody was online wait across logouts until someone is.
-- Sent every SHARE_INTERVAL, and a few seconds after anyone comes online.
function ns.FlushShared()
  local r, db = Realm(), DB()
  if not r or not db or type(db.db) ~= "table" or not next(r.unsent) then return end
  if not ns.db.shareScans then wipe(r.unsent); return end
  local targets = ns.PeerTargets()
  if #targets == 0 then return end -- nobody online: keep the queue for later
  local list = {}
  local oldest = ns.Now() - ns.db.maxAgeDays * 86400
  for key, before in pairs(r.unsent) do
    local entry = db.db[key]
    local ts = r.ts[key] or 0
    -- skip it if it went back to the price we last sent, or is too old to be worth sending
    if type(entry) == "table" and (entry.m or 0) > 0 and entry.m ~= before and ts > oldest then
      local day = entry.a and tostring(math.floor((ts - DayZero()) / 86400))
      list[#list + 1] = { key, entry.m, day and entry.a[day] or 0, ts }
    end
  end
  wipe(r.unsent)
  if #list == 0 then return end
  ns.SendEntries(targets, list, "NORMAL")
  ns.Debug("shared %d changed prices", #list)
end

-- Someone came online (their HELLO, or their answer to ours): send the queue shortly, once
-- they're registered as a peer. Several arriving together share one send.
local flushSoon
function ns.FlushSoon()
  if flushSoon then return end
  flushSoon = C_Timer.NewTimer(5, function()
    flushSoon = nil
    ns.FlushShared()
  end)
end

local function OnLocalPrice(key, price, available)
  local r = Realm()
  if not r or not key or not price then return end
  key = tostring(key)
  local now = ns.Now()
  r.ts[key] = now
  if ns.NoteScanKey then ns.NoteScanKey(key) end
  if known[key] == price then return end -- same price as before: seen again, nothing to send
  if r.unsent[key] == nil then r.unsent[key] = known[key] or 0 end
  NoteChange(r, key, price, known[key], nil)
  known[key] = price
  r.ch[key] = now
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

-- Returns "changed" (newer and a different price: written), "same" (newer, same price: only
-- our timestamp moves), "older" (mine is newer AND different: kept) or nil.
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
  end

  -- Only a newer AND different price is written into Auctionator. A newer sighting of the
  -- same price just moves our timestamp; an older one is never written.
  if ts <= SeenAt(r, key, entry) then
    return ((entry.m or 0) > 0 and entry.m ~= price) and "older" or nil
  end
  r.ts[key] = ts
  if entry.m == price then return "same" end
  local was = entry.m
  r.unsent[key] = nil
  entry.m = price
  entry.l = entry.l or {}
  entry.h = entry.h or {}
  data[key] = entry
  known[key] = price
  r.ch[key] = ns.Now()

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
  return "changed", was
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

-- Prices that changed here after `since` and were seen within maxAgeDays. `covered` (a set of
-- keys) and `after`: the asker's last full scan saw those items at `after`, so our sightings of
-- them from before then are older than theirs and not worth sending.
local function Collect(since, covered, after)
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  since = since or 0
  local oldest = ns.Now() - ns.db.maxAgeDays * 86400
  for key, entry in pairs(db.db) do
    if type(entry) == "table" and (entry.m or 0) > 0 and ChangedAt(r, key, entry) > since then
      local ts = SeenAt(r, key, entry)
      if ts > oldest and not (covered and after and covered[key] and ts <= after) then
        local day = entry.a and tostring(floor((ts - DayZero()) / 86400))
        list[#list + 1] = { key, entry.m, day and entry.a[day] or 0, ts }
      end
    end
  end
  return list
end

----------------------------------------------------------------------------------------------
-- Chat
--
-- Automatic messages (sign-in, sync results) go through ns.Notice and obey the "Show chat
-- messages" box. Answers to something the player did (/async commands, Sync now) and errors
-- always show. Sends are never announced, and updates arriving from several friends within a
-- few seconds share one line.

local REPORT_DELAY = 10
local reported, reportTimer = 0, nil -- changed prices waiting for the combined line

-- Chat never names who prices came from: they come from AuctionatorSync (the line's prefix).
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

----------------------------------------------------------------------------------------------
-- Catching up

local catchUp -- { started, since, offers = { [peerKey] = n }, chosen, verbose }

-- For catch-ups: the player asked (Sync now) -> always say; automatic (login) -> only if ticked.
local function Say(verbose, fmt, ...)
  if verbose then ns.Print(fmt, ...) else ns.Notice(fmt, ...) end
end

-- A transfer arrives in batches of BATCH prices; each batch is applied as it lands, but chat
-- only hears about it once, after the last batch, with the totals for the whole transfer.
local transfers = {} -- peerKey .. "/" .. x -> { name, changed, received, corrections, timer, kind, verbose }

local function FinishTransfer(tkey, peer, incomplete)
  local tr = transfers[tkey]
  if not tr then return end
  transfers[tkey] = nil
  if tr.timer then tr.timer:Cancel() end
  local cut = incomplete and " (stopped partway; the rest comes with the next sync)" or ""
  if tr.kind == "catchup" then
    if tr.changed > 0 then
      Say(tr.verbose, "Caught up: updated %s%s.", ns.Plural(tr.changed, "price"), cut)
    else
      Say(tr.verbose, "Up to date%s.", cut)
    end
  else
    Report(tr.changed)
  end
  -- They sent prices that are older than ours and different: send ours back so they're fixed too.
  if peer and #tr.corrections > 0 then
    ns.SendEntries({ ns.ReplyTarget(peer) }, tr.corrections, "BULK")
    ns.Debug("sent %d newer prices back to %s", #tr.corrections, tr.name)
  end
end

----------------------------------------------------------------------------------------------
-- Auctionator's full scans. Auctionator announces scan start/finish on its EventBus; we
-- register a listener there (no change to Auctionator). While a scan runs, a catch-up waits,
-- then asks only for what the scan didn't already cover (see REQ.cov).

local SCAN_TIMEOUT = 900  -- forget a scan that never reported back after 15 minutes
local scanning, scanTimer = false, nil
local scanKeys            -- set of keys the running scan has priced
local deferred -- nil, or the `verbose` of a catch-up waiting for the scan to finish

-- Covered keys go over the wire compactly: item IDs sorted and sent as gaps, the rest as-is.
local function PackKeys(list)
  local ids, other = {}, {}
  for _, key in ipairs(list) do
    local id = tostring(key):match("^(%d+)$")
    if id then ids[#ids + 1] = tonumber(id) else other[#other + 1] = key end
  end
  table.sort(ids)
  local gaps, prev = {}, 0
  for i, id in ipairs(ids) do
    gaps[i] = id - prev
    prev = id
  end
  return { d = gaps, s = other }
end

local function UnpackKeys(packed)
  if type(packed) ~= "table" then return nil end
  local set, id = {}, 0
  for _, gap in ipairs(type(packed.d) == "table" and packed.d or {}) do
    id = id + (tonumber(gap) or 0)
    set[tostring(id)] = true
  end
  for _, key in ipairs(type(packed.s) == "table" and packed.s or {}) do set[tostring(key)] = true end
  return set
end

local function ScanEnded(completed)
  scanning = false
  if scanTimer then scanTimer:Cancel(); scanTimer = nil end
  local r = Realm()
  if completed and r and scanKeys then
    r.lastFullScan = ns.Now()
    local list = {}
    for key in pairs(scanKeys) do list[#list + 1] = key end
    r.scanKeys = list
  end
  scanKeys = nil
  if deferred ~= nil then
    local verbose = deferred
    deferred = nil
    ns.CatchUp(verbose)
  end
end

function ns.NoteScanKey(key)
  if scanKeys then scanKeys[key] = true end
end

local scanListener = { kinds = {} }
function scanListener:ReceiveEvent(event)
  local kind = self.kinds[event]
  if kind == "start" then
    scanning = true
    scanKeys = {}
    if scanTimer then scanTimer:Cancel() end
    scanTimer = C_Timer.NewTimer(SCAN_TIMEOUT, function() ScanEnded(false) end)
    -- a catch-up still asking around is pointless now: the scan will be newer
    if catchUp and not catchUp.chosen then
      deferred = deferred or catchUp.verbose or false
      catchUp = nil
    end
  elseif kind == "complete" then
    ScanEnded(true)
  elseif kind == "failed" then
    ScanEnded(false)
  end
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
  if not ok then ns.Debug("couldn't watch Auctionator scans: %s", tostring(err)) end
end

function ns.CatchUp(verbose)
  if verbose then ns.FlushShared() end -- Sync now also sends what's collected so far
  local r = Realm()
  if not r then
    Say(verbose, "Auctionator's prices aren't loaded yet; try again in a moment.")
    return
  end
  if scanning then
    if verbose then ns.Print("Waiting for your scan to finish first.") end
    deferred = deferred or verbose
    return
  end
  if catchUp and catchUp.chosen then
    Say(verbose, "Already catching up.")
    return
  end
  local since = math.max(0, (r.lastCatchUp or 0) - CATCHUP_MARGIN)
  catchUp = { started = ns.Now(), since = since, offers = {}, verbose = verbose }
  local targets = ns.AllTargets()
  if #targets == 0 then
    if not (ns.db.guild or ns.db.friends or ns.db.bnet) then
      Say(verbose, "Syncing is off: tick guild, friends or Battle.net in |cffffd100/async|r.")
    else
      Say(verbose, "No guild members or friends online to sync with.")
    end
    catchUp = nil
    return
  end
  for _, t in ipairs(targets) do
    ns.Send(t, { t = "HELLO", r = ns.RealmKey(), since = since }, "ALERT")
  end
  if verbose then ns.Print("Checking for changed prices...") end
  local mine = catchUp
  C_Timer.After(PONG_WAIT, function()
    if catchUp ~= mine then return end
    local bestKey, bestN, names = nil, 0, {}
    for key, n in pairs(mine.offers) do
      if ns.peers[key] then names[#names + 1] = ns.peers[key].name end
      if n > bestN then bestKey, bestN = key, n end
    end
    if #names == 0 then
      Say(verbose, "No one online with AuctionatorSync yet. Your scans are shared once they are.")
      r.lastCatchUp = mine.started
      catchUp = nil
      return
    end
    if not bestKey then
      Say(verbose, "Up to date.")
      r.lastCatchUp = mine.started
      catchUp = nil
      return
    end
    mine.chosen = bestKey
    local peer = ns.peers[bestKey]
    local req = { t = "REQ", r = ns.RealmKey(), since = mine.since }
    local covered = r.lastFullScan and r.lastFullScan > mine.since and r.scanKeys
    if covered then
      req.after, req.cov = r.lastFullScan, PackKeys(r.scanKeys)
    end
    -- Only worth a line of its own when it'll take a while (more than one batch). After a scan
    -- the friend's count doesn't know what the scan covered, so it's too high to quote.
    if covered then
      if verbose then ns.Print("Getting what your scan didn't cover...") end
    elseif verbose or bestN > BATCH then
      Say(verbose, "Catching up %s...", ns.Plural(bestN, "price"))
    end
    ns.Send(ns.ReplyTarget(peer), req, "ALERT")
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
    ns.FlushSoon()
    local reply = { t = "PONG", r = ns.RealmKey() }
    if msg.since then reply.n = #Collect(tonumber(msg.since) or 0) end
    ns.Send(ns.ReplyTarget(peer), reply, "ALERT")

  elseif msg.t == "PONG" then
    ns.FlushSoon()
    if catchUp and msg.n then catchUp.offers[peerKey] = tonumber(msg.n) or 0 end

  elseif msg.t == "REQ" then
    if serving[peerKey] then return end
    serving[peerKey] = true
    local list = Collect(tonumber(msg.since) or 0, UnpackKeys(msg.cov), tonumber(msg.after))
    ns.SendEntries({ ns.ReplyTarget(peer) }, list, "BULK", { cu = true })
    ns.Debug("sending %d changed prices to %s", #list, peer.name)
    C_Timer.After(120, function() serving[peerKey] = nil end)

  elseif msg.t == "DATA" then
    local e, base = msg.e, tonumber(msg.b) or 0
    if type(e) ~= "table" then return end
    local tkey = peerKey .. "/" .. tostring(msg.x)
    local tr = transfers[tkey]
    if not tr then
      local isMyCatchUp = msg.cu and catchUp and catchUp.chosen == peerKey
      tr = { name = peer.name, changed = 0, received = 0, corrections = {},
        kind = isMyCatchUp and "catchup" or "update", verbose = isMyCatchUp and catchUp.verbose }
      transfers[tkey] = tr
    end
    local entries = DB() and DB().db
    for i = 1, #e - 3, 4 do
      tr.received = tr.received + 1
      local key = e[i]
      local result, was = Apply(r, key, e[i + 1], e[i + 2], base + (tonumber(e[i + 3]) or 0))
      if result == "changed" then
        tr.changed = tr.changed + 1
        NoteChange(r, tostring(key), tonumber(e[i + 1]), was, true)
      elseif result == "older" and msg.cu and entries then
        -- only for catch-up replies: a guild broadcast would get a correction from everyone
        key = tostring(key)
        local mine = entries[key]
        tr.corrections[#tr.corrections + 1] = { key, mine.m, 0, SeenAt(r, key, mine) }
      end
    end
    if tr.timer then tr.timer:Cancel() end
    local function EndCatchUp(done)
      if tr.kind == "catchup" and catchUp and catchUp.chosen == peerKey then
        if done then r.lastCatchUp = catchUp.started end
        catchUp = nil
      end
    end
    if msg.fin then
      FinishTransfer(tkey, peer)
      EndCatchUp(true)
    else
      tr.timer = C_Timer.NewTimer(ANNOUNCE_FALLBACK, function()
        FinishTransfer(tkey, peer, true)
        EndCatchUp(false)
      end)
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

local function SourcesText()
  local list = {}
  if ns.db.guild then list[#list + 1] = "guild" end
  if ns.db.friends then list[#list + 1] = "friends" end
  if ns.db.bnet then list[#list + 1] = "Battle.net friends" end
  if #list == 0 then return nil end
  if #list == 1 then return list[1] end
  return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

ns.On("PLAYER_LOGIN", function()
  if not ns.canEncode then return end
  PruneTimestamps()
  ns.HookAuctionator()
  ns.WatchScans()
  C_Timer.NewTicker(10, ns.HookAuctionator)
  C_Timer.NewTicker(SHARE_INTERVAL, ns.FlushShared)
end)

-- Once per session, after the first loading screen: the sign-in line, then the catch-up.
local greeted = false
ns.On("PLAYER_ENTERING_WORLD", function()
  if greeted then return end
  greeted = true
  -- A few seconds in, so the line isn't lost in the burst of chat that follows a loading screen.
  C_Timer.After(4, function()
    if not ns.canEncode then
      ns.Print("|cffff5555Can't sync: this game client is missing C_EncodingUtil.|r")
      return
    end
    local sources = SourcesText()
    if sources then
      ns.Notice("v%s ready. Syncing prices with your %s. |cffffd100/async|r for options.", ns.VERSION, sources)
    else
      ns.Notice("v%s ready, but syncing is off (nothing ticked). |cffffd100/async|r for options.", ns.VERSION)
    end
  end)
  -- Give the guild roster and friends list a moment to arrive.
  C_Timer.After(10, function()
    if not ns.canEncode then return end
    ns.HookAuctionator()
    ns.RefreshRosters()
    if ns.db.catchUpOnLogin then ns.CatchUp(false) else ns.Hello() end
  end)
end)

function ns.PrintStatus()
  local r = Realm()
  ns.Print("v%s on %s.", ns.VERSION, tostring(ns.RealmKey() or "?"))
  if r then
    local count = 0
    for _ in pairs(r.ts) do count = count + 1 end
    ns.Print("Tracking %s. Last catch-up: %s.", ns.Plural(count, "price"),
      (r.lastCatchUp or 0) > 0 and date("%d %b %H:%M", r.lastCatchUp) or "never")
  end
  local versions, groups, count = ns.OnlineGroups()
  if count == 1 then
    ns.Print("No one else online with AuctionatorSync.")
    return
  end
  local parts = {}
  for _, v in ipairs(versions) do
    parts[#parts + 1] = string.format("v%s: %s", v, table.concat(groups[v], ", "))
  end
  ns.Print("Online (%d): %s.", count, table.concat(parts, " · "))
end
