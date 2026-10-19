-- The sync itself.
--
-- Auctionator keeps, per item, the last seen price (m) and per-day history (h/l/a), but not
-- *when* during the day a price was seen. AuctionatorSync keeps its own timestamp per item:
--   ts[key] = when this price was last seen (by me or a friend) - the newer one always wins
-- A newer sighting of the same price only moves the timestamp; nothing in Auctionator changes.
--
-- Messages (all hidden addon data; all carry r = Auctionator's realm key, so other
-- realms/factions are ignored, and sid, a random per-login ID, so our own echoes are dropped):
--   HELLO {j?}       "I'm here" (j: and I'm joining, please answer)
--   PONG  {os, rd}   answer: when I came online, and whether I've finished my own join
--   DATA  {x, e, b, k?, fin?}  one batch of transfer x: e = {key, price, available, ts - b, ...};
--                    k = "join" (newcomer -> host), "reply" (host -> newcomer), nil = live update
-- How a join works is described above ns.CatchUp below.
local _, ns = ...

local BATCH = 1500          -- prices per DATA message
-- Changes are collected and sent as one update every SHARE_INTERVAL seconds.
-- 60 while testing; set back to 300 (5 minutes) for the live release.
local SHARE_INTERVAL = 60
local PONG_WAIT = 5         -- seconds to collect answers to a HELLO
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
    r = { ts = {}, unsent = {}, lastCatchUp = 0 }
    ns.store.realms[key] = r
  end
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

-- Live sharing while friends are online: r.unsent[key] = the price at the last update we sent
-- (0 if none), sent to everyone online every SHARE_INTERVAL. Changes made while nobody is online
-- wait here, and go into the next join compare (which then clears the queue).
function ns.FlushShared()
  local r, db = Realm(), DB()
  if not r or not db or type(db.db) ~= "table" or not next(r.unsent) then return end
  if not ns.db.shareScans then wipe(r.unsent); return end
  local targets = ns.PeerTargets()
  if #targets == 0 then -- nobody online: keep the queue for later
    local n = 0
    for _ in pairs(r.unsent) do n = n + 1 end
    ns.Log("nobody online: %s kept for later", ns.Plural(n, "changed price"))
    return
  end
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
  ns.Log("shared %s from your scans with everyone online", ns.Plural(#list, "changed price"))
end

local function OnLocalPrice(key, price, available)
  local r = Realm()
  if not r or not key or not price then return end
  key = tostring(key)
  local now = ns.Now()
  r.ts[key] = now
  if known[key] == price then return end -- same price as before: seen again, nothing to send
  if r.unsent[key] == nil then r.unsent[key] = known[key] or 0 end
  NoteChange(r, key, price, known[key], nil)
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
      if type(entry) == "table" then known[key] = entry.m end
    end
  end
  hooksecurefunc(db, "SetPrice", function(self, key, price, available)
    if self == hookedDB then OnLocalPrice(key, price, available) end
  end)
  ns.Log("watching Auctionator's prices for %s", tostring(ns.RealmKey()))
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
-- the last one marked fin. opts.k marks a join upload ("join") or the host's answer ("reply").
function ns.SendEntries(targets, list, prio, opts)
  local realm = ns.RealmKey()
  transferCounter = transferCounter + 1
  local x = transferCounter
  local k = opts and opts.k or nil
  local n = #list
  if n == 0 then
    for _, t in ipairs(targets) do
      ns.Send(t, { t = "DATA", r = realm, x = x, e = {}, b = 0, fin = true, k = k }, prio)
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
    local msg = { t = "DATA", r = realm, x = x, e = e, b = base, fin = (last == n) or nil, k = k }
    for _, t in ipairs(targets) do ns.Send(t, msg, prio) end
    i = last + 1
  end
end

----------------------------------------------------------------------------------------------
-- Chat
--
-- Automatic messages (sign-in, sync results) go through ns.Notice and obey the "Show chat
-- messages" box. Answers to something the player did (/async commands, Sync now) and errors
-- always show. Sends are never announced, and updates arriving from several friends within a
-- few seconds share one line. Chat never names who prices came from.

local REPORT_DELAY = 10
local reported, reportTimer = 0, nil -- changed prices waiting for the combined line

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

-- The player asked (Sync now) -> always say; automatic (login) -> only if ticked.
local function Say(verbose, fmt, ...)
  if verbose then ns.Print(fmt, ...) else ns.Notice(fmt, ...) end
end

----------------------------------------------------------------------------------------------
-- Joining: the host compare.
--
-- Everyone already online is in sync (they joined the same way, and new scans are shared live),
-- so any one of them can stand in for the group. When you come online:
--   1. HELLO to everyone; each answers PONG with when they came online (os) and whether they've
--      finished their own join (rd).
--   2. The host is picked automatically: finished joining first, then online longest.
--   3. You upload your last maxAgeDays of prices to the host (DATA k="join").
--   4. The host keeps whichever is newer per item, then sends back everything where its price is
--      newer than yours or you don't have it (DATA k="reply"), and passes the prices you brought
--      that were new to it on to everyone else online (an ordinary update).
--   5. If the host goes quiet, you move on to the next one.
-- Alone, there's nothing to do: your prices go into the next compare.

local JOIN_TIMEOUT = 180 -- seconds without hearing from the host before trying the next one
                         -- (generous: a first upload over whispers can take a minute or two)

ns.onlineSince = nil -- server time we came online (set at login)
ns.ready = false     -- finished our own join (or found nobody): fit to be someone's host

local join      -- { verbose, candidates = {peerKey...}, idx, pongs = {peerKey = {os, rd}}, timer, started }
local transfers = {} -- peerKey .. "/" .. x -> per-transfer state (see DATA below)

local function DoneJoining()
  ns.ready = true
  if join and join.timer then join.timer:Cancel() end
  join = nil
end

-- Everything we have from the last maxAgeDays, for a join upload or a host reply.
local function AllRecent()
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  local oldest = ns.Now() - ns.db.maxAgeDays * 86400
  for key, entry in pairs(db.db) do
    if type(entry) == "table" and (entry.m or 0) > 0 then
      local ts = SeenAt(r, key, entry)
      if ts > oldest then
        local day = entry.a and tostring(floor((ts - DayZero()) / 86400))
        list[#list + 1] = { key, entry.m, day and entry.a[day] or 0, ts }
      end
    end
  end
  return list
end

local function TryNextHost()
  if not join then return end
  if join.timer then join.timer:Cancel(); join.timer = nil end
  join.idx = join.idx + 1
  local key = join.candidates[join.idx]
  local peer = key and ns.peers[key]
  if not peer then
    if join.idx > 1 then
      ns.Log("sync gave up: no host answered")
      Say(join.verbose, "Couldn't finish syncing; it'll try again next time.")
    end
    DoneJoining()
    return
  end
  join.host = key
  local list = AllRecent()
  local p = join.pongs[key] or {}
  ns.Log("host: %s (online since %s%s); uploading your %s",
    peer.name, p.os and date("%H:%M", p.os) or "?", p.rd and "" or ", still syncing itself", ns.Plural(#list, "price"))
  ns.SendEntries({ ns.ReplyTarget(peer) }, list, "BULK", { k = "join" })
  local mine = join
  local function Arm()
    if join ~= mine then return end
    if join.timer then join.timer:Cancel() end
    join.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
      if join == mine then
        ns.Log("%s went quiet for %ds, trying the next host", peer.name, JOIN_TIMEOUT)
        TryNextHost()
      end
    end)
  end
  mine.arm = Arm
  Arm()
end

-- Login (or Sync now): find who's online and compare with a host.
function ns.CatchUp(verbose)
  if verbose then ns.FlushShared() end -- Sync now also sends what's collected so far
  local r = Realm()
  if not r then
    Say(verbose, "Auctionator's prices aren't loaded yet; try again in a moment.")
    return
  end
  if ns.IsScanning() then
    ns.Log("sync waiting for your scan to finish")
    if verbose then ns.Print("Waiting for your scan to finish first.") end
    ns.DeferSync(verbose)
    return
  end
  if join and join.host then
    Say(verbose, "Already syncing.")
    return
  end
  local targets = ns.AllTargets()
  if #targets == 0 then
    if not (ns.db.guild or ns.db.friends or ns.db.bnet) then
      Say(verbose, "Syncing is off: tick guild, friends or Battle.net in |cffffd100/async|r.")
    else
      Say(verbose, "No guild members or friends online to sync with.")
    end
    DoneJoining()
    return
  end
  join = { verbose = verbose, pongs = {}, candidates = {}, idx = 0, started = ns.Now() }
  ns.Log("sync started (%s): saying hello to %s", verbose and "Sync now" or "login", ns.Plural(#targets, "place"))
  for _, t in ipairs(targets) do
    ns.Send(t, { t = "HELLO", r = ns.RealmKey(), j = true }, "ALERT")
  end
  if verbose then ns.Print("Syncing...") end
  local mine = join
  C_Timer.After(PONG_WAIT, function()
    if join ~= mine then return end
    for key, info in pairs(mine.pongs) do
      if ns.peers[key] then mine.candidates[#mine.candidates + 1] = key end
    end
    ns.Log("%s answered", ns.Plural(#mine.candidates, "player"))
    if #mine.candidates == 0 then
      ns.Log("nobody to sync with: your prices go into the next sync")
      Say(verbose, "No one online with AuctionatorSync yet. Your prices join the next sync.")
      DoneJoining()
      return
    end
    table.sort(mine.candidates, function(a, b)
      local pa, pb = mine.pongs[a], mine.pongs[b]
      if (pa.rd and true) ~= (pb.rd and true) then return pa.rd and true or false end
      if pa.os ~= pb.os then return pa.os < pb.os end
      return a < b
    end)
    TryNextHost()
  end)
end

-- Kept for older callers: a plain hello, so friends know we're here.
function ns.Hello()
  for _, t in ipairs(ns.AllTargets()) do
    ns.Send(t, { t = "HELLO", r = ns.RealmKey() }, "NORMAL")
  end
end

----------------------------------------------------------------------------------------------
-- Messages

function ns.OnMessage(msg, peer)
  local r = Realm()
  if not r or msg.r ~= ns.RealmKey() then
    if not peer.otherRealm then
      ns.Log("ignoring %s: prices for %s, not %s", peer.name, tostring(msg.r), tostring(ns.RealmKey()))
    end
    peer.otherRealm = true
    return
  end
  peer.otherRealm = nil
  local peerKey = ns.ShortName(peer.name)
  if join and join.host == peerKey and join.arm then join.arm() end -- the host is still talking

  if msg.t == "HELLO" then
    ns.Send(ns.ReplyTarget(peer), { t = "PONG", r = ns.RealmKey(), os = ns.onlineSince, rd = ns.ready }, "ALERT")

  elseif msg.t == "PONG" then
    -- only peers on this protocol can host (older versions don't send os)
    if join and not join.host and msg.os and (tonumber(msg.p) or 1) >= ns.PROTOCOL then
      join.pongs[peerKey] = { os = tonumber(msg.os) or math.huge, rd = msg.rd }
    end

  elseif msg.t == "DATA" then
    local e, base = msg.e, tonumber(msg.b) or 0
    if type(e) ~= "table" then return end
    local tkey = peerKey .. "/" .. tostring(msg.x)
    local tr = transfers[tkey]
    if not tr then
      -- k = "join": we're their host; "reply": our host answering our join; nil: a live update
      tr = { kind = msg.k or "update", changed = 0, received = 0, brought = {}, theirs = {} }
      transfers[tkey] = tr
    end
    for i = 1, #e - 3, 4 do
      local key, price, avail = tostring(e[i]), tonumber(e[i + 1]), tonumber(e[i + 2])
      local ts = base + (tonumber(e[i + 3]) or 0)
      tr.received = tr.received + 1
      local result, was = Apply(r, key, price, avail, ts)
      if result == "changed" then
        tr.changed = tr.changed + 1
        NoteChange(r, key, price, was, true)
        if tr.kind == "join" then tr.brought[#tr.brought + 1] = { key, price, avail or 0, ts } end
      end
      if tr.kind == "join" and price then tr.theirs[key] = { ts, price } end
    end
    if tr.timer then tr.timer:Cancel() end
    if not msg.fin then
      -- a transfer that never finishes is dropped after a while
      tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
        transfers[tkey] = nil
        ns.Log("prices from %s stopped arriving partway (%s kept)", peer.name, ns.Plural(tr.changed, "change"))
      end)
      return
    end
    transfers[tkey] = nil

    if tr.kind == "join" then
      -- We're the host. Send back what's newer here (or missing there)...
      local reply = {}
      for _, it in ipairs(AllRecent()) do
        local t = tr.theirs[it[1]]
        if not t or (it[4] > t[1] and it[2] ~= t[2]) then reply[#reply + 1] = it end
      end
      ns.SendEntries({ ns.ReplyTarget(peer) }, reply, "BULK", { k = "reply" })
      -- ...and pass what they brought on to everyone else online.
      if #tr.brought > 0 then
        local others = {}
        for _, t in ipairs(ns.PeerTargets()) do
          if not (t.kind ~= "GUILD" and t.name and ns.ShortName(t.name) == peerKey) then others[#others + 1] = t end
        end
        if #others > 0 then ns.SendEntries(others, tr.brought, "NORMAL") end
      end
      Report(tr.changed)
      ns.Log("hosted %s: %s received, %s newer than yours; sent back %s; passed %s on to others",
        peer.name, ns.Num(tr.received), ns.Num(#tr.brought), ns.Plural(#reply, "price"), ns.Num(#tr.brought))

    elseif tr.kind == "reply" and join and join.host == peerKey then
      -- Our join is done: we now hold the group's best prices, and they hold ours.
      local verbose = join.verbose
      r.lastCatchUp = ns.Now()
      wipe(r.unsent) -- the host has everything we had
      ns.Log("sync done with %s: %s received, %s changed", peer.name, ns.Num(tr.received), ns.Num(tr.changed))
      DoneJoining()
      if tr.changed > 0 then
        Say(verbose, "Synced: updated %s.", ns.Plural(tr.changed, "price"))
      else
        Say(verbose, "Up to date.")
      end

    else
      ns.Log("update from %s: %s, %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
      Report(tr.changed)
    end
  end
end

----------------------------------------------------------------------------------------------
-- Auctionator's full scans. Auctionator announces scan start/finish on its EventBus; we
-- register a listener there (no change to Auctionator). A sync waits while a scan runs, so it
-- compares the fresh prices.

local SCAN_TIMEOUT = 900  -- forget a scan that never reported back after 15 minutes
local scanning, scanTimer = false, nil
local deferred -- nil, or the `verbose` of a sync waiting for the scan to finish

function ns.IsScanning() return scanning end
function ns.DeferSync(verbose) deferred = deferred or verbose or false end

local function ScanEnded(completed)
  scanning = false
  if scanTimer then scanTimer:Cancel(); scanTimer = nil end
  if completed then
    local r = Realm()
    if r then r.lastFullScan = ns.Now() end
  end
  if deferred ~= nil then
    local verbose = deferred
    deferred = nil
    ns.CatchUp(verbose)
  end
end

local scanListener = { kinds = {} }
function scanListener:ReceiveEvent(event)
  local kind = self.kinds[event]
  if kind == "start" then
    ns.Log("Auctionator scan started")
    scanning = true
    if scanTimer then scanTimer:Cancel() end
    scanTimer = C_Timer.NewTimer(SCAN_TIMEOUT, function() ScanEnded(false) end)
    -- a sync still asking around waits for the scan, then compares the fresh prices
    if join and not join.host then
      ns.DeferSync(join.verbose)
      join = nil
    end
  elseif kind == "complete" then
    ns.Log("Auctionator scan finished")
    ScanEnded(true)
  elseif kind == "failed" then
    ns.Log("Auctionator scan failed")
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

----------------------------------------------------------------------------------------------

local function PruneTimestamps()
  local cutoff = ns.Now() - TS_KEEP_DAYS * 86400
  for _, r in pairs(ns.store.realms) do
    for key, ts in pairs(r.ts) do
      if ts < cutoff then r.ts[key] = nil end
    end
    -- left over from 0.8 and earlier
    r.ch, r.scanKeys = nil, nil
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
  ns.onlineSince = ns.Now()
  if not ns.canEncode then return end
  PruneTimestamps()
  ns.HookAuctionator()
  ns.WatchScans()
  C_Timer.NewTicker(10, ns.HookAuctionator)
  C_Timer.NewTicker(SHARE_INTERVAL, ns.FlushShared)
end)

-- Once per session, after the first loading screen: the sign-in line, then the sync.
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
    if ns.db.catchUpOnLogin then
      ns.CatchUp(false)
    else
      ns.Hello()
      ns.ready = true
    end
  end)
end)

function ns.PrintStatus()
  local r = Realm()
  ns.Print("v%s on %s.", ns.VERSION, tostring(ns.RealmKey() or "?"))
  if r then
    local count = 0
    for _ in pairs(r.ts) do count = count + 1 end
    ns.Print("Tracking %s. Last sync: %s.", ns.Plural(count, "price"),
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
