-- /async window: settings, Sync now, the price check item, and who's online with AuctionatorSync.
local _, ns = ...

local frame

local OPTIONS = {
  { key = "guild", label = "Sync with my guild" },
  { key = "friends", label = "Sync with my friends list" },
  { key = "bnet", label = "Sync with Battle.net friends on this realm" },
  { key = "shareScans", label = "Share my scans automatically" },
  { key = "catchUpOnLogin", label = "Sync with friends online when I log in" },
  { key = "announce", label = "Show chat messages",
    tip = "Sign-in and sync messages in chat. Replies to /async commands and Sync now always show." },
  { key = "verbose", label = "Verbose mode",
    tip = "Records every step (who answered, the host, what was sent and received, what changed) in a log window. Only you see it. Also /async log.",
    onClick = function(on) ns.ShowLog(on) end },
}

local function Ago(ts)
  local s = ns.Now() - (ts or 0)
  if s < 60 then return "just now" end
  if s < 3600 then return floor(s / 60) .. "m ago" end
  if s < 86400 then return floor(s / 3600) .. "h ago" end
  return floor(s / 86400) .. "d ago"
end

local function Money(copper)
  if not copper then return "?" end
  if GetMoneyString then return GetMoneyString(copper, true) end
  if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
    return C_CurrencyInfo.GetCoinTextureString(copper)
  end
  return tostring(copper) .. "c"
end


----------------------------------------------------------------------------------------------
-- Price check: the latest changed price, as an item button. Friends compare it to check
-- they're in sync; the tooltip also shows Auctionator's own price lines.

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local loading = {}

