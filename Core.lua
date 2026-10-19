-- AuctionatorSync: shares Auctionator's price database between friends.
-- It never changes Auctionator's code: it watches Auctionator.Database:SetPrice from the
-- outside (hooksecurefunc) and writes friends' prices into the same price table a scan fills.
local addonName, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = (GetMeta and GetMeta(addonName, "Version")) or "?"
ns.PREFIX = "AucSync"
ns.PROTOCOL = 2

-- Account-wide: the Auctionator price database these settings act on is account-wide too.
local DEFAULTS = {
  guild = true,          -- sync with guild members
  friends = true,        -- sync with the in-game friends list
  bnet = true,           -- sync with Battle.net friends playing on this realm
  shareScans = true,     -- send my changed prices on the share timer
  catchUpOnLogin = true, -- sync with whoever's online when I log in (the host compare)
  announce = true,       -- automatic chat messages (sign-in, sync results)
  maxAgeDays = 7,        -- syncs only carry prices seen in the last N days
  verbose = false,       -- verbose mode: record every step in the log window
}

local LOG_MAX = 500

-- Always shown: answers to something the player did, and errors.
function ns.Print(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAuctionatorSync|r: " .. text)
end

-- Automatic messages: only while "Show chat messages" is ticked.
function ns.Notice(fmt, ...)
  if ns.db and ns.db.announce then ns.Print(fmt, ...) end
end

function ns.Num(n)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

function ns.Plural(n, word)
  return ns.Num(n) .. " " .. word .. (n == 1 and "" or "s")
end

-- "Bob", "Bob and Alice", "Bob, Alice and Cat", "Bob, Alice and 3 others"
function ns.NameList(names)
  local n = #names
  if n <= 1 then return names[1] or "" end
  if n == 2 then return names[1] .. " and " .. names[2] end
  if n == 3 then return names[1] .. ", " .. names[2] .. " and " .. names[3] end
  return names[1] .. ", " .. names[2] .. " and " .. (n - 2) .. " others"
end

-- Verbose mode: every step goes into the log (last LOG_MAX lines, kept across /reload) and
-- the log window, never chat.
function ns.Log(fmt, ...)
  if not (ns.db and ns.db.verbose and ns.store) then return end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = fmt end
  local line = "|cff888888" .. date("%H:%M:%S") .. "|r  " .. text
  local log = ns.store.log
  log[#log + 1] = line
  if #log > LOG_MAX then table.remove(log, 1) end
  if ns.OnLogLine then ns.OnLogLine(line) end
end
ns.Debug = ns.Log

function ns.Now()
  return GetServerTime and GetServerTime() or time()
end

-- Short, lower-case character name for comparing senders ("Bob-Realm" and "Bob" match).
function ns.ShortName(name)
  if not name then return nil end
  name = Ambiguate and Ambiguate(name, "none") or name
  return (name:gsub("%-.*$", "")):lower()
end

-- Random per-login ID stamped on every message, so our own messages (guild echo, a second
-- copy of ourselves) are always recognised and dropped, whatever the name looks like.
ns.SESSION = string.format("%x%04x", time(), math.random(0, 0xffff))

-- Looked up each time: at load the player's name may not be known yet.
function ns.IsMe(name)
  local me = UnitName("player")
  return name ~= nil and me ~= nil and ns.ShortName(name) == ns.ShortName(me)
end

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
  db.log = db.log or {}
  db.settings.debug = nil -- replaced by verbose mode
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
  elseif cmd == "log" or cmd == "debug" then
    ns.ToggleLog()
  elseif cmd == "" then
    ns.ToggleWindow()
  else
    ns.Print("|cffffd100/async|r window · |cffffd100/async sync|r sync now · "
      .. "|cffffd100/async status|r what's synced · |cffffd100/async log|r verbose log")
  end
end
