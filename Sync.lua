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
--      host; the least busy is picked), then swap prices for the sections that differ, in
--      pieces of PIECE_SECTIONS: each host works one piece at a time, merges it and passes
--      what's new to everyone. A host that goes silent (not slow: silent) has its piece moved.
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
local JOIN_TIMEOUT = 180    -- an incoming transfer with no chunk from its sender this long is dropped
local HEARTBEAT = 60        -- seconds between STATE heartbeats
local HEAL_AFTER = 120      -- seconds out of sync with the host before re-syncing
local SINCE_MARGIN = 600    -- a quick handshake re-sends prices from a little before the last sync
local COMPARE_TIMEOUT = 45  -- after our sums have gone out: no answer (and nothing arriving) by then, try another host
local STALL_TIMEOUT = 120   -- a handshake piece with not one chunk moving either way for this long is moved
local BENCH_MIN = 120       -- a host that went silent sits out this long, doubling each time it happens
local BENCH_MAX = 600       -- ...up to this
local PIECE_SECTIONS = 128  -- a handshake goes in pieces this size (~1,500 prices), each finished on its own
local RETRY_STEPS = { 20, 60, 180, 300 } -- seconds before retrying a failed sync, growing each time
local REBUILD_SLICE = 1500  -- prices per frame when rebuilding the fingerprint (~4 ms: no login freeze)
local WAIT_LIMIT = 60       -- looking for a host longer than this: carry on alone and retry later
local SECTIONS = 4096       -- fine sections: one changed price sends ~22 others along, not ~350
local GROUPS = 256          -- the compare's first step: section s is in group s % GROUPS
local PER_GROUP = SECTIONS / GROUPS
local NARROW_MAX = 32       -- groups differing at most this many: the host adds their section sums
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

-- Auctionator keys: "12345" (item), "g:12345:<item level>" (gear), "gr:12345:<suffix>"
-- (random-suffix gear), "p:..." (battle pet).
function ns.ItemIDFromKey(key)
  key = tostring(key)
  return tonumber(key:match("^(%d+)$") or key:match("^gr?:(%d+)"))
end

-- Random-suffix gear. Auctionator on Forever keys it "gr:<item>:<n>", n an index into
-- Auctionator.Utilities.SuffixLabels (6 = "of the Whale"). Older copies wrote the suffix text,
-- "gr:<item>:of the Whale". Auctionator converted its own list once, but synced prices kept
-- bringing the text keys back, so every suffix item was listed twice.
local function SuffixLabels()
  local u = Auctionator and Auctionator.Utilities
  local labels = u and u.SuffixLabels
  if type(labels) == "table" and labels[1] then return labels end
end

local labelIndex -- suffix text -> its first index, the same pick as Auctionator's conversion
function ns.CanonicalKey(key)
  key = tostring(key)
  local id, text = key:match("^gr:(%d+):(%D.*)$")
  if not id then return key end
  local labels = SuffixLabels()
  if not labels then return key end
  if not labelIndex then
    labelIndex = {}
    for i = #labels, 1, -1 do labelIndex[labels[i]] = i end
  end
  local index = labelIndex[text]
  return index and ("gr:" .. id .. ":" .. index) or key
end

-- The game's item string for a price key. Suffix gear gets the bonus ID behind its suffix (the
-- link shape Auctionator itself uses to name suffixes), so tooltips, Auctionator's price line
-- and chat links are for "of the Whale", not the plain item.
local bonusFor -- suffix index -> bonus ID
function ns.ItemString(key)
  key = tostring(key)
  local id, index = key:match("^gr:(%d+):(%d+)$")
  if not id then
    local plain = ns.ItemIDFromKey(key)
    return plain and ("item:" .. plain) or nil
  end
  local u = Auctionator and Auctionator.Utilities
  if not bonusFor and u and type(u.SuffixBonusIDs) == "table" then
    bonusFor = {}
    for bonus, i in pairs(u.SuffixBonusIDs) do
      if not bonusFor[i] or bonus < bonusFor[i] then bonusFor[i] = bonus end
    end
  end
  local bonus = bonusFor and bonusFor[tonumber(index)]
  if not bonus then return "item:" .. id end
  return "item:" .. id .. string.rep(":", 12) .. "1:" .. bonus
end

-- The suffix a key names ("of the Whale"), or nil for anything that isn't suffix gear.
function ns.SuffixName(key)
  local suffix = tostring(key):match("^gr:%d+:(.+)$")
  if not suffix then return nil end
  local index = tonumber(suffix)
  if not index then return suffix end
  local labels = SuffixLabels()
  return labels and labels[index] or nil
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
-- Fingerprint: 4096 sections, each the sum (mod 2^32) of hash(item, price) for its items.
-- The compare sends 256 group sums (16 sections each) first; see SUM / NEED.

