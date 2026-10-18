-- AuctionatorSync: shares Auctionator's price database between friends.
-- It never changes Auctionator's code: it watches Auctionator.Database:SetPrice from the
-- outside (hooksecurefunc) and writes friends' prices into the same price table a scan fills.
local addonName, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = (GetMeta and GetMeta(addonName, "Version")) or "?"
ns.PREFIX = "AucSync"
ns.PROTOCOL = 1

-- Account-wide: the Auctionator price database these settings act on is account-wide too.
local DEFAULTS = {
  guild = true,          -- sync with guild members
  friends = true,        -- sync with the in-game friends list
  bnet = true,           -- sync with Battle.net friends playing on this realm
  shareScans = true,     -- send my new scan results straight away
  catchUpOnLogin = true, -- ask for prices I missed when I log in
  announce = true,       -- chat line when prices arrive
  maxAgeDays = 7,        -- catch-ups only carry prices seen in the last N days
}

function ns.Print(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAuctionatorSync|r: " .. text)
end

function ns.Debug(fmt, ...)
  if ns.db and ns.db.debug then ns.Print("|cff888888" .. fmt .. "|r", ...) end
end

function ns.Now()
  return GetServerTime and GetServerTime() or time()
end

-- Short, lower-case character name for comparing senders ("Bob-Realm" and "Bob" match).
function ns.ShortName(name)
  if not name then return nil end
  name = Ambiguate and Ambiguate(name, "none") or name
  return (name:gsub("%-.*$", "")):lower()
end

ns.playerName = UnitName("player")

local events = CreateFrame("Frame")
ns.events = events
local handlers = {}

-- Forever throws on unknown events, so check each one first.
function ns.On(event, fn)
  if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
    ns.Debug("event %s not available on this client", event)
    return
  end
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], fn)
  events:RegisterEvent(event)
end

events:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.Print("|cffff5555error in %s:|r %s", event, tostring(err)) end
  end
end)

ns.On("ADDON_LOADED", function(name)
  if name ~= addonName then return end
  AuctionatorSyncDB = AuctionatorSyncDB or {}
  local db = AuctionatorSyncDB
  db.settings = db.settings or {}
  for k, v in pairs(DEFAULTS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  db.realms = db.realms or {}
  ns.store = db
  ns.db = db.settings
end)

SLASH_AUCTIONATORSYNC1 = "/async"
SLASH_AUCTIONATORSYNC2 = "/aucsync"
SlashCmdList.AUCTIONATORSYNC = function(msg)
  local cmd = strtrim(msg or ""):lower()
  if cmd == "sync" then
    ns.CatchUp(true)
  elseif cmd == "status" then
    ns.PrintStatus()
  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    ns.Print("debug %s", ns.db.debug and "on" or "off")
  elseif cmd == "" then
    ns.ToggleWindow()
  else
    ns.Print("/async - open the window")
    ns.Print("/async sync - catch up from friends now")
    ns.Print("/async status - who's online with AuctionatorSync")
    ns.Print("/async debug - toggle debug messages")
  end
end
