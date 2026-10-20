-- The sync itself (protocol 4).
--
-- Auctionator keeps, per item, the last seen price (m) and per-day history (h/l/a), but not
-- *when* during the day a price was seen. AuctionatorSync keeps its own timestamp per item:
--   ts[key] = when this price was last seen (by me or a friend) - the newer one always wins
-- Merging is newest-wins per item (ties: the lower price), so merges give the same result in any
-- order: two versions of the list are combined by any handshake between them, nothing is lost.
--
-- The master list: each player has a fingerprint of their whole price list (256 section sums of
-- item+price hashes). The master list is the fingerprint most ready players hold; "in sync" means
-- holding it. A fingerprint says only "same or different" - which price is newer is decided per
-- item. Each player also shares the time of their newest price (nt).
--
-- Two things start a sync:
--   1. Someone comes online: they compare section sums with an in-sync player (any of them can
--      host; the least busy is picked), then swap prices for the sections that differ - spread
--      across up to 4 in-sync hosts when many differ (swarming), each merging its share and
--      passing what's new to everyone. A host that goes quiet has its share moved to another.
--   2. Your Auctionator prices change (a full scan finishes, or you close the auction house
--      after searching): your changed prices go to everyone online.
-- Safety net: out of step with the master list for 2 minutes -> handshake again (also how two
-- versions that met get merged).
--
-- Messages (hidden addon data; all carry r = Auctionator's realm key and sid, a per-login ID):
--   HELLO {st, d, os, w, ls, nt, hl, pg}  I'm here -> everyone; answered by STATE
--   STATE {...same}     state, fingerprint, online since, syncing with, last sync, newest price,
--                       hosting load, handshake progress; also a heartbeat every minute
--   SUM   {b}           newcomer -> one host: my 256 section sums
--   NEED  {bk}          host -> newcomer: the sections that differ (empty = already in sync)
--   DATA  {x, e, b, k?, fin?, bk?, pc?, tot?}  prices, e = {key, price, available, ts - b, ...};
--                       k = "join" (newcomer -> host: a piece, its sections bk, piece id pc),
--                           "reply" (host -> newcomer: the piece's merged prices, tot of them),
--                           "fwd" (host -> everyone: what a newcomer brought), nil = scan changes
local _, ns = ...

local BATCH = 500           -- prices per DATA message (smaller = finer progress in the log)
local HELLO_WAIT = 5        -- seconds to collect answers to a HELLO
local JOIN_TIMEOUT = 180    -- seconds without hearing from the host before trying again
local HEARTBEAT = 60        -- seconds between STATE heartbeats
local HEAL_AFTER = 120      -- seconds out of sync with the host before re-syncing
local SINCE_MARGIN = 600    -- a quick handshake re-sends prices from a little before the last sync
local COMPARE_TIMEOUT = 45  -- the compare step is two small messages: no answer by then, try another host
local STALL_TIMEOUT = 60    -- a handshake piece with no prices moving either way for this long is dropped
local BENCH_TIME = 600      -- a host dropped for that is not picked again for this long (10 minutes)
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
-- Fingerprint: 256 sections, each the sum (mod 2^32) of hash(item, price) for its items.

local sections, itemCount = {}, 0
local newestTs = 0 -- when the newest price in this list was seen (shared as nt)
function ns.NewestPrice() return newestTs end
for i = 0, SECTIONS - 1 do sections[i] = 0 end

local function Hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % TWO32 end
  return h
end

local function SectionOf(key) return Hash(key) % SECTIONS end

ns.dataVersion = 0 -- bumped on every price / seen-time change (the Price List rebuilds on it)

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
      if type(entry) == "table" then known[key] = entry.m end
    end
    RebuildFingerprint(db.db)
  end
  local r = Realm()
  if r then
    for _, ts in pairs(r.ts) do if ts > newestTs then newestTs = ts end end
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
-- extra: fields copied onto every message (a handshake piece's bk / pc). Every message carries
-- tot (the transfer's size), and each batch logs when it has actually been sent.
local KIND_WORDS = { join = "handshake piece", reply = "handshake reply", fwd = "share-out" }
ns.KIND_WORDS = KIND_WORDS

-- Transfers we're sending right now (for the Sync Monitor): { to, kind, tot, sent, started }
ns.outgoing = {}

function ns.SendEntries(target, list, prio, k, extra)
  local realm = ns.RealmKey()
  transferCounter = transferCounter + 1
  local x = transferCounter
  local n = #list
  local label = string.format("%s -> %s", ns.MyName(), target and (target.name or "?") or "everyone")
  local what = KIND_WORDS[k] or "scan prices"
  local batches = math.max(1, math.ceil(n / BATCH))
  local out = { to = target and (target.name or "?") or "everyone", toKey = target and target.name and ns.ShortName(target.name),
    kind = k, tot = n, sent = 0, started = ns.Now() }
  if n > 0 then
    ns.outgoing[out] = true
    -- forget it if the throttle never reports the last batch (e.g. a disconnect)
    C_Timer.After(900, function() ns.outgoing[out] = nil end)
  end

  -- One batch at a time: the next is only queued once this one has actually gone out, so a
  -- transfer can be stopped midway (out.cancelled) instead of the whole thing sitting queued.
  local function SendBatch(i)
    if out.cancelled then
      ns.outgoing[out] = nil
      return
    end
    local last = math.min(i + BATCH - 1, n)
    local base = math.huge
    for j = i, last do base = math.min(base, list[j][4]) end
    if base == math.huge then base = 0 end
    local e = {}
    for j = i, last do
      local it = list[j]
      e[#e + 1] = tonumber(it[1]) or it[1] -- plain item IDs as numbers: smaller than text
      e[#e + 1] = it[2]
      e[#e + 1] = it[3] or 0
      e[#e + 1] = it[4] - base
    end
    local msg = { t = "DATA", r = realm, x = x, e = e, b = base, fin = (last >= n) or nil, k = k, tot = n }
    for field, value in pairs(extra or {}) do msg[field] = value end
    local function onSent()
      out.sent = math.max(out.sent, last)
      if batches > 1 and n > 0 then
        ns.Log("%s: sent %s / %s (%s, %d%%)", label, ns.Num(last), ns.Plural(n, "price"), what, floor(last / n * 100))
      end
      if out.sent >= n then ns.outgoing[out] = nil end
      if ns.OnSendProgress then ns.OnSendProgress() end
      ns.AnnounceState()
      if last < n then SendBatch(last + 1) end
    end
    if target then ns.Send(target, msg, prio, nil, onSent) else ns.Broadcast(msg, prio, nil, onSent) end
  end
  SendBatch(1)
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
    sp = ns.SendProgress and ns.SendProgress() or nil }
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
  if st ~= "syncing" then ns.syncProgress = nil end
  ns.AnnounceState()
end

local function Compatible(peer)
  return (peer.proto or 1) >= ns.PROTOCOL and not peer.otherRealm
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

-- Who can host a handshake: any ready player holding the master list. Least busy first, then
-- Battle.net friends (16x bigger messages), then random, so newcomers spread out instead of
-- queueing behind one player. exclude = a set of peers to leave out.
-- Hosts that stalled or didn't answer sit out for BENCH_TIME: not picked for any handshake.
local benched = {} -- peerKey -> until (server time)

local function IsBenched(peer)
  local untilTs = benched[ns.ShortName(peer.name)]
  return untilTs ~= nil and untilTs > ns.Now()
end

local function Bench(peer, why)
  benched[ns.ShortName(peer.name)] = ns.Now() + BENCH_TIME
  ns.Log("%s benched as a host for %d min (%s)", peer.name, BENCH_TIME / 60, why)
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

local function Hosts(master, exclude)
  local list = {}
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and Compatible(peer) and peer.st == "ready" and peer.d == master
      and not (exclude and exclude[peer]) and not IsBenched(peer) then
      peer.pick = math.random()
      list[#list + 1] = peer
    end
  end
  table.sort(list, function(a, b)
    local la, lb = a.hl or 0, b.hl or 0
    if la ~= lb then return la < lb end
    local ba, bb = ns.ReplyTarget(a).kind == "BN", ns.ReplyTarget(b).kind == "BN"
    if ba ~= bb then return ba end
    return a.pick < b.pick
  end)
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
-- Trigger 1: coming online - the handshake (swarmed across hosts when it's big)
--
--   1. The newcomer sends its 256 section sums to one host (the least busy in-sync player);
--      the host answers with the sections that differ.
--   2. The differing sections are dealt out in pieces across in-sync hosts, which all hold the
--      same list, so the pieces fit together. How many hosts: see HostCount below. The pieces
--      fit together.
--   3. Per piece: the newcomer sends its prices for those sections; the host merges them
--      (newest wins), sends back its prices that differ, and shares what the newcomer brought
--      with everyone else.
--   4. A host that goes quiet has its piece moved to another host.

local SECTIONS_PER_HOST = 16 -- each host gets at least this many sections (smaller isn't worth it)
local SWARM_MAX = 6          -- never more hosts than this (past it the newcomer's own sending dominates)

local join -- { verbose, probe, pieces = { [id] = piece }, bad = { [peer] = true }, changed, nextId }
local transfers = {}

-- Price transfers arriving right now (not counting handshake pieces we're hosting).
function ns.Receiving()
  local n = 0
  for _, tr in pairs(transfers) do
    if tr.kind ~= "join" then n = n + 1 end
  end
  return n
end

-- For the Sync Monitor (and shared in STATE so others can show it too):
-- how many hosts our handshake is pulling from, the master list it's syncing to, and how far
-- our incoming / outgoing transfers have got (percent, nil when there are none).
function ns.MyHostsCount()
  if not join then return nil end
  local hosts = {}
  for _, piece in pairs(join.pieces) do hosts[piece.host] = true end
  local n = 0
  for _ in pairs(hosts) do n = n + 1 end
  return n > 0 and n or 1
end

function ns.MyTarget() return join and join.target or nil end

function ns.ReceiveAmounts()
  local got, tot = 0, 0
  for _, tr in pairs(transfers) do
    if tr.kind ~= "join" and tr.kind ~= "reply" and tr.tot then
      got, tot = got + tr.received, tot + tr.tot
    end
  end
  return got, tot
end

function ns.ReceiveProgress()
  local got, tot = ns.ReceiveAmounts()
  return tot > 0 and floor(got / tot * 100) or nil
end

-- what we're sending outside our own handshake (scan shares, share-outs, replies we host)
function ns.SendAmounts()
  local sent, tot = 0, 0
  for out in pairs(ns.outgoing) do
    if out.kind ~= "join" then sent, tot = sent + out.sent, tot + out.tot end
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
    if tr.tot and tr.kind ~= "join" then
      list[#list + 1] = { dir = "in", who = tr.from, kind = tr.kind, done = tr.received, tot = tr.tot, started = tr.started }
    end
  end
  return list
end

function ns.Pieces()
  local list = {}
  for _, piece in pairs(join and join.pieces or {}) do
    list[#list + 1] = { host = piece.host.name, sections = #piece.list, done = piece.done,
      got = piece.received or 0, tot = piece.tot }
  end
  return list
end

function ns.IsCompatible(peer) return (peer.proto or 1) >= ns.PROTOCOL and not peer.otherRealm end

local function HostNames()
  local names, seen = {}, {}
  for _, piece in pairs(join and join.pieces or {}) do
    if not piece.done and not seen[piece.host] then
      seen[piece.host] = true
      names[#names + 1] = piece.host.name
    end
  end
  if #names == 0 then return join and join.probe and join.probe.name end
  table.sort(names)
  return names[1] .. (#names > 1 and (" +" .. (#names - 1)) or "")
end

-- Progress over the whole handshake, by prices moved: what we've uploaded to each host plus what
-- each host has sent back (until a reply's size is known, assume it's about what we sent).
-- The step we're on goes in ns.syncPhase: "comparing", "sending x / y" or "receiving x / y".
local function UpdateProgress()
  if not join then return end
  if not next(join.pieces) then
    ns.syncProgress = 1
    ns.syncPhase = "comparing - waiting for " .. (join.probe and join.probe.name or "the host")
    ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
    ns.AnnounceState()
    return
  end
  local upDone, upTot, inDone, inTot = 0, 0, 0, 0
  for _, piece in pairs(join.pieces) do
    local ut = piece.up and piece.up.tot or 0
    local ud = piece.up and piece.up.sent or 0
    local rt = piece.tot or math.max(ut, 1)
    local rd = piece.done and rt or math.min(piece.received or 0, rt)
    upDone, upTot, inDone, inTot = upDone + ud, upTot + ut, inDone + rd, inTot + rt
  end
  local total = upTot + inTot
  ns.syncProgress = total > 0 and math.min(99, math.max(1, floor((upDone + inDone) / total * 100))) or 1
  if upDone < upTot then
    ns.syncStep, ns.syncDone, ns.syncTotal = "sending", upDone, upTot
  else
    ns.syncStep, ns.syncDone, ns.syncTotal = "receiving", inDone, inTot
  end
  ns.syncPhase = string.format("%s %s / %s", ns.syncStep, ns.Num(ns.syncDone), ns.Num(ns.syncTotal))
  ns.syncingWith = HostNames()
  ns.AnnounceState()
end
ns.OnSendProgress = function()
  if not join then return end
  for _, piece in pairs(join.pieces) do
    if piece.up and piece.up.sent ~= piece.lastUp then
      piece.lastUp = piece.up.sent
      piece.lastProgress = ns.Now()
    end
  end
  UpdateProgress()
end

local function FinishJoin(verbose, changed, via)
  local r = Realm()
  if join then
    for _, piece in pairs(join.pieces) do if piece.timer then piece.timer:Cancel() end end
    if join.timer then join.timer:Cancel() end
  end
  join = nil
  local master = ns.Master()
  if r and (not master or ns.Fingerprint() == master) then r.lastCatchUp = ns.Now() end
  MarkSynced()
  SetState("ready")
  if via then
    ns.Log("%s is in sync (via %s): master list %s, fingerprint %s", ns.MyName(), via,
      ns.Plural(itemCount, "price"), ns.Fingerprint())
  end
  if changed and changed > 0 then
    Say(verbose, "Synced: updated %s.", ns.Plural(changed, "price"))
  elseif via then
    Say(verbose, "Up to date.")
  end
end

local function GiveUp()
  local verbose = join and join.verbose
  ns.Log("%s couldn't finish syncing: no in-sync host answered; trying again later", ns.MyName())
  Say(verbose, "Couldn't finish syncing; it'll try again shortly.")
  FinishJoin(verbose, join and join.changed, nil)
end

local SendPiece -- forward declaration (pieces re-send themselves on reassignment)

-- Drop a stalled piece: tell that host to stop, stop our upload to it, bench it, and give the
-- piece to another in-sync host. No host left: stop the handshake cleanly and retry later.
local function KickPiece(piece, why)
  local old = piece.host
  if piece.up then piece.up.cancelled = true end
  ns.Send(ns.ReplyTarget(old), { t = "CANCEL", r = ns.RealmKey(), pc = piece.id }, "ALERT")
  Bench(old, why)
  join.bad[old] = true
  local hosts = Hosts(ns.Master(), join.bad)
  if not hosts[1] then
    GiveUp()
    return
  end
  ns.Log("%s dropped %s (%s); moving %d sections to %s", ns.MyName(), old.name, why, #piece.list, hosts[1].name)
  piece.host, piece.received, piece.tot, piece.lastUp = hosts[1], 0, nil, nil
  SendPiece(piece)
end

SendPiece = function(piece)
  local items = ItemsIn(piece.set)
  local all = #items
  if join.since then
    -- At our last sync our list matched the master list, so only prices seen since then can be
    -- news to the host. (If that turns out wrong, the self-repair does a full handshake.)
    local newer = {}
    for _, it in ipairs(items) do
      if it[4] > join.since then newer[#newer + 1] = it end
    end
    items = newer
  end
  ns.Log("%s sends %s %s from %d sections to merge%s", ns.MyName(), piece.host.name,
    ns.Plural(#items, "price"), #piece.list,
    join.since and string.format(" (only those seen since %s; %s in those sections)", date("%H:%M", join.since), ns.Num(all)) or "")
  piece.up = ns.SendEntries(ns.ReplyTarget(piece.host), items, "BULK", "join",
    { bk = piece.list, pc = piece.id, sn = join.since })
  piece.lastProgress = ns.Now()
  UpdateProgress()
end

-- Step 2: deal the differing sections out to hosts.
-- How many hosts one handshake uses: the smallest of
--   half the free in-sync hosts (so others logging in at the same time still find one),
--   the differing sections / SECTIONS_PER_HOST, and SWARM_MAX - but always at least 1.
local function HostCount(differing, candidates)
  local free = 0
  for _, h in ipairs(candidates) do
    if (h.hl or 0) == 0 then free = free + 1 end
  end
  return math.max(1, math.min(floor(free / 2), floor(differing / SECTIONS_PER_HOST), SWARM_MAX))
end

local function StartPieces(bk)
  local candidates = Hosts(ns.Master(), join.bad)
  local want = HostCount(#bk, candidates)
  local hosts = { join.probe }
  for _, h in ipairs(candidates) do
    if h ~= join.probe and #hosts < want then hosts[#hosts + 1] = h end
  end
  local per = math.ceil(#bk / #hosts)
  local parts = {}
  for i, h in ipairs(hosts) do
    local list, set = {}, {}
    for j = (i - 1) * per + 1, math.min(i * per, #bk) do
      local s = tonumber(bk[j])
      if s then
        list[#list + 1] = s
        set[s] = true
      end
    end
    if #list > 0 then
      join.nextId = join.nextId + 1
      local piece = { id = join.nextId, host = h, list = list, set = set, received = 0 }
      join.pieces[piece.id] = piece
      parts[#parts + 1] = string.format("%s (%d)", h.name, #list)
    end
  end
  ns.Log("%d of %d sections differ: %s", #bk, SECTIONS, #parts > 1
    and ("splitting across " .. #parts .. " hosts: " .. table.concat(parts, ", ")) or ("all from " .. join.probe.name))
  for _, piece in pairs(join.pieces) do SendPiece(piece) end
end

-- Step 1: compare section sums with one host.
-- full = compare everything; otherwise only prices seen since our last sync travel (see SendPiece).
local function StartHandshake(verbose, probe, full)
  if join then
    for _, piece in pairs(join.pieces) do if piece.timer then piece.timer:Cancel() end end
    if join.timer then join.timer:Cancel() end
  end
  local r = Realm()
  local last = r and r.lastCatchUp or 0
  local since = (not full and last > 0) and (last - SINCE_MARGIN) or nil
  join = { verbose = verbose, probe = probe, pieces = {}, bad = {}, changed = 0, nextId = 0, target = ns.Master(),
    since = since, full = full }
  SetState("syncing", probe.name)
  ns.syncProgress = 0
  ns.Log("%s is comparing with %s (in sync%s): %s, %s", ns.MyName(), probe.name,
    (probe.hl or 0) > 0 and (", hosting " .. probe.hl) or "", ns.Plural(itemCount, "price"),
    since and ("changes since last sync " .. date("%d %b %H:%M", last)) or "full compare")
  local b = {}
  for i = 0, SECTIONS - 1 do b[i + 1] = sections[i] end
  ns.syncPhase = "comparing - waiting for " .. probe.name
  ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
  ns.Send(ns.ReplyTarget(probe), { t = "SUM", r = ns.RealmKey(), b = b }, "ALERT", nil, function()
    ns.Log("%s sent its section sums to %s; waiting for the comparison", ns.MyName(), probe.name)
  end)
  UpdateProgress()
  local mine = join
  join.timer = C_Timer.NewTimer(COMPARE_TIMEOUT, function()
    if join ~= mine or next(mine.pieces) then return end
    mine.bad[probe] = true
    Bench(probe, string.format("no answer to the compare in %ds", COMPARE_TIMEOUT))
    local hosts = Hosts(ns.Master(), mine.bad)
    if hosts[1] then
      ns.Log("%s didn't answer; comparing with %s instead", probe.name, hosts[1].name)
      local bad = mine.bad
      StartHandshake(verbose, hosts[1], mine.full)
      join.bad = bad
    else
      GiveUp()
    end
  end)
end

-- Login / Sync now: find who's online, then handshake.
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
        local extra = not Compatible(peer) and ("v" .. tostring(peer.version) .. ", can't sync")
          or ((peer.st or "?") .. ((peer.hl or 0) > 0 and (", hosting " .. peer.hl) or ""))
        answered[#answered + 1] = string.format("%s (%s)", peer.name, extra)
      end
    end
    table.sort(answered)
    if #answered > 0 then
      ns.Log("online: %s", table.concat(answered, ", "))
    else
      ns.Log("nobody else online with AuctionatorSync")
    end

    local hosts = Hosts(ns.Master())
    if hosts[1] then
      StartHandshake(verbose, hosts[1])
      return
    end
    -- Nobody is ready yet (alone, or everyone just logged in): the one online longest starts
    -- the master list; everyone else handshakes once they're ready.
    local first, firstOs = "me", ns.onlineSince or 0
    for _, peer in pairs(ns.peers) do
      if ns.IsPeerOnline(peer) and Compatible(peer) and (peer.os or math.huge) < firstOs then
        first, firstOs = peer, peer.os
      end
    end
    if first == "me" then
      if ns.state == "ready" then
        Say(verbose, "Up to date (holding the master list).")
      else
        ns.Log("%s starts the master list: %s, fingerprint %s", ns.MyName(), ns.Plural(itemCount, "price"), ns.Fingerprint())
        Say(verbose, #answered > 0 and "Up to date." or "No one online with AuctionatorSync yet. These prices join the next sync.")
      end
      local rr = Realm()
      if rr then rr.lastCatchUp = ns.Now() end
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
  local was, wasD, wasOffline, wasHl = peer.st, peer.d, peer.lastHeard == nil, peer.hl or 0
  peer.st, peer.d, peer.os, peer.w = msg.st, msg.d, tonumber(msg.os), msg.w
  peer.ls, peer.nt, peer.hl, peer.pg = tonumber(msg.ls), tonumber(msg.nt), tonumber(msg.hl) or 0, tonumber(msg.pg)
  peer.rx = tonumber(msg.rx) or 0
  peer.hc, peer.tg, peer.rp, peer.sp = tonumber(msg.hc), msg.tg, tonumber(msg.rp), tonumber(msg.sp)
  peer.ph = msg.ph
  peer.hs, peer.hd, peer.ht = msg.hs, tonumber(msg.hd), tonumber(msg.ht)
  peer.ra, peer.rt, peer.sa, peer.st2 = tonumber(msg.ra), tonumber(msg.rt), tonumber(msg.sa), tonumber(msg.st2)
  peer.lastHeard = ns.Now()
  if isHello or wasOffline then
    ns.Log("%s came online (v%s)", peer.name, tostring(peer.version))
  end
  if msg.st == "syncing" and was ~= "syncing" and msg.w then
    ns.Log("%s is handshaking with %s", peer.name, msg.w)
  end
  if peer.hl > 0 and peer.hl ~= wasHl then
    ns.Log("%s is hosting %s", peer.name, ns.Plural(peer.hl, "handshake"))
  end
  if msg.st == "ready" and (was ~= "ready" or wasD ~= msg.d) then
    local master = ns.Master()
    if master and msg.d == master then
      ns.Log("%s is in sync (fingerprint %s)", peer.name, tostring(msg.d))
    else
      ns.Log("%s is ready, but their prices differ from the master list", peer.name)
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

  if msg.t == "HELLO" then
    NoteState(peer, msg, true)
    ns.Send(ns.ReplyTarget(peer), StateMsg(), "ALERT")

  elseif msg.t == "STATE" then
    NoteState(peer, msg, false)

  elseif msg.t == "SUM" then
    -- Someone is comparing with us: which sections differ?
    local diff = {}
    for i = 0, SECTIONS - 1 do
      if tonumber(type(msg.b) == "table" and msg.b[i + 1]) ~= sections[i] then diff[#diff + 1] = i end
    end
    ns.Log("%s is comparing with %s: %d of %d sections differ", peer.name, ns.MyName(), #diff, SECTIONS)
    ns.Send(ns.ReplyTarget(peer), { t = "NEED", r = ns.RealmKey(), bk = diff }, "ALERT")

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
    if not join or join.probe ~= peer or next(join.pieces) then return end
    if join.timer then join.timer:Cancel(); join.timer = nil end
    local bk = type(msg.bk) == "table" and msg.bk or {}
    if #bk == 0 then
      ns.Log("%s's prices already match %s's", ns.MyName(), peer.name)
      FinishJoin(join.verbose, 0, peer.name)
      return
    end
    ns.Log("%s answered: %d of %d sections differ", peer.name, #bk, SECTIONS)
    StartPieces(bk)

  elseif msg.t == "DATA" then
    local e, base = msg.e, tonumber(msg.b) or 0
    if type(e) ~= "table" then return end
    local tkey = peerKey .. "/" .. tostring(msg.x)
    local tr = transfers[tkey]
    if not tr then
      tr = { kind = msg.k or "update", changed = 0, received = 0, brought = {}, theirs = {},
        from = peer.name, started = ns.Now() }
      transfers[tkey] = tr
      if tr.kind ~= "join" then ns.AnnounceState() end -- now "receiving updates"
      if tr.kind == "join" then
        local set = {}
        for _, s in ipairs(type(msg.bk) == "table" and msg.bk or {}) do set[tonumber(s)] = true end
        tr.sections, tr.pc, tr.since = set, msg.pc, tonumber(msg.sn)
        hosting[tkey] = true
        ns.Log("%s is handshaking with %s (%d sections)", peer.name, ns.MyName(),
          type(msg.bk) == "table" and #msg.bk or 0)
        ns.AnnounceState()
      end
    end
    -- a reply for one of our pieces: the host's merged values are taken as they are
    local piece = tr.kind == "reply" and join and join.pieces[tonumber(msg.pc) or -1]
    if piece and piece.host ~= peer then piece = nil end -- a late answer from a host we moved away from
    local force = piece and true or false
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
    tr.tot = tonumber(msg.tot) or tr.tot
    if piece then
      piece.received, piece.tot = tr.received, tonumber(msg.tot) or piece.tot
      piece.lastProgress = ns.Now()
      UpdateProgress()
    elseif tr.kind ~= "join" then
      ns.AnnounceState() -- receive progress
    end
    local tot = tonumber(msg.tot)
    if tot and tot > BATCH then
      ns.Log("%s <- %s: %s / %s (%s, %d%%)", ns.MyName(), peer.name, ns.Num(tr.received),
        ns.Plural(tot, "price"), KIND_WORDS[tr.kind] or "scan prices", floor(tr.received / tot * 100))
    end
    if tr.timer then tr.timer:Cancel() end
    if not msg.fin then
      tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
        transfers[tkey] = nil
        DoneHosting(tkey)
        ns.Log("prices from %s stopped arriving partway (%s kept)", peer.name, ns.Plural(tr.changed, "change"))
      end)
      return
    end
    transfers[tkey] = nil

    if tr.kind == "join" then
      -- Hosting a piece: merge done. Send back what differs, share what they brought.
      ns.Log("%s received %s from %s; %s newer than %s's", ns.MyName(), ns.Plural(tr.received, "price"),
        peer.name, ns.Num(tr.changed), ns.MyName())
      if tr.changed > 0 then
        ns.Log("new master list generated: %s, fingerprint %s", ns.Plural(itemCount, "price"), ns.Fingerprint())
      end
      local reply = {}
      for _, it in ipairs(ItemsIn(tr.sections)) do
        local theirs = tr.theirs[it[1]]
        -- not sent by them: they still have what they had at their last sync, so only prices
        -- seen since then can be news (all of them, for a full handshake)
        if (theirs ~= nil and theirs ~= it[2]) or (theirs == nil and (not tr.since or it[4] > tr.since)) then
          reply[#reply + 1] = it
        end
      end
      ns.Log("%s sends %s the master list for those sections: %s", ns.MyName(), peer.name, ns.Plural(#reply, "price"))
      replies[peerKey .. "#" .. tostring(tr.pc)] = ns.SendEntries(ns.ReplyTarget(peer), reply, "BULK", "reply", { pc = tr.pc, tot = #reply })
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
      DoneHosting(tkey)
      MarkSynced()
      Report(tr.changed)
      ns.AnnounceState()

    elseif tr.kind == "reply" then
      if piece then
        piece.done = true
        if piece.timer then piece.timer:Cancel() end
        join.changed = join.changed + tr.changed
        ns.Log("%s received %s from %s (%d sections), %s changed", ns.MyName(), ns.Plural(tr.received, "price"),
          peer.name, #piece.list, ns.Num(tr.changed))
        UpdateProgress()
        local all, names = true, {}
        for _, p in pairs(join.pieces) do
          if not p.done then all = false end
          names[p.host.name] = true
        end
        if all then
          local list = {}
          for n in pairs(names) do list[#list + 1] = n end
          table.sort(list)
          FinishJoin(join.verbose, join.changed, table.concat(list, ", "))
        end
      else
        MarkSynced()
        Report(tr.changed)
      end

    elseif tr.kind == "fwd" then
      ns.Log("%s shared a newcomer's prices: %s, %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
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

-- Watchdog: every few seconds, drop any handshake piece whose prices stopped moving.
C_Timer.NewTicker(5, function()
  if not join then return end
  local now = ns.Now()
  for _, piece in pairs(join.pieces) do
    if not piece.done and piece.lastProgress and now - piece.lastProgress > STALL_TIMEOUT then
      KickPiece(piece, string.format("no progress for %ds", STALL_TIMEOUT))
      if not join then return end
    end
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
  -- Safety net (and how two versions of the list get merged): out of step with the master list
  -- for HEAL_AFTER seconds -> handshake with a free player who has it. The handshake also brings
  -- this side's different prices into the master list, so nothing is lost.
  local master = ns.Master()
  if ns.state == "ready" and not join and master and master ~= ns.Fingerprint()
    and not ns.IsScanning() and not next(pending) and ns.Receiving() == 0 then
    mismatchSince = mismatchSince or ns.Now()
    if ns.Now() - mismatchSince >= HEAL_AFTER then
      mismatchSince = nil
      local hosts = Hosts(master)
      if hosts[1] then
        ns.Log("%s's prices have differed from the master list for %ds: re-syncing with %s",
          ns.MyName(), HEAL_AFTER, hosts[1].name)
        StartHandshake(false, hosts[1], true) -- full: the quick one wasn't enough
      end
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
