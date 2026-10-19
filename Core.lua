-- AuctionatorSync: shares Auctionator's price database between friends.
-- It never changes Auctionator's code: it watches Auctionator.Database:SetPrice from the
-- outside (hooksecurefunc) and writes friends' prices into the same price table a scan fills.
local addonName, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = (GetMeta and GetMeta(addonName, "Version")) or "?"
ns.PREFIX = "AucSync"
ns.PROTOCOL = 3

-- Account-wide: the Auctionator price database these settings act on is account-wide too.
local DEFAULTS = {
  shareScans = true,     -- send my changed prices when a scan finishes / the AH closes
  catchUpOnLogin = true, -- handshake with the host when I log in
  announce = true,       -- automatic chat messages (sign-in, sync results)
  verbose = false,       -- verbose mode: record every step in the log window
  minimap = { hide = false }, -- minimap button (LibDBIcon keeps its position here too)
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

-- This character's name, for the online list and the log (never "you").
function ns.MyName() return UnitName("player") or "?" end

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
  db.names = db.names or {} -- the Price List's name book: [itemID] = { name, quality }
  db.settings.debug = nil -- replaced by verbose mode
  db.settings.guild, db.settings.friends, db.settings.bnet, db.settings.maxAgeDays = nil, nil, nil, nil -- everyone with the addon syncs
  ns.store = db
  ns.db = db.settings
end)

-- Window placement, shared by the /async window, the log and the Price List: a window that opens
-- while others are up docks against the first one it can - its left side, then right, below,
-- above - edge to edge, tops level, fully on screen and overlapping none of them. Docked means
-- attached: it follows that window when you drag it (dragging the docked one itself detaches it).
-- With nothing else open it stays where it was (wherever you dragged it).

-- Is `frame` attached (directly or through others) to `target`? Docking target to it would loop.
local function AttachedTo(frame, target)
  for _ = 1, 6 do
    local _, rel = frame:GetPoint(1)
    if not rel or rel == UIParent then return false end
    if rel == target then return true end
    frame = rel
  end
  return false
end
local WINDOWS = { "AuctionatorSyncFrame", "AuctionatorSyncPriceListFrame", "AuctionatorSyncLogFrame" }

function ns.PlaceWindow(win)
  local others = {}
  for _, name in ipairs(WINDOWS) do
    local f = _G[name]
    if f and f ~= win and f:IsShown() and f:GetLeft() then others[#others + 1] = f end
  end
  if #others == 0 then return end
  local w, h = win:GetWidth(), win:GetHeight()
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  local function Fits(x, top)
    if x < 0 or x + w > sw or top > sh or top - h < 0 then return false end
    for _, o in ipairs(others) do
      if x < o:GetRight() and x + w > o:GetLeft() and top > o:GetBottom() and top - h < o:GetTop() then
        return false
      end
    end
    return true
  end
  for _, o in ipairs(others) do
    if not AttachedTo(o, win) then
      for _, spot in ipairs({
        { o:GetLeft() - w, o:GetTop(), "TOPRIGHT", "TOPLEFT" },     -- left of it
        { o:GetRight(), o:GetTop(), "TOPLEFT", "TOPRIGHT" },        -- right of it
        { o:GetLeft(), o:GetBottom(), "TOPLEFT", "BOTTOMLEFT" },    -- below it
        { o:GetLeft(), o:GetTop() + h, "BOTTOMLEFT", "TOPLEFT" },   -- above it
      }) do
        if Fits(spot[1], spot[2]) then
          win:ClearAllPoints()
          win:SetPoint(spot[3], o, spot[4], 0, 0) -- attached: follows o when o is dragged
          return
        end
      end
    end
  end
end

-- Dragging: docked windows move as one group - dragging any of them moves the window at the root
-- of its dock chain, and everything attached follows. Alt-drag takes just that window out.
local OURS = {}
for _, name in ipairs(WINDOWS) do OURS[name] = true end

local function DockRoot(f)
  for _ = 1, 6 do
    local _, rel = f:GetPoint(1)
    -- only through windows that are open: a closed one can't be dragged
    if rel and rel ~= UIParent and rel.GetName and OURS[rel:GetName() or ""] and rel:IsShown() then
      f = rel
    else
      return f
    end
  end
  return f
end

function ns.DragStart(f)
  local mover = IsAltKeyDown() and f or DockRoot(f)
  f.dragMover = mover
  mover:StartMoving()
end

function ns.DragStop(f)
  local mover = f.dragMover or f
  f.dragMover = nil
  mover:StopMovingOrSizing()
end

-- Price List shortcuts: /ah, and a key binding (Bindings.xml; set the key in the game's
-- Keybindings menu under AddOns > AuctionatorSync).
BINDING_HEADER_AUCTIONATORSYNC = "AuctionatorSync"
BINDING_NAME_AUCTIONATORSYNC_PRICELIST = "Open / close the Price List"
function AuctionatorSync_TogglePriceList() ns.TogglePriceList() end
SLASH_AUCTIONATORSYNCPRICES1 = "/ah"
SlashCmdList.AUCTIONATORSYNCPRICES = function() ns.TogglePriceList() end

SLASH_AUCTIONATORSYNC1 = "/async"
SLASH_AUCTIONATORSYNC2 = "/aucsync"
SlashCmdList.AUCTIONATORSYNC = function(msg)
  local cmd = strtrim(msg or ""):lower()
  if cmd == "sync" then
    ns.CatchUp(true)
  elseif cmd == "status" then
    ns.PrintStatus()
  elseif cmd == "prices" or cmd == "pricelist" then
    ns.TogglePriceList()
  elseif cmd == "log" or cmd == "debug" then
    ns.ToggleLog()
  elseif cmd == "" then
    ns.ToggleWindow()
  else
    ns.Print("|cffffd100/async|r window · |cffffd100/async sync|r sync now · "
      .. "|cffffd100/async status|r what's synced · |cffffd100/ah|r or |cffffd100/async prices|r price list · |cffffd100/async log|r verbose log")
  end
end
