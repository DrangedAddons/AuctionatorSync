-- Neutral auction houses (Booty Bay, Gadgetzan, Everlook) have their own listings and prices.
-- Auctionator keeps one list per ruleset and can't tell them apart, so a neutral visit would
-- overwrite the faction prices (and AuctionatorSync would share them). Instead:
--   * opening an auction house whose auctioneer has no faction diverts Auctionator's price saves
--     into a neutral list of our own (ns.store.neutral[realm]); Auctionator's list isn't touched
--   * closing it shares the new neutral prices with everyone (NDATA, which older versions ignore)
--   * at login, once synced, one player with a neutral list sends what's new since our last
--     sync (NREQ -> NDATA), and anything we saw while nobody was online goes out
-- Merging is newest-wins, like the main list. The Price List shows it on its Neutral AH tab.
local _, ns = ...

local CATCHUP_MARGIN = 600 -- re-ask for a little before the last sync, like quick handshakes
local CATCHUP_RETRY = 120  -- no one to ask yet: try again this often

ns.atNeutralAH = false

-- { items = { [key] = { p = price, t = seen, a = available } }, synced = ts, shared = ts }
local function List()
  local realm = ns.RealmKey()
  if not realm or not ns.store then return nil end
  ns.store.neutral = ns.store.neutral or {}
  local r = ns.store.neutral[realm]
  if type(r) ~= "table" then
    r = { items = {}, synced = 0, shared = 0 }
    ns.store.neutral[realm] = r
  end
  return r
end

