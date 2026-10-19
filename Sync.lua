-- The sync itself (protocol 3).
--
-- Auctionator keeps, per item, the last seen price (m) and per-day history (h/l/a), but not
-- *when* during the day a price was seen. AuctionatorSync keeps its own timestamp per item:
--   ts[key] = when this price was last seen (by me or a friend) - the newer one always wins
--
-- The master list: everyone's prices merged, newest per item. Each player has a fingerprint of
-- their whole price list (256 section sums of item+price hashes); equal fingerprints = the same
-- master list. That's what the online list's "In sync" means.
--
-- Two things start a sync:
--   1. Someone comes online: they handshake with a host, picked automatically from the players
--      already in sync (online longest). They compare the 256 section fingerprints and swap
--      prices only for the sections that differ; the host merges (newest wins) into the new
--      master list, sends the newcomer what it was missing, and shares what the newcomer brought
--      with everyone else.
--   2. Your Auctionator prices change (a full scan finishes, or you close the auction house
--      after searching): your changed prices go to everyone online.
-- Safety net: if your fingerprint differs from the host's for 2 minutes (e.g. two people logged
-- in at once), you quietly handshake with the host again.
--
-- Messages (hidden addon data; all carry r = Auctionator's realm key and sid, a per-login ID):
--   HELLO {st, d, os}   I'm here (state, fingerprint, online since)  -> everyone; answered by STATE
--   STATE {st, d, os, w} my state (+ w: who I'm syncing with); also a heartbeat every minute
--   SUM   {b}           newcomer -> host: my 256 section sums
--   NEED  {bk}          host -> newcomer: the sections that differ (empty = already in sync)
--   DATA  {x, e, b, k?, fin?}  prices, e = {key, price, available, ts - b, ...};
--                       k = "join" (newcomer -> host), "reply" (host -> newcomer),
--                           "fwd" (host -> everyone: what a newcomer brought), nil = scan changes
local _, ns = ...

local BATCH = 1500          -- prices per DATA message
local HELLO_WAIT = 5        -- seconds to collect answers to a HELLO
local JOIN_TIMEOUT = 180    -- seconds without hearing from the host before trying again
local HEARTBEAT = 60        -- seconds between STATE heartbeats
local HEAL_AFTER = 120      -- seconds out of sync with the host before re-syncing
local SECTIONS = 256
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
  return newest and (DayZero() + newest * 86400) or 0
end

-- Auctionator keys: "12345" (item), "g:12345:..." (gear by item level), "p:..." (battle pet).
function ns.ItemIDFromKey(key)
  key = tostring(key)
  return tonumber(key:match("^(%d+)$") or key:match("^g:(%d+)"))
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
-- Fingerprint: 256 sections, each the sum (mod 2^32) of hash(item, price) for its items.

local sections, itemCount = {}, 0
for i = 0, SECTIONS - 1 do sections[i] = 0 end

local function Hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % TWO32 end
  return h
end

local function SectionOf(key) return Hash(key) % SECTIONS end

local function Track(key, oldPrice, newPrice)
  local s = SectionOf(key)
  if oldPrice and oldPrice > 0 then
    sections[s] = (sections[s] - Hash(key .. ":" .. oldPrice)) % TWO32
    itemCount = itemCount - 1
  end
  if newPrice and newPrice > 0 then
    sections[s] = (sections[s] + Hash(key .. ":" .. newPrice)) % TWO32
    itemCount = itemCount + 1
  end
end

function ns.Fingerprint()
  local total = 0
  for i = 0, SECTIONS - 1 do total = (total + sections[i]) % TWO32 end
  return string.format("%08x-%d", total, itemCount)
end

local function RebuildFingerprint(data)
  for i = 0, SECTIONS - 1 do sections[i] = 0 end
  itemCount = 0
  for key, entry in pairs(data) do
    if type(entry) == "table" then Track(tostring(key), nil, entry.m) end
  end
end

----------------------------------------------------------------------------------------------
-- Watching Auctionator: prices you scan or search

-- What each item's price was before Auctionator's SetPrice overwrote it (the hook runs after).
local known = {}
local hookedDB
local pending = {} -- key -> price before your latest scan/search changed it (to share)

local function OnLocalPrice(key, price, available)
  local r = Realm()
  if not r or not key or not price then return end
  key = tostring(key)
  r.ts[key] = ns.Now()
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
      if type(entry) == "table" then known[key] = entry.m end
    end
    RebuildFingerprint(db.db)
  end
  hooksecurefunc(db, "SetPrice", function(self, key, price, available)
    if self == hookedDB then OnLocalPrice(key, price, available) end
  end)
  ns.Log("watching Auctionator's prices for %s: %s, fingerprint %s",
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
  if ts > mine then r.ts[key] = ts end
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

-- Every price in the given sections (a set of section numbers).
local function ItemsIn(set)
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  for key, entry in pairs(db.db) do
    if type(entry) == "table" and (entry.m or 0) > 0 and set[SectionOf(tostring(key))] then
      list[#list + 1] = Item(r, tostring(key), entry)
    end
  end
  return list
end

----------------------------------------------------------------------------------------------
-- Sending prices

local transferCounter = 0

-- One transfer of BATCH-sized DATA messages, the last marked fin. target = nil -> everyone.
function ns.SendEntries(target, list, prio, k)
  local realm = ns.RealmKey()
  transferCounter = transferCounter + 1
  local x = transferCounter
  local n, i = #list, 1
  repeat
    local last = math.min(i + BATCH - 1, n)
    local base = math.huge
    for j = i, last do base = math.min(base, list[j][4]) end
    if base == math.huge then base = 0 end
    local e = {}
    for j = i, last do
      local it = list[j]
      e[#e + 1] = it[1]
      e[#e + 1] = it[2]
      e[#e + 1] = it[3] or 0
      e[#e + 1] = it[4] - base
    end
    local msg = { t = "DATA", r = realm, x = x, e = e, b = base, fin = (last >= n) or nil, k = k }
    if target then ns.Send(target, msg, prio) else ns.Broadcast(msg, prio) end
    i = last + 1
  until i > n
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
-- State and the host

ns.onlineSince = nil
ns.state = "starting" -- "waiting" (looking for a host) | "syncing" (handshaking) | "ready"
ns.syncingWith = nil

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

local stateTimer
local function StateMsg(t)
  return { t = t or "STATE", r = ns.RealmKey(), st = ns.state, d = ns.Fingerprint(), os = ns.onlineSince,
    w = ns.syncingWith, ls = ns.LastSync() }
end

-- Tell everyone our state/fingerprint (debounced: several changes in a row send one message).
function ns.AnnounceState()
  if stateTimer then return end
  stateTimer = C_Timer.NewTimer(2, function()
    stateTimer = nil
    if ns.RealmKey() then ns.Broadcast(StateMsg(), "NORMAL") end
  end)
end

local function SetState(st, with)
  ns.state, ns.syncingWith = st, with
  ns.AnnounceState()
end

local function Compatible(peer)
  return (peer.proto or 1) >= ns.PROTOCOL and not peer.otherRealm
end

-- The host: whoever holds the master list - ready, online longest (ties: name). Includes you.
-- Returns peer table, "me", or nil.
function ns.GroupHost()
  local bestOs, bestName, best = nil, nil, nil
  local function Consider(os, name, who)
    if not os then return end
    if not bestOs or os < bestOs or (os == bestOs and name < bestName) then
      bestOs, bestName, best = os, name, who
    end
  end
  if ns.state == "ready" then Consider(ns.onlineSince, ns.ShortName(UnitName("player")), "me") end
  for short, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and Compatible(peer) and peer.st == "ready" then Consider(peer.os, short, peer) end
  end
  return best
end

function ns.MasterFingerprint()
  local host = ns.GroupHost()
  if host == "me" then return ns.Fingerprint() end
  return host and host.d
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
  if not ns.db.shareScans then
    ns.Log("%s changed %s; not shared (sharing is off)", why, ns.Plural(#list, "price"))
    return
  end
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
  ns.SendEntries(nil, list, "NORMAL")
  MarkSynced()
  ns.AnnounceState()
end

----------------------------------------------------------------------------------------------
-- Trigger 1: coming online - the handshake with the host

local join -- { verbose, host = peer, started, timer, sections }
local hosting = {} -- peerKey -> { sections = set } while we host someone's handshake
local transfers = {}

local function FinishJoin(verbose, changed, hostName)
  local r = Realm()
  if join and join.timer then join.timer:Cancel() end
  join = nil
  if r then r.lastCatchUp = ns.Now() end
  MarkSynced()
  SetState("ready")
  if hostName then
    ns.Log("%s is in sync with %s: master list %s, fingerprint %s", ns.MyName(), hostName, ns.Plural(itemCount, "price"), ns.Fingerprint())
  end
  if changed and changed > 0 then
    Say(verbose, "Synced: updated %s.", ns.Plural(changed, "price"))
  elseif hostName then
    Say(verbose, "Up to date.")
  end
end

local function Handshake(host, verbose)
  if join and join.timer then join.timer:Cancel() end
  join = { verbose = verbose, host = host, started = ns.Now() }
  SetState("syncing", host.name)
  ns.Log("%s is handshaking with %s (host, online since %s): comparing %s",
    ns.MyName(), host.name, host.os and date("%H:%M", host.os) or "?", ns.Plural(itemCount, "price"))
  local b = {}
  for i = 0, SECTIONS - 1 do b[i + 1] = sections[i] end
  ns.Send(ns.ReplyTarget(host), { t = "SUM", r = ns.RealmKey(), b = b }, "ALERT")
  local mine = join
  join.arm = function()
    if join ~= mine then return end
    if join.timer then join.timer:Cancel() end
    join.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
      if join ~= mine then return end
      ns.Log("%s stopped answering; looking for another host", host.name)
      host.gone = true
      join = nil
      ns.CatchUp(verbose)
    end)
  end
  join.arm()
end

-- Login / Sync now: find who's online, then handshake with the host.
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
  ns.Log("looking for players with AuctionatorSync (%s)", routes ~= "" and routes or "no routes")
  if verbose then ns.Print("Syncing...") end
  C_Timer.After(HELLO_WAIT, function()
    if join then return end
    local answered = {}
    for _, peer in pairs(ns.peers) do
      if ns.IsPeerOnline(peer) then
        answered[#answered + 1] = string.format("%s (%s)", peer.name,
          not Compatible(peer) and ("v" .. tostring(peer.version) .. ", can't sync") or (peer.st or "?"))
      end
    end
    table.sort(answered)
    if #answered > 0 then
      ns.Log("online: %s", table.concat(answered, ", "))
    else
      ns.Log("nobody else online with AuctionatorSync")
    end

    local host = ns.GroupHost()
    if host and host ~= "me" then
      Handshake(host, verbose)
      return
    end
    -- Nobody holds a master list yet (alone, or everyone just logged in): the one online
    -- longest starts it; everyone else handshakes with them once they're ready.
    local first, firstOs = "me", ns.onlineSince or 0
    for _, peer in pairs(ns.peers) do
      if ns.IsPeerOnline(peer) and Compatible(peer) and (peer.os or math.huge) < firstOs then
        first, firstOs = peer, peer.os
      end
    end
    if first == "me" then
      if host == "me" then
        Say(verbose, "Up to date (holding the master list).")
      else
        ns.Log("%s starts the master list: %s, fingerprint %s", ns.MyName(), ns.Plural(itemCount, "price"), ns.Fingerprint())
        Say(verbose, #answered > 0 and "Up to date." or "No one online with AuctionatorSync yet. These prices join the next sync.")
      end
      local rr = Realm()
      if rr then rr.lastCatchUp = ns.Now() end
      MarkSynced()
      SetState("ready")
    else
      ns.Log("%s is starting the master list; handshaking with them when they're ready", first.name)
      C_Timer.After(HELLO_WAIT, function() if not join and ns.state ~= "ready" then ns.CatchUp(verbose) end end)
    end
  end)
end

----------------------------------------------------------------------------------------------
-- Messages

local function NoteState(peer, msg, isHello)
  local was, wasD, wasOffline = peer.st, peer.d, peer.lastHeard == nil
  peer.st, peer.d, peer.os, peer.w, peer.ls = msg.st, msg.d, tonumber(msg.os), msg.w, tonumber(msg.ls)
  peer.lastHeard = ns.Now()
  if isHello or wasOffline then
    ns.Log("%s came online (v%s)", peer.name, tostring(peer.version))
  end
  if msg.st == "syncing" and was ~= "syncing" and msg.w then
    ns.Log("%s is handshaking with %s", peer.name, msg.w)
  end
  if msg.st == "ready" and (was ~= "ready" or wasD ~= msg.d) then
    local master = ns.MasterFingerprint()
    if master and msg.d == master then
      ns.Log("%s is in sync (fingerprint %s)", peer.name, tostring(msg.d))
    else
      ns.Log("%s is ready, but their prices differ from the master list", peer.name)
    end
  end
end

function ns.OnMessage(msg, peer)
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
    if not peer.warned then
      peer.warned = true
      ns.Log("%s came online on v%s, which can't sync with v%s - they need to update",
        peer.name, tostring(msg.v), ns.VERSION)
    end
    return
  end
  local peerKey = ns.ShortName(peer.name)
  if join and join.host == peer and join.arm then join.arm() end

  if msg.t == "HELLO" then
    NoteState(peer, msg, true)
    ns.Send(ns.ReplyTarget(peer), StateMsg(), "ALERT")

  elseif msg.t == "STATE" then
    NoteState(peer, msg, false)

  elseif msg.t == "SUM" then
    -- We're the host for their handshake: which sections differ?
    local diff, set = {}, {}
    for i = 0, SECTIONS - 1 do
      if tonumber(type(msg.b) == "table" and msg.b[i + 1]) ~= sections[i] then
        diff[#diff + 1] = i
        set[i] = true
      end
    end
    ns.Log("%s is handshaking with %s (host): %d of %d sections differ", peer.name, ns.MyName(), #diff, SECTIONS)
    hosting[peerKey] = #diff > 0 and { sections = set } or nil
    ns.Send(ns.ReplyTarget(peer), { t = "NEED", r = ns.RealmKey(), bk = diff }, "ALERT")
    if #diff == 0 then ns.Log("%s already has the master list", peer.name) end

  elseif msg.t == "NEED" then
    if not join or join.host ~= peer then return end
    local bk = type(msg.bk) == "table" and msg.bk or {}
    if #bk == 0 then
      ns.Log("%s's prices already match the master list held by %s", ns.MyName(), peer.name)
      FinishJoin(join.verbose, 0, peer.name)
      return
    end
    local set = {}
    for _, i in ipairs(bk) do set[tonumber(i)] = true end
    join.sections = set
    local list = ItemsIn(set)
    ns.Log("%d of %d sections differ: %s sends %s %s from those sections", #bk, SECTIONS, ns.MyName(), peer.name, ns.Plural(#list, "price"))
    ns.SendEntries(ns.ReplyTarget(peer), list, "BULK", "join")

  elseif msg.t == "DATA" then
    local e, base = msg.e, tonumber(msg.b) or 0
    if type(e) ~= "table" then return end
    local tkey = peerKey .. "/" .. tostring(msg.x)
    local tr = transfers[tkey]
    if not tr then
      tr = { kind = msg.k or "update", changed = 0, received = 0, brought = {}, theirs = {} }
      transfers[tkey] = tr
    end
    local force = tr.kind == "reply"
    for i = 1, #e - 3, 4 do
      local key, price, avail = tostring(e[i]), tonumber(e[i + 1]), tonumber(e[i + 2])
      local ts = base + (tonumber(e[i + 3]) or 0)
      tr.received = tr.received + 1
      if Apply(r, key, price, avail, ts, force) == "changed" then
        tr.changed = tr.changed + 1
        if tr.kind == "join" then tr.brought[#tr.brought + 1] = { key, price, avail or 0, ts } end
      end
      if tr.kind == "join" and price then tr.theirs[key] = price end
    end
    if tr.timer then tr.timer:Cancel() end
    if not msg.fin then
      tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
        transfers[tkey] = nil
        ns.Log("prices from %s stopped arriving partway (%s kept)", peer.name, ns.Plural(tr.changed, "change"))
      end)
      return
    end
    transfers[tkey] = nil

    if tr.kind == "join" then
      -- Host: merge done. Send them what differs, share what they brought.
      local h = hosting[peerKey]
      hosting[peerKey] = nil
      ns.Log("%s received %s from %s; %s newer than %s's", ns.MyName(), ns.Plural(tr.received, "price"), peer.name, ns.Num(tr.changed), ns.MyName())
      ns.Log("new master list generated: %s, fingerprint %s", ns.Plural(itemCount, "price"), ns.Fingerprint())
      local reply = {}
      for _, it in ipairs(ItemsIn(h and h.sections or {})) do
        if tr.theirs[it[1]] ~= it[2] then reply[#reply + 1] = it end
      end
      ns.Log("sending %s the master list for those sections: %s", peer.name, ns.Plural(#reply, "price"))
      ns.SendEntries(ns.ReplyTarget(peer), reply, "BULK", "reply")
      if #tr.brought > 0 then
        local others = 0
        for short, p in pairs(ns.peers) do
          if short ~= peerKey and ns.IsPeerOnline(p) and Compatible(p) then others = others + 1 end
        end
        if others > 0 then
          ns.Log("master list ready: sharing the %s from %s with %s", ns.Plural(#tr.brought, "new price"),
            peer.name, ns.Plural(others, "other player"))
          ns.SendEntries(nil, tr.brought, "NORMAL", "fwd")
        end
      end
      MarkSynced()
      Report(tr.changed)
      ns.AnnounceState()

    elseif tr.kind == "reply" then
      if join and join.host == peer then
        ns.Log("%s received the master list from %s: %s, %s changed", ns.MyName(), peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
        FinishJoin(join.verbose, tr.changed, peer.name)
      end

    elseif tr.kind == "fwd" then
      ns.Log("%s (host) shared a newcomer's prices: %s, %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
      MarkSynced()
      Report(tr.changed)
      ns.AnnounceState()

    else
      ns.Log("%s shared %s from their scan: %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
      MarkSynced()
      Report(tr.changed)
      ns.AnnounceState()
    end
  end
end

----------------------------------------------------------------------------------------------
-- Heartbeat, who went offline, and the safety net

local mismatchSince

C_Timer.NewTicker(30, function()
  if not ns.store or not ns.RealmKey() or ns.state == "starting" then return end
  for _, peer in pairs(ns.peers) do
    if not peer.gone and peer.lastSeen and not ns.IsPeerOnline(peer) then
      peer.gone = true
      peer.lastHeard = nil
      ns.Log("%s went offline", peer.name)
    end
  end
  -- Safety net: out of sync with the host for HEAL_AFTER seconds -> handshake again.
  local host = ns.GroupHost()
  if ns.state == "ready" and not join and host and host ~= "me" and host.d ~= ns.Fingerprint()
    and not ns.IsScanning() and not next(pending) then
    mismatchSince = mismatchSince or ns.Now()
    if ns.Now() - mismatchSince >= HEAL_AFTER then
      mismatchSince = nil
      ns.Log("%s's prices have differed from the master list for %ds: re-syncing with %s", ns.MyName(), HEAL_AFTER, host.name)
      Handshake(host, false)
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

local scanListener = { kinds = {} }
function scanListener:ReceiveEvent(event)
  local kind = self.kinds[event]
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
    if ns.db.catchUpOnLogin then
      ns.CatchUp(false)
    else
      ns.Log("syncing at login is off: %s gets scan updates, but no handshake", ns.MyName())
      SetState("ready")
      ns.Broadcast(StateMsg("HELLO"), "NORMAL", true)
    end
  end)
end)

----------------------------------------------------------------------------------------------
-- Who's online and in sync (the /async list and /async status)

-- rows: { name, version, text, color, rank, lastSync, host, me }, host first.
-- rank orders statuses for sorting: in sync, handshaking, waiting, not in sync, needs update.
function ns.StatusRows()
  local host = ns.GroupHost()
  local master = ns.MasterFingerprint()
  local function Text(st, d, with, compatible, version)
    if not compatible then return "needs update", "808080", 5 end
    if st == "syncing" then return "handshaking" .. (with and (" with " .. with) or ""), "ffd100", 2 end
    if st ~= "ready" then return "waiting to sync", "ffd100", 3 end
    if master and d == master then return "in sync", "33ff99", 1 end
    return "not in sync yet", "ff5555", 4
  end
  local rows = {}
  local myText, myColor, myRank = Text(ns.state, ns.Fingerprint(), ns.syncingWith, true)
  rows[#rows + 1] = { name = ns.MyName(), version = ns.VERSION, text = myText, color = myColor, rank = myRank,
    lastSync = ns.LastSync(), host = host == "me", me = true }
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and not peer.otherRealm then
      local t, c, rank = Text(peer.st, peer.d, peer.w, Compatible(peer), peer.version)
      rows[#rows + 1] = { name = peer.name, version = peer.version, text = t, color = c, rank = rank,
        lastSync = peer.ls, host = host == peer }
    end
  end
  table.sort(rows, function(a, b)
    if a.host ~= b.host then return a.host end
    if (a.me or false) ~= (b.me or false) then return a.me and true or false end
    return a.name < b.name
  end)
  return rows
end

function ns.PrintStatus()
  local r = Realm()
  ns.Print("v%s on %s: %s, fingerprint %s.", ns.VERSION, tostring(ns.RealmKey() or "?"),
    ns.Plural(itemCount, "price"), ns.Fingerprint())
  if r then
    local ls = ns.LastSync()
    ns.Print("Last sync: %s.", (ls or 0) > 0 and date("%d %b %H:%M", ls) or "never")
  end
  for _, row in ipairs(ns.StatusRows()) do
    ns.Print("  %s%s v%s: |cff%s%s|r, last sync %s", row.name, row.host and " (host)" or "", tostring(row.version),
      row.color, row.text, row.lastSync and date("%H:%M", row.lastSync) or "unknown")
  end
end
