-- /async window: settings, Sync now, the price check item, and who's online with AuctionatorSync.
local _, ns = ...

local frame

local OPTIONS = {
  { key = "shareScans", label = "Share my scans with everyone online",
    tip = "When an Auctionator scan finishes, or you close the auction house after searching, the prices that changed go to everyone online with AuctionatorSync." },
  { key = "catchUpOnLogin", label = "Sync when I log in",
    tip = "Handshake with the host (whoever holds the master list) when you come online, so you start with the newest prices." },
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
-- Online list: everyone online with AuctionatorSync (you included): name, version, and where
-- they stand against the master list. The host (who holds the master list and hands it to
-- newcomers) is first, marked with a star. Click the header to fold it to one summary line.
--   in sync           same fingerprint as the host: the same master list
--   handshaking with  getting the master list right now
--   waiting to sync   online, handshake not started yet
--   not in sync yet   different prices (a fresh scan going out, or about to re-sync)
--   needs update      an older AuctionatorSync that can't sync with this one

local function RefreshOnline()
  local rows = ns.StatusRows()
  local expanded = ns.db.onlineExpanded ~= false
  local inSync = 0
  for _, row in ipairs(rows) do
    if row.text == "in sync" then inSync = inSync + 1 end
  end
  frame.onlineHeader.text:SetText(string.format("%s Online with AuctionatorSync (%d) |cff999999- %d in sync|r",
    expanded and "|cffffd100-|r" or "|cffffd100+|r", #rows, inSync))

  local lines = {}
  if expanded then
    for _, row in ipairs(rows) do
      lines[#lines + 1] = string.format("%s%s  |cff999999v%s|r  |cff%s%s%s|r",
        row.host and "|cffffd100*|r " or "   ", row.name, tostring(row.version), row.color,
        row.host and "host - " or "", row.text)
    end
  else
    local counts, order = {}, {}
    for _, row in ipairs(rows) do
      local key = "|cff" .. row.color .. row.text:gsub(" with .*$", "") .. "|r"
      if not counts[key] then counts[key] = 0; order[#order + 1] = key end
      counts[key] = counts[key] + 1
    end
    for _, key in ipairs(order) do lines[#lines + 1] = counts[key] .. " " .. key end
  end
  frame.peers:SetText(table.concat(lines, expanded and "\n" or "   "))

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
    ns.db.onlineExpanded = ns.db.onlineExpanded == false
    Refresh()
  end)
  header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ns.db.onlineExpanded == false and "Click to show everyone" or "Click to fold to a summary")
    GameTooltip:AddLine("* host: holds the master list and hands it to whoever comes online.", 1, 1, 1, true)
    GameTooltip:AddLine("|cff33ff99in sync|r: the same master list as the host.", 1, 1, 1, true)
    GameTooltip:AddLine("|cffffd100handshaking / waiting to sync|r: getting the master list.", 1, 1, 1, true)
    GameTooltip:AddLine("|cffff9966not in sync yet|r: different prices for now (a fresh scan going out, or re-syncing within 2 minutes).", 1, 1, 1, true)
    GameTooltip:AddLine("|cffff5555needs update|r: an older AuctionatorSync that can't sync with this one.", 1, 1, 1, true)
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