-- sectionKeys[s] = { [text key] = Auctionator's key }: which prices are in each section, kept as
-- prices change, so sending a few sections never walks the whole list.
local sections, sectionKeys, itemCount = {}, {}, 0
local newestTs = 0 -- when the newest price in this list was seen (shared as nt)
function ns.NewestPrice() return newestTs end
for i = 0, SECTIONS - 1 do
  sections[i] = 0
  sectionKeys[i] = {}
end
local rebuilding     -- the fingerprint rebuild in progress (several frames), or nil
-- A handshake that didn't finish leaves our list part-merged: until one finishes, it isn't a
-- candidate for the master list and we don't host (else two halves could each think they lead).
local incomplete = false
local inRebuild = false -- the rebuild itself is calling Track

local function Hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % TWO32 end
  return h
end

local function SectionOf(key) return Hash(key) % SECTIONS end

ns.dataVersion = 0 -- bumped on every price / seen-time change (the Price List rebuilds on it)

-- orig: the key as Auctionator stores it (key is its text form)
local function Track(key, oldPrice, newPrice, orig)
  if rebuilding and not inRebuild then rebuilding.dirty = true end -- a price moved under the rebuild
  local s = SectionOf(key)
  if oldPrice and oldPrice > 0 then
    sections[s] = (sections[s] - Hash(key .. ":" .. oldPrice)) % TWO32
    itemCount = itemCount - 1
    if not (newPrice and newPrice > 0) then sectionKeys[s][key] = nil end
  end
  if newPrice and newPrice > 0 then
    sections[s] = (sections[s] + Hash(key .. ":" .. newPrice)) % TWO32
    itemCount = itemCount + 1
    sectionKeys[s][key] = orig or key
  end
end

-- The 256 group sums (section s counts toward group s % 256), as sent in SUM.
local function GroupSums()
  local b = {}
  for g = 0, GROUPS - 1 do b[g + 1] = 0 end
  for i = 0, SECTIONS - 1 do
    local g = i % GROUPS + 1
    b[g] = (b[g] + sections[i]) % TWO32
  end
  return b
end

-- The sections of group g: g, g + 256, g + 512, ...
local function GroupSections(g)
  local list = {}
  for k = 0, PER_GROUP - 1 do list[#list + 1] = g + k * GROUPS end
  return list
end

-- A set of sections on the wire: one number per group, group * 65536 + a 16-bit mask of which
-- of its sections are in it. At most 256 numbers, however many sections.
local function PackSections(list)
  local masks = {}
  for _, s in ipairs(list) do
    local g, k = s % GROUPS, floor(s / GROUPS)
    local m = masks[g] or 0
    if floor(m / 2 ^ k) % 2 == 0 then m = m + 2 ^ k end
    masks[g] = m
  end
  local out = {}
  for g, m in pairs(masks) do out[#out + 1] = g * 65536 + m end
  table.sort(out)
  return out
end

local function UnpackSections(packed)
  local set, n = {}, 0
  if type(packed) ~= "table" then return set, n end
  for _, v in ipairs(packed) do
    v = tonumber(v)
    if v then
      local g, m = floor(v / 65536), v % 65536
      if g >= 0 and g < GROUPS then
        for k = 0, PER_GROUP - 1 do
          if floor(m / 2 ^ k) % 2 == 1 then
            set[g + k * GROUPS] = true
            n = n + 1
          end
        end
      end
    end
  end
  return set, n
end

function ns.Fingerprint()
  local total = 0
  for i = 0, SECTIONS - 1 do total = (total + sections[i]) % TWO32 end
  return string.format("%08x-%d", total, itemCount)
end

local function ResetFingerprint()
  for i = 0, SECTIONS - 1 do
    sections[i] = 0
    wipe(sectionKeys[i])
  end
  itemCount = 0
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

-- Day tables (h, l, a): keep from's value for a day where better(from's, ours) says so.
local function MergeDays(into, from, better)
  if type(from) ~= "table" then return end
  for day, v in pairs(from) do
    if into[day] == nil or better(v, into[day]) then into[day] = v end
  end
end

local function Higher(a, b) return a > b end
local function Lower(a, b) return a < b end

-- Fold text suffix keys into the numeric ones: the newer price wins (same time: the lower,
-- as in Apply), and the day history of both is kept. Favorites move with them.
local function FoldSuffixKeys(data, r)
  if not SuffixLabels() then return 0 end
  local moves = {}
  for key in pairs(data) do
    local canon = ns.CanonicalKey(key)
    if canon ~= tostring(key) then moves[key] = canon end
  end
  local folded = 0
  for old, canon in pairs(moves) do
    local from, into = data[old], data[canon]
    if type(from) == "table" and (from.m or 0) > 0 then
      local tFrom = SeenAt(r, tostring(old), from)
      if type(into) ~= "table" or not ((into.m or 0) > 0) then
        data[canon] = from
        r.ts[canon] = r.ts[tostring(old)] or r.ts[canon]
      else
        local tInto = SeenAt(r, canon, into)
        if tFrom > tInto or (tFrom == tInto and from.m < into.m) then into.m = from.m end
        into.h, into.l = into.h or {}, into.l or {}
        MergeDays(into.h, from.h, Higher)
        MergeDays(into.l, from.l, Lower)
        if type(from.a) == "table" then
          into.a = into.a or {}
          MergeDays(into.a, from.a, Higher)
        end
        if r.ts[tostring(old)] or r.ts[canon] then r.ts[canon] = math.max(tFrom, tInto) end
      end
    end
    data[old] = nil
    r.ts[tostring(old)] = nil
    folded = folded + 1
  end
  local favs = ns.db and ns.db.favorites
  if type(favs) == "table" then
    local renamed = {}
    for key in pairs(favs) do
      local canon = ns.CanonicalKey(key)
      if canon ~= key then renamed[key] = canon end
    end
    for key, canon in pairs(renamed) do
      favs[key] = nil
      favs[canon] = true
    end
  end
  return folded
end

-- Rebuilding the fingerprint, the section index and what we know of each price, REBUILD_SLICE
-- prices a frame, so a big list doesn't freeze the game. A price changing meanwhile (or the list
-- gaining a key mid-walk) starts it over; after a few restarts the rest is done in one go.
-- Nothing syncs until it's done (ns.FingerprintReady).
local afterRebuild = {} -- functions to run once it's done

function ns.FingerprintReady() return rebuilding == nil end

local function WhenReady(fn)
  if not rebuilding then fn() else afterRebuild[#afterRebuild + 1] = fn end
end

local function StartRebuild(data, r)
  local job = { restarts = 0 }
  rebuilding = job
  local function Begin()
    ResetFingerprint()
    wipe(known)
    job.dirty = false
    job.co = coroutine.create(function()
      local n = 0
      for key, entry in pairs(data) do
        if type(entry) == "table" then
          known[key] = entry.m
          Track(tostring(key), nil, entry.m, key)
        end
        n = n + 1
        if n % REBUILD_SLICE == 0 then coroutine.yield() end
      end
      local newest = 0
      for _, ts in pairs(r and r.ts or {}) do
        if type(ts) == "number" and ts > newest then newest = ts end
        n = n + 1
        if n % REBUILD_SLICE == 0 then coroutine.yield() end
      end
      newestTs = math.max(newestTs, newest)
    end)
  end
  local function Step()
    if rebuilding ~= job then return end
    local whole = job.restarts >= 3 -- prices keep changing under it: finish now
    repeat
      if job.dirty then
        job.restarts = job.restarts + 1
        Begin()
      end
      inRebuild = true
      local ok = coroutine.resume(job.co)
      inRebuild = false
      if not ok then
        job.dirty = true -- the list changed under the walk: start over
      elseif coroutine.status(job.co) == "dead" and not job.dirty then
        rebuilding = nil
        ns.Detail("watching Auctionator's prices for %s: %s, fingerprint %s (%d restarts)",
          tostring(ns.RealmKey()), ns.Plural(itemCount, "price"), ns.Fingerprint(), job.restarts)
        local fns = afterRebuild
        afterRebuild = {}
        for _, fn in ipairs(fns) do
          local fok, err = pcall(fn)
          if not fok then ns.Log("after loading prices: %s", tostring(err)) end
        end
        ns.AnnounceState()
        return
      end
    until not whole
    C_Timer.After(0, Step)
  end
  Begin()
  C_Timer.After(0, Step)
end

-- Auctionator can rebuild its database object (e.g. when you clear it), so keep checking.
function ns.HookAuctionator()
  local db = DB()
  if not db or db == hookedDB or type(db.SetPrice) ~= "function" then return end
  hookedDB = db
  local r0 = Realm()
  -- old text suffix keys: once per realm (synced prices arrive already converted)
  if type(db.db) == "table" and r0 and SuffixLabels() and not r0.suffixFold then
    local folded = FoldSuffixKeys(db.db, r0)
    r0.suffixFold = 1
    if folded > 0 then
      ns.Log("%s merged %s saved under old suffix names into Auctionator's own", ns.MyName(),
        ns.Plural(folded, "price"))
    end
  end
  if type(db.db) == "table" then StartRebuild(db.db, r0) end
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

-- Every price in the given sections (a set of section numbers): only those sections' prices are
-- touched, however big the list.
local function ItemsIn(set)
  local r, db = Realm(), DB()
  local list = {}
  if not r or not db or type(db.db) ~= "table" then return list end
  local data = db.db
  for s in pairs(set) do
    for key, orig in pairs(sectionKeys[s] or {}) do
      local entry = data[orig]
      if type(entry) == "table" and (entry.m or 0) > 0 then list[#list + 1] = Item(r, key, entry) end
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
local KIND_WORDS = { join = "handshake piece", reply = "handshake reply", fwd = "share-out",
  neutral = "neutral AH prices" }
ns.KIND_WORDS = KIND_WORDS

-- Transfers we're sending right now (for the Sync Monitor): { to, kind, tot, sent, started }
ns.outgoing = {}

-- onDone(out): once the last batch has gone out (not when cancelled).
function ns.SendEntries(target, list, prio, k, extra, onDone)
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
    local function onSent(ok)
      if out.cancelled then return end
      if ok == false then
        -- the game refused a chunk: the receiver can't rebuild this batch, so send it again
        out.retries = (out.retries or 0) + 1
        if out.retries <= 3 then
          C_Timer.After(2 * out.retries, function() SendBatch(i) end)
          return
        end
        ns.Log("%s: a batch to %s kept failing; skipped (the next compare picks those prices up)", label, out.to)
      end
      out.retries = 0
      out.sent = math.max(out.sent, last)
      if batches > 1 and n > 0 then
        ns.Detail("%s: sent %s / %s (%s, %d%%)", label, ns.Num(last), ns.Plural(n, "price"), what, floor(last / n * 100))
      end
      if out.sent >= n then ns.outgoing[out] = nil end
      if ns.OnSendProgress then ns.OnSendProgress() end
      ns.AnnounceState(true)
      if last < n then
        SendBatch(last + 1)
      elseif onDone then
        out.done = true
        onDone(out)
      end
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
  if ns.OnPeerLost then ns.OnPeerLost(key, why) end
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
  -- while the fingerprint is still being rebuilt it isn't ours yet: nobody should pick us as a host
  local st = ((rebuilding or incomplete) and ns.state == "ready") and "waiting" or ns.state
  return { t = t or "STATE", r = ns.RealmKey(), st = st, d = ns.Fingerprint(), os = ns.onlineSince,
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
local PROGRESS_EVERY = 30
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
  if ns.state == "ready" and not rebuilding and not incomplete then Vote(ns.Fingerprint(), newestTs) end
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
-- random, so newcomers spread out instead of queueing behind one player.
-- exclude = a set of peers to leave out.
-- Hosts that went silent or didn't answer sit out a while (Bench): not picked for any handshake.
local benched = {}    -- peerKey -> until (server time)
local benchCount = {} -- peerKey -> times benched since they last finished a piece for us

local function IsBenched(peer)
  local untilTs = benched[ns.ShortName(peer.name)]
  return untilTs ~= nil and untilTs > ns.Now()
end

local function Bench(peer, why)
  local key = ns.ShortName(peer.name)
  benchCount[key] = (benchCount[key] or 0) + 1
  local secs = math.min(BENCH_MIN * 2 ^ (benchCount[key] - 1), BENCH_MAX)
  benched[key] = ns.Now() + secs
  ns.Log("%s sits out as a host for %s (%s)", peer.name,
    secs >= 60 and string.format("%d min", floor(secs / 60)) or string.format("%ds", secs), why)
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

local SECTIONS_PER_HOST = 256 -- one more host per this many differing sections
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
    if not piece.done then
      list[#list + 1] = { host = piece.host.name, sections = #piece.list, done = piece.done,
        got = piece.received or 0, tot = piece.tot }
    end
  end
  return list
end

function ns.IsCompatible(peer) return Compatible(peer) end

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
  if not join.total then
    ns.syncProgress = 1
    ns.syncPhase = "comparing - waiting for " .. (join.probe and join.probe.name or "the host")
    ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
    ns.AnnounceState()
    return
  end
  -- by sections: finished pieces count whole, the ones under way by how far they've got
  local upDone, upTot, inDone, inTot = 0, 0, 0, 0
  local sectionsDone = 0
  for _, piece in pairs(join.pieces) do
    local ut = piece.up and piece.up.tot or 0
    local ud = piece.up and piece.up.sent or 0
    local rt = piece.tot or math.max(ut, 1)
    local rd = piece.done and rt or math.min(piece.received or 0, rt)
    if piece.done then
      sectionsDone = sectionsDone + #piece.list
    else
      upDone, upTot, inDone, inTot = upDone + ud, upTot + ut, inDone + rd, inTot + rt
      local moved = (ut + rt) > 0 and (ud + rd) / (ut + rt) or 0
      sectionsDone = sectionsDone + #piece.list * moved
    end
  end
  ns.syncProgress = math.min(99, math.max(1, floor(sectionsDone / math.max(join.total, 1) * 100)))
  if upDone < upTot then
    ns.syncStep, ns.syncDone, ns.syncTotal = "sending", upDone, upTot
  else
    ns.syncStep, ns.syncDone, ns.syncTotal = "receiving", inDone, inTot
  end
  ns.syncPhase = string.format("%s %s / %s", ns.syncStep, ns.Num(ns.syncDone), ns.Num(ns.syncTotal))
  ns.syncingWith = HostNames()
  ns.AnnounceState(true)
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

local retryStep = 0 -- failed syncs in a row (sets how long RetrySoon waits)

local function FinishJoin(verbose, changed, via)
  local r = Realm()
  if via then retryStep, incomplete = 0, false end
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
    ns.Log("%s is in sync (via %s)", ns.MyName(), via)
  end
  if changed and changed > 0 then
    Say(verbose, "Synced: updated %s.", ns.Plural(changed, "price"))
  elseif via then
    Say(verbose, "Up to date.")
  end
end

local RetrySoon -- forward declaration (needs StartHandshake)

local function GiveUp(why)
  local verbose = join and join.verbose
  incomplete = true
  ns.Log("%s couldn't finish syncing (%s); what arrived is kept, trying again shortly", ns.MyName(),
    why or "no in-sync host left")
  Say(verbose, "Couldn't finish syncing; it'll try again shortly.")
  FinishJoin(verbose, join and join.changed, nil)
  RetrySoon()
end

local SendPiece -- forward declaration (pieces re-send themselves on reassignment)
local NextPiece -- forward declaration (a free host takes the next queued piece)
local CompareTimedOut -- forward declaration (StartHandshake arms it, the watchdog backs it up)

-- Drop a piece whose host went silent (or offline): tell it to stop, stop our upload, let it
-- sit out a while, and put the piece back at the front of the queue for another host. Pieces
-- already finished stay merged. No host left: end cleanly, keep what arrived, retry later.
local function KickPiece(piece, why, bench)
  local old = piece.host
  if piece.up then piece.up.cancelled = true end
  if piece.timer then piece.timer:Cancel() end
  ns.Send(ns.ReplyTarget(old), { t = "CANCEL", r = ns.RealmKey(), pc = piece.id }, "ALERT")
  if bench ~= false then Bench(old, why) end
  join.bad[old] = true
  join.pieces[piece.id] = nil
  table.insert(join.queue, 1, piece.list)
  local hosts = Hosts(ns.Master(), join.bad)
  ns.Log("%s stopped using %s (%s)%s", ns.MyName(), old.name, why,
    hosts[1] and string.format("; %d sections go to %s", #piece.list, hosts[1].name) or "")
  -- any host already busy with us keeps going; a new one takes over the dropped piece
  local busy = {}
  for _, p in pairs(join.pieces) do if not p.done then busy[p.host] = true end end
  for _, h in ipairs(hosts) do
    if not busy[h] then
      NextPiece(h)
      return
    end
  end
  if not next(busy) then GiveUp(string.format("%s %s", old.name, why)) end
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
  ns.Detail("%s sends %s %s from %d sections to merge%s", ns.MyName(), piece.host.name,
    ns.Plural(#items, "price"), #piece.list,
    join.since and string.format(" (only those seen since %s; %s in those sections)", date("%H:%M", join.since), ns.Num(all)) or "")
  piece.up = ns.SendEntries(ns.ReplyTarget(piece.host), items, "BULK", "join",
    { bs = PackSections(piece.list), pc = piece.id, sn = join.since })
  piece.started, piece.lastProgress = ns.Now(), ns.Now()
  UpdateProgress()
end

-- A host is free: give it the next queued piece. Nothing left and nothing under way: done.
NextPiece = function(host)
  if not join then return end
  local list = table.remove(join.queue, 1)
  if not list then
    for _, p in pairs(join.pieces) do
      if not p.done then return end -- others still under way
    end
    local names = {}
    for _, p in pairs(join.pieces) do names[p.host.name] = true end
    local via = {}
    for n in pairs(names) do via[#via + 1] = n end
    table.sort(via)
    FinishJoin(join.verbose, join.changed, table.concat(via, ", "))
    return
  end
  local set = {}
  for _, sec in ipairs(list) do set[sec] = true end
  join.nextId = join.nextId + 1
  local piece = { id = join.nextId, host = host, list = list, set = set, received = 0 }
  join.pieces[piece.id] = piece
  SendPiece(piece)
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

-- The differing sections go in a queue of PIECE_SECTIONS-sized pieces. Each host works on one
-- piece at a time and takes the next when it's done, so a slow host simply does fewer, and a
-- failure only ever loses the piece under way.
local function StartPieces(bk)
  join.queue, join.total = {}, #bk
  for i = 1, #bk, PIECE_SECTIONS do
    local list = {}
    for j = i, math.min(i + PIECE_SECTIONS - 1, #bk) do
      local s = tonumber(bk[j])
      if s then list[#list + 1] = s end
    end
    if #list > 0 then join.queue[#join.queue + 1] = list end
  end
  local candidates = Hosts(ns.Master(), join.bad)
  local want = math.min(HostCount(#bk, candidates), #join.queue)
  local hosts = { join.probe }
  for _, h in ipairs(candidates) do
    if h ~= join.probe and #hosts < want then hosts[#hosts + 1] = h end
  end
  local names = {}
  for _, h in ipairs(hosts) do names[#names + 1] = h.name end
  ns.Detail("%d of %d sections differ: %d pieces, from %s", #bk, SECTIONS, #join.queue, table.concat(names, ", "))
  for _, h in ipairs(hosts) do NextPiece(h) end
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
  join = { verbose = verbose, probe = probe, pieces = {}, queue = {}, bad = {}, changed = 0, nextId = 0,
    target = ns.Master(), since = since, full = full, started = ns.Now() }
  SetState("syncing", probe.name)
  ns.syncProgress = 0
  ns.Log("%s is syncing with %s%s", ns.MyName(), probe.name, since and "" or " (full)")
  local b = GroupSums()
  ns.syncPhase = "comparing - waiting for " .. probe.name
  ns.syncStep, ns.syncDone, ns.syncTotal = "comparing", nil, nil
  local mine = join
  -- the answer is timed from when our sums have actually gone out (the throttle can hold them)
  ns.Send(ns.ReplyTarget(probe), { t = "SUM", r = ns.RealmKey(), b = b }, "ALERT", nil, function()
    if join ~= mine then return end
    mine.sumsSent = ns.Now()
    ns.Detail("%s sent its section sums to %s; waiting for the comparison", ns.MyName(), probe.name)
  end)
  UpdateProgress()
end

-- Waiting for the compare's answer: given up on once our sums have been out COMPARE_TIMEOUT
-- with nothing at all arriving from them (an answer still coming in chunks counts), or after
-- 3 minutes whatever happens. Checked by the watchdog.
local function CompareStalled(mine, now)
  if mine.total then return false end
  if now - mine.started > 180 then return true end
  if not mine.sumsSent then return false end
  local heard = math.max(mine.sumsSent, ns.HeardFrom(mine.probe, true))
  return now - heard > COMPARE_TIMEOUT
end

-- The probe never answered our section sums: bench it and compare with another host.
CompareTimedOut = function(mine)
  if join ~= mine or mine.total then return end
  local probe = mine.probe
  if mine.timer then mine.timer:Cancel(); mine.timer = nil end
  mine.bad[probe] = true
  Bench(probe, "no answer to the compare")
  local hosts = Hosts(ns.Master(), mine.bad)
  if hosts[1] then
    ns.Log("%s didn't answer; comparing with %s instead", probe.name, hosts[1].name)
    local bad = mine.bad
    StartHandshake(mine.verbose, hosts[1], mine.full)
    join.bad = bad
  else
    GiveUp()
  end
end

-- After a failed attempt: try again with whichever host is free (ones that went silent sit
-- out), waiting longer each time it fails in a row (20s, 1, 3, 5 min). Nobody left to try:
-- stay ready on our own list; the safety net catches up later.
local retryPending = false
RetrySoon = function()
  if retryPending then return end
  retryPending = true
  retryStep = retryStep + 1
  local wait = RETRY_STEPS[math.min(retryStep, #RETRY_STEPS)]
  C_Timer.After(wait, function()
    retryPending = false
    if join or ns.state ~= "ready" then return end
    if ns.IsScanning() or rebuilding then RetrySoon() return end
    local master = ns.Master()
    if not incomplete and (not master or master == ns.Fingerprint()) then return end
    local hosts = master and Hosts(master) or {}
    if hosts[1] then
      ns.Log("%s retries syncing with %s", ns.MyName(), hosts[1].name)
      StartHandshake(false, hosts[1])
    else
      RetrySoon() -- nobody free yet (or everyone sitting out): keep trying, less often
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
  if rebuilding then
    -- still reading Auctionator's list: sync the moment it's done
    if not rebuilding.catchUp then
      rebuilding.catchUp = true
      WhenReady(function() ns.CatchUp(verbose) end)
    end
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
        ns.Log("%s starts the master list (%s)", ns.MyName(), ns.Plural(itemCount, "price"))
        Say(verbose, #answered > 0 and "Up to date." or "No one online with AuctionatorSync yet. These prices join the next sync.")
      end
      local rr = Realm()
      if rr then rr.lastCatchUp = ns.Now() end
      SetState("ready")
    elseif first.st == "ready" or ns.Now() - (ns.stateSince or ns.Now()) >= WAIT_LIMIT then
      -- they're ready but benched (or never got ready): don't wait on them forever
      ns.Log("%s found no free host to sync with; carrying on and retrying shortly", ns.MyName())
      SetState("ready")
      RetrySoon()
    else
      ns.Detail("%s is starting the master list; handshaking with them when they're ready", first.name)
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

-- A host we're pulling a piece from reloaded or went offline: move that piece now.
ns.OnPeerLost = function(key, why)
  if not join then return end
  for _, piece in pairs(join.pieces) do
    if not piece.done and ns.ShortName(piece.host.name) == key then
      KickPiece(piece, why, false)
      if not join then return end
    end
  end
  if join and not join.total and ns.ShortName(join.probe.name) == key then CompareTimedOut(join) end
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
    -- too old: nothing of theirs is used (older than 1.4.0 mixes neutral AH prices in). Only the
    -- log and the online list's "needs update" say so; their own copy tells them (CheckOwnVersion).
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
    if rebuilding then return end -- our sums aren't whole yet; they'll try another host
    -- Someone is comparing with us: which groups of sections differ? With only a few, add our
    -- sums for each of their 16 sections so they can tell exactly which (no extra round trip,
    -- and the answer stays a few messages long).
    local mine, diff = GroupSums(), {}
    for g = 0, GROUPS - 1 do
      if tonumber(type(msg.b) == "table" and msg.b[g + 1]) ~= mine[g + 1] then diff[#diff + 1] = g end
    end
    local need = { t = "NEED", r = ns.RealmKey(), bk = diff }
    if #diff > 0 and #diff <= NARROW_MAX then
      local ss = {}
      for _, g in ipairs(diff) do
        for _, sec in ipairs(GroupSections(g)) do ss[#ss + 1] = sections[sec] end
      end
      need.ss = ss
    end
    ns.Detail("%s is comparing with %s: %d of %d groups differ", peer.name, ns.MyName(), #diff, GROUPS)
    ns.Send(ns.ReplyTarget(peer), need, "ALERT")

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
    if not join or join.probe ~= peer or join.total then return end
    if join.timer then join.timer:Cancel(); join.timer = nil end
    local bk = type(msg.bk) == "table" and msg.bk or {}
    if #bk == 0 then
      ns.Detail("%s's prices already match %s's", ns.MyName(), peer.name)
      FinishJoin(join.verbose, 0, peer.name)
      return
    end
    -- the differing sections: exactly, where they sent their section sums, else whole groups
    local ss = type(msg.ss) == "table" and #msg.ss == #bk * PER_GROUP and msg.ss or nil
    local list = {}
    for i, g in ipairs(bk) do
      g = tonumber(g)
      if g and g >= 0 and g < GROUPS then
        for k, sec in ipairs(GroupSections(g)) do
          if not ss or tonumber(ss[(i - 1) * PER_GROUP + k]) ~= sections[sec] then list[#list + 1] = sec end
        end
      end
    end
    ns.Detail("%s answered: %d of %d groups differ, %d of %d sections", peer.name, #bk, GROUPS, #list, SECTIONS)
    if #list == 0 then
      FinishJoin(join.verbose, 0, peer.name)
      return
    end
    StartPieces(list)

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
        local set, n = UnpackSections(msg.bs)
        tr.sections, tr.pc, tr.since = set, msg.pc, tonumber(msg.sn)
        hosting[tkey] = true
        ns.Detail("%s is handshaking with %s (%d sections)", peer.name, ns.MyName(), n)
        ns.AnnounceState()
      end
    end
    -- a reply for one of our pieces: the host's merged values are taken as they are
    local piece = tr.kind == "reply" and join and join.pieces[tonumber(msg.pc) or -1]
    if piece and piece.host ~= peer then piece = nil end -- a late answer from a host we moved away from
    local force = piece and true or false
    for i = 1, #e - 3, 4 do
      -- a 1.5.1 copy can still send a text suffix key: store it under Auctionator's own
      local key, price, avail = ns.CanonicalKey(e[i]), tonumber(e[i + 1]), tonumber(e[i + 2])
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
      ns.AnnounceState(true) -- receive progress
    end
    local tot = tonumber(msg.tot)
    if tot and tot > BATCH then
      ns.Detail("%s <- %s: %s / %s (%s, %d%%)", ns.MyName(), peer.name, ns.Num(tr.received),
        ns.Plural(tot, "price"), KIND_WORDS[tr.kind] or "scan prices", floor(tr.received / tot * 100))
    end
    if tr.timer then tr.timer:Cancel() end
    if not msg.fin then
      -- dropped only if not one chunk from them arrives for JOIN_TIMEOUT (a slow transfer is fine)
      local function Check()
        if transfers[tkey] ~= tr then return end
        local quiet = ns.Now() - math.max(tr.lastBatch or 0, ns.HeardFrom(peer))
        if quiet < JOIN_TIMEOUT then
          tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT - quiet + 1, Check)
          return
        end
        transfers[tkey] = nil
        DoneHosting(tkey)
        ns.Log("prices from %s stopped arriving partway (%s kept)", peer.name, ns.Plural(tr.changed, "change"))
      end
      tr.lastBatch = ns.Now()
      tr.timer = C_Timer.NewTimer(JOIN_TIMEOUT, Check)
      return
    end
    transfers[tkey] = nil

    if tr.kind == "join" then
      -- Hosting a piece: merge done. Send back what differs, share what they brought.
      ns.Detail("%s received %s from %s; %s newer than %s's", ns.MyName(), ns.Plural(tr.received, "price"),
        peer.name, ns.Num(tr.changed), ns.MyName())
      if tr.changed > 0 then
        ns.Detail("new master list generated: %s, fingerprint %s", ns.Plural(itemCount, "price"), ns.Fingerprint())
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
      ns.Detail("%s sends %s the master list for those sections: %s", ns.MyName(), peer.name, ns.Plural(#reply, "price"))
      -- The reply goes first (they're waiting on it); what they brought is shared with everyone
      -- else once it's out, at the lowest priority.
      local brought = tr.brought
      replies[peerKey .. "#" .. tostring(tr.pc)] = ns.SendEntries(ns.ReplyTarget(peer), reply, "NORMAL", "reply",
        { pc = tr.pc, tot = #reply }, function()
          if #brought == 0 then return end
          local others = 0
          for short, p in pairs(ns.peers) do
            if short ~= peerKey and ns.IsPeerOnline(p) and Compatible(p) then others = others + 1 end
          end
          if others > 0 then
            ns.Detail("master list ready: sharing the %s from %s with %s", ns.Plural(#brought, "new price"),
              peer.name, ns.Plural(others, "other player"))
            ns.SendEntries(nil, brought, "BULK", "fwd")
          end
        end)
      DoneHosting(tkey)
      MarkSynced()
      Report(tr.changed)
      ns.AnnounceState()

    elseif tr.kind == "reply" then
      if piece then
        piece.done = true
        if piece.timer then piece.timer:Cancel() end
        join.changed = join.changed + tr.changed
        benchCount[peerKey] = nil -- they came through
        ns.Detail("%s received %s from %s (%d sections), %s changed", ns.MyName(), ns.Plural(tr.received, "price"),
          peer.name, #piece.list, ns.Num(tr.changed))
        UpdateProgress()
        NextPiece(peer)
      else
        MarkSynced()
        Report(tr.changed)
      end

    elseif tr.kind == "fwd" then
      ns.Detail("%s shared a newcomer's prices: %s, %s changed", peer.name, ns.Plural(tr.received, "price"), ns.Num(tr.changed))
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

-- Watchdog: every few seconds, drop any handshake piece whose prices stopped moving, and make
-- sure "waiting" and "handshaking" always end, even if a timer or message handler failed.
local function Watchdog()
  local now = ns.Now()
  if not join then
    if ns.state == "syncing" then
      ns.Log("%s's handshake ended without finishing; retrying shortly", ns.MyName())
      SetState("ready")
      RetrySoon()
    elseif ns.state == "waiting" and now - (ns.stateSince or now) >= WAIT_LIMIT + HELLO_WAIT * 2 then
      ns.Log("%s found no host to sync with in %ds; carrying on and retrying shortly", ns.MyName(), WAIT_LIMIT)
      SetState("ready")
      RetrySoon()
    end
    return
  end
  if not join.total then
    if CompareStalled(join, now) then CompareTimedOut(join) end
    return
  end
  -- A piece is only moved when not one chunk has crossed between us and its host, either way,
  -- for STALL_TIMEOUT. Slow is fine; silent isn't.
  local busy = false
  for _, piece in pairs(join.pieces) do
    if not piece.done then
      busy = true
      local h = piece.host
      local last = math.max(piece.lastProgress or 0, piece.started or 0, ns.HeardFrom(h, true), ns.SentTo(h))
      if not ns.IsPeerOnline(h) then
        KickPiece(piece, "went offline", false)
      elseif now - last > STALL_TIMEOUT then
        KickPiece(piece, string.format("nothing from them for %d min", floor(STALL_TIMEOUT / 60)))
      end
      if not join then return end
    end
  end
  -- nothing under way and the queue still holds pieces (a host was lost between pieces)
  if not busy then
    if #join.queue > 0 then
      local hosts = Hosts(ns.Master(), join.bad)
      if hosts[1] then NextPiece(hosts[1]) else GiveUp() end
    else
      NextPiece(join.probe) -- finishes the handshake
    end
  end
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
  -- Safety net (and how two versions of the list get merged): out of step with the master list
  -- for HEAL_AFTER seconds -> handshake with a free player who has it. The handshake also brings
  -- this side's different prices into the master list, so nothing is lost.
  local master = ns.Master()
  if ns.state == "ready" and not join and not rebuilding and not retryPending and master and master ~= ns.Fingerprint()
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