local function RefreshPriceCheck()
  local pc = frame.priceCheck
  local c = ns.LastChange()
  local id = c and ns.ItemIDFromKey(c.key)
  pc.itemID = id
  if not id then
    pc.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    pc.button:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    pc.name:SetText("|cff999999No price changes yet|r")
    pc.price:SetText("")
    pc.source:SetText("|cff999999Scan the auction house, or wait for a friend's update.|r")
    return
  end

  local name, link, quality = GetInfo(id)
  pc.link = link
  pc.icon:SetTexture(GetIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark")
  local r, g, b = 1, 1, 1
  if quality and C_Item and C_Item.GetItemQualityColor then
    r, g, b = C_Item.GetItemQualityColor(quality)
  elseif quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
    local q = ITEM_QUALITY_COLORS[quality]
    r, g, b = q.r, q.g, q.b
  end
  pc.button:SetBackdropBorderColor(r, g, b, 1)
  if name then
    pc.name:SetText(name)
    pc.name:SetTextColor(r, g, b)
  else
    pc.name:SetText("Item " .. id)
    pc.name:SetTextColor(1, 1, 1)
    -- not in the item cache yet: refresh once it loads
    if Item and Item.CreateFromItemID and not loading[id] then
      loading[id] = true
      Item:CreateFromItemID(id):ContinueOnItemLoad(function()
        loading[id] = nil
        if frame:IsShown() then RefreshPriceCheck() end
      end)
    end
  end

  -- Auctionator's current price (it can only differ if something changed it since)
  local db = Auctionator and Auctionator.Database and Auctionator.Database.db
  local entry = type(db) == "table" and db[c.key]
  local now = type(entry) == "table" and entry.m or c.price
  local text = Money(now)
  if c.was and c.was > 0 and c.was ~= now then
    text = text .. "  |cff999999was " .. Money(c.was) .. "|r"
  end
  pc.price:SetText(text)
  pc.source:SetText(string.format("|cff999999%s · %s|r", c.from and "From AuctionatorSync" or "From your scan", Ago(c.at)))
end

local function BuildPriceCheck(y)
  local pc = {}
  frame.priceCheck = pc

  local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header:SetPoint("TOPLEFT", 16, y)
  header:SetText("Price check")

  local why = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  why:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
  why:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  why:SetJustifyH("LEFT")
  why:SetTextColor(0.6, 0.6, 0.6)
  why:SetText("The latest price change. If a friend's matches, you're in sync.")

  local button = CreateFrame("Button", nil, frame, "BackdropTemplate")
  button:SetSize(40, 40)
  button:SetPoint("TOPLEFT", why, "BOTTOMLEFT", 0, -6)
  button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  button:RegisterForClicks("LeftButtonUp")
  pc.button = button

  pc.icon = button:CreateTexture(nil, "ARTWORK")
  pc.icon:SetPoint("TOPLEFT", 1, -1)
  pc.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  pc.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local highlight = button:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints(pc.icon)
  highlight:SetColorTexture(1, 1, 1, 0.15)

  button:SetScript("OnEnter", function(self)
    if not pc.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
      GameTooltip:SetItemByID(pc.itemID)
    else
      GameTooltip:SetHyperlink("item:" .. pc.itemID)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
  -- Shift-click links it in chat, like any item button.
  button:SetScript("OnClick", function()
    if pc.link and HandleModifiedItemClick then HandleModifiedItemClick(pc.link) end
  end)

  pc.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  pc.name:SetPoint("TOPLEFT", button, "TOPRIGHT", 8, -1)
  pc.name:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  pc.name:SetJustifyH("LEFT")
  pc.name:SetWordWrap(false)

  pc.price = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  pc.price:SetPoint("TOPLEFT", pc.name, "BOTTOMLEFT", 0, -2)
  pc.price:SetJustifyH("LEFT")

  pc.source = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pc.source:SetPoint("TOPLEFT", pc.price, "BOTTOMLEFT", 0, -2)
  pc.source:SetJustifyH("LEFT")

  return button
end

----------------------------------------------------------------------------------------------
-- Online list: everyone online with AuctionatorSync (you included), grouped by version.
-- Collapsed it's one line of counts; click the header to see the names.

-- "0.10.2" > "0.9.0": compare number by number
local function NewerVersion(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- versions (newest first), groups[version] = sorted names ("You" first), total count
function ns.OnlineGroups()
  local groups, versions, count = {}, {}, 1
  local function Add(version, name)
    version = tostring(version or "?")
    if not groups[version] then
      groups[version] = {}
      versions[#versions + 1] = version
    end
    table.insert(groups[version], name)
  end
  Add(ns.VERSION, "You")
  for _, peer in pairs(ns.peers) do
    if not peer.otherRealm and ns.IsPeerOnline(peer) then
      Add(peer.version, peer.name)
      count = count + 1
    end
  end
  table.sort(versions, NewerVersion)
  for _, names in pairs(groups) do
    table.sort(names, function(a, b)
      if a == "You" or b == "You" then return a == "You" end
      return a < b
    end)
  end
  return versions, groups, count
end

local function RefreshOnline()
  local versions, groups, count = ns.OnlineGroups()
  local newest = versions[1]

  local expanded = ns.db.onlineExpanded
  frame.onlineHeader.text:SetText(string.format("%s Online with AuctionatorSync (%d)",
    expanded and "|cffffd100-|r" or "|cffffd100+|r", count))

  local parts = {}
  for _, v in ipairs(versions) do
    local colour = (v == newest) and "|cff33ff99" or "|cffff9966"
    local names = groups[v]
    if expanded then
      parts[#parts + 1] = string.format("%sv%s|r |cff999999(%d%s)|r  %s", colour, v, #names,
        v == newest and "" or ", older", table.concat(names, ", "))
    else
      parts[#parts + 1] = string.format("%sv%s|r ×%d", colour, v, #names)
    end
  end
  frame.peers:SetText(table.concat(parts, expanded and "\n" or "   "))

  -- grow or shrink the window to fit the list
  local top, listTop = frame:GetTop(), frame.peers:GetTop()
  if top and listTop then
    frame:SetHeight(top - listTop + frame.peers:GetStringHeight() + 16)
  end
end

----------------------------------------------------------------------------------------------

local function Refresh()
  if not frame or not frame:IsShown() then return end
  for _, cb in ipairs(frame.checks) do cb:SetChecked(ns.db[cb.key] and true or false) end

  RefreshPriceCheck()
  RefreshOnline()

  local realm = ns.store.realms[ns.RealmKey() or ""]
  local last = realm and realm.lastCatchUp or 0
  frame.status:SetText(string.format("Realm: %s\nLast sync: %s", tostring(ns.RealmKey() or "?"),
    last > 0 and date("%d %b %H:%M", last) or "never"))
end

local function Build()
  frame = CreateFrame("Frame", "AuctionatorSyncFrame", UIParent, "BackdropTemplate")
  frame:SetSize(380, 500)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
  })
  frame:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
  frame:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  table.insert(UISpecialFrames, "AuctionatorSyncFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("AuctionatorSync |cff999999v" .. ns.VERSION .. "|r")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  frame.checks = {}
  local y = -42
  for _, opt in ipairs(OPTIONS) do
    local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 12, y)
    cb.key = opt.key
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(opt.label)
    cb:SetScript("OnClick", function(self)
      ns.db[self.key] = self:GetChecked() and true or false
      if opt.onClick then opt.onClick(ns.db[self.key]) end
      Refresh()
    end)
    if opt.tip then
      cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(opt.label)
        GameTooltip:AddLine(opt.tip, 1, 1, 1, true)
        GameTooltip:Show()
      end)
      cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    table.insert(frame.checks, cb)
    y = y - 26
  end

  local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  sync:SetSize(120, 24)
  sync:SetPoint("TOPLEFT", 16, y - 8)
  sync:SetText("Sync now")
  sync:SetScript("OnClick", function() ns.CatchUp(true) end)

  local logButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  logButton:SetSize(60, 24)
  logButton:SetPoint("TOPRIGHT", -16, y - 8)
  logButton:SetText("Log")
  logButton:SetScript("OnClick", function() ns.ToggleLog() end)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("LEFT", sync, "RIGHT", 12, 0)
  frame.status:SetPoint("RIGHT", logButton, "LEFT", -8, 0)
  frame.status:SetJustifyH("LEFT")

  local itemButton = BuildPriceCheck(y - 50)

  local header = CreateFrame("Button", nil, frame)
  header:SetPoint("TOPLEFT", itemButton, "BOTTOMLEFT", 0, -18)
  header:SetSize(260, 16)
  header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header.text:SetPoint("LEFT")
  header:SetScript("OnClick", function()
    ns.db.onlineExpanded = not ns.db.onlineExpanded
    Refresh()
  end)
  header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ns.db.onlineExpanded and "Click to hide names" or "Click to show names")
    GameTooltip:AddLine("Orange versions are older than the newest one online.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  header:SetScript("OnLeave", GameTooltip_Hide)
  frame.onlineHeader = header

  frame.peers = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.peers:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  frame.peers:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  frame.peers:SetJustifyH("LEFT")
  frame.peers:SetJustifyV("TOP")
  frame.peers:SetSpacing(3)

  frame:SetScript("OnShow", Refresh)
  C_Timer.NewTicker(5, Refresh)
  frame:Hide() -- a new frame starts shown; start hidden so the first /async opens it
end

function ns.ToggleWindow()
  if not frame then Build() end
  frame:SetShown(not frame:IsShown())
  Refresh()
end