-- For the Price List: { key, price, seen at, available }, the same shape as ns.PriceEntries.
function ns.NeutralEntries()
  local r, out = List(), {}
  if not r then return out end
  for key, it in pairs(r.items) do
    if (it.p or 0) > 0 then out[#out + 1] = { key, it.p, it.t or 0, it.a } end
  end
  return out
end

-- Entries seen after ts, as SendEntries items { key, price, available, seen }.
local function Since(r, ts)
  local list = {}
  for key, it in pairs(r.items) do
    if (it.t or 0) > ts and (it.p or 0) > 0 then list[#list + 1] = { key, it.p, it.a or 0, it.t } end
  end
  return list
end

local function OnlineNeutralPeers()
  local n = 0
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and ns.IsCompatible(peer) and peer.nh then n = n + 1 end
  end
  return n
end

----------------------------------------------------------------------------------------------
-- At a neutral auction house: Auctionator's saves come here.

local diverted -- { db, fn }: Auctionator's database and the SetPrice we swapped out
local seenHere = {} -- keys saved during this visit, to share on close

local function NeutralSetPrice(_, key, price, available)
  -- Auctionator calls this from its scan ticker without a pcall: never let it error.
  local ok, err = pcall(function()
    price = tonumber(price)
    if key == nil or not price or price <= 0 then return end
    local r = List()
    if not r then return end
    key = tostring(key)
    local it = r.items[key]
    local avail = tonumber(available)
    if it and it.t == ns.Now() then avail = math.max(avail or 0, it.a or 0) end -- same scan, more listings
    r.items[key] = { p = price, t = ns.Now(), a = avail }
    seenHere[key] = true
    ns.dataVersion = ns.dataVersion + 1
  end)
  if not ok and not diverted.failed then
    diverted.failed = true
    ns.Log("couldn't record a neutral auction house price: %s", tostring(err))
  end
end

local function Divert(on)
  local db = Auctionator and Auctionator.Database
  if on then
    if diverted or not db then return end
    diverted = { db = db, fn = rawget(db, "SetPrice") }
    db.SetPrice = NeutralSetPrice
  elseif diverted then
    if diverted.db.SetPrice == NeutralSetPrice then diverted.db.SetPrice = diverted.fn end
    diverted = nil
  end
end

-- The goblin auctioneers belong to no faction; faction auctioneers are Alliance or Horde.
local function NeutralAuctioneer()
  for _, unit in ipairs({ "npc", "target" }) do
    if UnitExists(unit) and not UnitIsPlayer(unit) then
      local faction = UnitFactionGroup(unit)
      return faction ~= "Alliance" and faction ~= "Horde"
    end
  end
  return false
end

local function ShareSeen()
  local r = List()
  if not r or not next(seenHere) then return end
  local list = {}
  for key in pairs(seenHere) do
    local it = r.items[key]
    if it then list[#list + 1] = { key, it.p, it.a or 0, it.t } end
  end
  wipe(seenHere)
  if #list == 0 then return end
  if OnlineNeutralPeers() == 0 then
    ns.Log("%s saw %s at the neutral auction house; nobody online to share them with yet",
      ns.MyName(), ns.Plural(#list, "price"))
    return -- r.shared stays put: they go out at the next login catch-up
  end
  ns.Log("%s shares %s from the neutral auction house", ns.MyName(), ns.Plural(#list, "price"))
  ns.SendEntries(nil, list, "NORMAL", "neutral", { t = "NDATA" })
  r.shared = ns.Now()
end

ns.On("AUCTION_HOUSE_SHOW", function()
  if NeutralAuctioneer() then
    ns.atNeutralAH = true
    Divert(true)
    ns.Log("%s opened a neutral auction house: its prices go to the neutral list", ns.MyName())
    if ns.OnNeutralChanged then ns.OnNeutralChanged() end
  end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  if not ns.atNeutralAH then return end
  ns.atNeutralAH = false
  Divert(false)
  ShareSeen()
  if ns.OnNeutralChanged then ns.OnNeutralChanged() end
end)

----------------------------------------------------------------------------------------------
-- Messages (Sync.lua hands NDATA / NREQ here, after its realm and version checks)

local incoming = {} -- "<sender>/<x>" -> { changed, received }

function ns.OnNeutralMessage(msg, peer)
  local r = List()
  if not r then return end
  if msg.t == "NREQ" then
    local since = tonumber(msg.sn) or 0
    local list = Since(r, since)
    ns.SendEntries(ns.ReplyTarget(peer), list, "BULK", "neutral", { t = "NDATA", rp = 1 })
    if #list > 0 then
      ns.Log("%s sends %s %s from the neutral list", ns.MyName(), peer.name, ns.Plural(#list, "price"))
    end
    return
  end

  -- NDATA: { e = key, price, avail, ts - b, ... }, b = base time, fin on the last batch
  local e, base = msg.e, tonumber(msg.b) or 0
  if type(e) ~= "table" then return end
  local tkey = ns.ShortName(peer.name) .. "/" .. tostring(msg.x)
  local tr = incoming[tkey] or { changed = 0, received = 0 }
  incoming[tkey] = tr
  for i = 1, #e - 3, 4 do
    local key, price = tostring(e[i]), tonumber(e[i + 1])
    local avail, ts = tonumber(e[i + 2]), base + (tonumber(e[i + 3]) or 0)
    tr.received = tr.received + 1
    if price and price > 0 then
      local it = r.items[key]
      -- newest wins; seen at the same moment: the lower price
      if not it or ts > (it.t or 0) or (ts == it.t and price < (it.p or math.huge)) then
        r.items[key] = { p = price, t = ts, a = avail }
        tr.changed = tr.changed + 1
      end
    end
  end
  if not msg.fin then return end
  incoming[tkey] = nil
  if tr.changed > 0 then ns.dataVersion = ns.dataVersion + 1 end
  if msg.rp then r.synced = ns.Now() end -- the answer to our catch-up request
  if tr.received > 0 then
    ns.Log("%s sent %s from the neutral auction house: %s changed", peer.name,
      ns.Plural(tr.received, "price"), ns.Num(tr.changed))
  end
end

----------------------------------------------------------------------------------------------
-- Login catch-up: once this character is synced, ask one player with a neutral list for
-- what's new, and send out anything we saw while nobody was online.

local caughtUp = false
local lastTry, askedAt = 0, nil

local function CatchUp()
  local r = List()
  if not r then return end
  -- asked, but no answer came (they logged off, a message was lost): ask again
  if caughtUp and askedAt and (r.synced or 0) < askedAt and ns.Now() - askedAt > CATCHUP_RETRY then
    caughtUp, askedAt = false, nil
  end
  if caughtUp or ns.state ~= "ready" or ns.Now() - lastTry < CATCHUP_RETRY then return end
  local best
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and ns.IsCompatible(peer) and peer.nh and peer.st == "ready" then
      if not best or (peer.hl or 0) < (best.hl or 0) then best = peer end
    end
  end
  lastTry = ns.Now()
  if not best then return end
  caughtUp, askedAt = true, ns.Now()
  ns.Send(ns.ReplyTarget(best), { t = "NREQ", r = ns.RealmKey(), sn = math.max(0, (r.synced or 0) - CATCHUP_MARGIN) },
    "NORMAL")
  local mine = Since(r, r.shared or 0)
  if #mine > 0 then
    ns.Log("%s shares %s from the neutral auction house seen while nobody was online",
      ns.MyName(), ns.Plural(#mine, "price"))
    ns.SendEntries(nil, mine, "NORMAL", "neutral", { t = "NDATA" })
    r.shared = ns.Now()
  end
end

C_Timer.NewTicker(10, function()
  local ok, err = pcall(CatchUp)
  if not ok then ns.Log("neutral list catch-up failed: %s", tostring(err)) end
end)
