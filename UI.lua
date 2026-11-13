-- /async window, top to bottom: settings, Sync now, who's online with AuctionatorSync (searchable
-- table), then the Sync Monitor and the log (Monitor.lua, Log.lua).
local _, ns = ...

local frame

local OPTIONS = {
  { key = "announce", label = "Show chat messages",
    tip = "Sign-in and sync messages in chat. Replies to /async commands and Sync now always show." },
  { key = "minimapShown", label = "Show minimap button",
    tip = "Left-click it for these settings, right-click for the Price List.",
    get = function() return not ns.db.minimap.hide end,
    onClick = function(on) ns.SetMinimapShown(on) end },
}

local function Ago(ts)
  local s = ns.Now() - (ts or 0)
  if s < 60 then return "just now" end
  if s < 3600 then return floor(s / 60) .. "m ago" end
  if s < 86400 then return floor(s / 3600) .. "h ago" end
  return floor(s / 86400) .. "d ago"
end

----------------------------------------------------------------------------------------------
-- Online list: a table of everyone online with AuctionatorSync (this character included):
-- Player | Version | Status. Anyone hosting a handshake right now (any in-sync player can) is
-- first, with a crown. Click the header to fold it to one summary line.
--   in sync           holds the master list (the fingerprint most ready players have)
--   handshaking with  getting the master list right now
--   waiting to sync   online, handshake not started yet
--   not in sync yet   different prices (a fresh scan going out, or about to re-sync)
--   needs update      an older AuctionatorSync that can't sync with this one

local ROW_H = 18
local VISIBLE_MAX = 16 -- rows shown before the table scrolls
local FRAME_W = 700
-- x offsets of the columns (Player starts at 20, after the host crown)
local COL_VERSION, COL_STATUS, COL_LAST = 220, 300, 580
local SCROLL_W = 10

-- Click a heading for its menu: the sort choices, and (Version, Status) the filters. The host
-- always stays at the top. desc = reverse of the column's natural order.
local COLUMNS = {
  { key = "name", label = "Player", x = 20,
    sorts = { { label = "A to Z", desc = false }, { label = "Z to A", desc = true } } },
  { key = "version", label = "Version", x = COL_VERSION,
    sorts = { { label = "Newest first", desc = true }, { label = "Oldest first", desc = false } } },
  { key = "rank", label = "Status", x = COL_STATUS,
    sorts = { { label = "In sync first", desc = false }, { label = "Not in sync first", desc = true } } },
  { key = "lastSync", label = "Last sync", x = COL_LAST,
    sorts = { { label = "Most recent first", desc = false }, { label = "Longest ago first", desc = true } } },
}

-- Filters, in the Version and Status heading menus. While one is on, the heading shows it
-- instead of the column name, in blue.
local HEADING_FILTERS = {
  version = { db = "filterVersion", options = {
    { key = "all", label = "All" },
    { key = "current", label = "Up to date", color = "33ff99", test = function(r) return not r.old end },
    { key = "old", label = "Old", color = "ff5555", test = function(r) return r.old end },
  } },
  rank = { db = "filterStatus", options = {
    { key = "all", label = "All" },
    { key = "insync", label = "In sync", color = "33ff99", test = function(r) return r.rank == 1 end },
    { key = "notsync", label = "Not in sync", color = "ff5555", test = function(r) return r.rank ~= 1 end },
  } },
}

local function ActiveOption(spec)
  local current = ns.db[spec.db] or "all"
  for _, o in ipairs(spec.options) do
    if o.key == current then return o end
  end
  return spec.options[1]
end

-- "0.10.2" > "0.9.0": compare number by number
local function VersionLess(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y end
  end
  return false
end

-- Last sync colour: green under 10 minutes, yellow under an hour, red under a day, grey older
local function SyncAgeColor(ts)
  local age = ns.Now() - ts
  if age < 600 then return "33ff99" end
  if age < 3600 then return "ffd100" end
  if age < 86400 then return "ff5555" end
  return "808080"
end

local function SortRows(rows)
  local key, desc = ns.db.onlineSort or "rank", ns.db.onlineSortDesc and true or false
  table.sort(rows, function(a, b)
    if a.host ~= b.host then return a.host end -- the host is always pinned to the top
    local less, more
    if key == "name" then
      less, more = a.name:lower() < b.name:lower(), b.name:lower() < a.name:lower()
    elseif key == "version" then
      less, more = VersionLess(a.version, b.version), VersionLess(b.version, a.version)
    elseif key == "lastSync" then
      local x, y = a.lastSync or 0, b.lastSync or 0
      less, more = x > y, y > x -- most recent first
    else
      less, more = a.rank < b.rank, b.rank < a.rank
    end
    if less ~= more then
      if desc then return more end
      return less
    end
    return a.name:lower() < b.name:lower()
  end)
end
local CROWN = "Interface\\GroupFrame\\UI-Group-LeaderIcon"

local function TableRow(i)
  local t = frame.onlineTable
  local row = t.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, t)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", t.head, "BOTTOMLEFT", 0, -2 - (i - 1) * ROW_H)
  row:SetPoint("RIGHT", t, "RIGHT", -SCROLL_W - 4, 0)
  row.stripe = row:CreateTexture(nil, "BACKGROUND")
  row.stripe:SetAllPoints()
  row.stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.05 or 0)
  row.crown = row:CreateTexture(nil, "ARTWORK")
  row.crown:SetSize(14, 14)
  row.crown:SetPoint("LEFT", 2, 0)
  row.crown:SetTexture(CROWN)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.name:SetPoint("LEFT", 20, 0)
  row.name:SetWidth(COL_VERSION - 24)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.version = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.version:SetPoint("LEFT", COL_VERSION, 0)
  row.version:SetJustifyH("LEFT")
  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.status:SetPoint("LEFT", COL_STATUS, 0)
  row.status:SetWidth(COL_LAST - COL_STATUS - 6)
  row.status:SetJustifyH("LEFT")
  row.status:SetWordWrap(false)
  row.last = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.last:SetPoint("LEFT", COL_LAST, 0)
  row.last:SetJustifyH("LEFT")
  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(d.name)
    GameTooltip:AddLine("AuctionatorSync v" .. tostring(d.version), 1, 1, 1)
    GameTooltip:AddLine(d.text, tonumber(d.color:sub(1, 2), 16) / 255, tonumber(d.color:sub(3, 4), 16) / 255,
      tonumber(d.color:sub(5, 6), 16) / 255)
    GameTooltip:AddLine("Last sync: " .. (d.lastSync and date("%d %b %H:%M", d.lastSync) or "unknown"), 0.7, 0.7, 0.7)
    if d.newest then
      GameTooltip:AddLine("Newest price: " .. date("%d %b %H:%M", d.newest), 0.7, 0.7, 0.7)
    end
    if d.host then GameTooltip:AddLine("Hosting a handshake right now.", 1, 0.82, 0, true) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  t.rows[i] = row
  return row
end

local function RefreshOnline()
  local all = ns.StatusRows()
  local expanded = ns.db.onlineExpanded ~= false
  local inSync = 0
  for _, row in ipairs(all) do
    if row.rank == 1 then inSync = inSync + 1 end
  end
  frame.onlineHeader.text:SetText(string.format("%s Online (%d) |cff999999- %d in sync|r",
    expanded and "|cffffd100-|r" or "|cffffd100+|r", #all, inSync))

  -- "Old" = older than the newest version anyone online runs
  local newest = ns.VERSION
  for _, row in ipairs(all) do
    if VersionLess(newest, row.version) then newest = row.version end
  end
  -- version colour against the newest: green newest, yellow same release older patch,
  -- red older release (still syncs), grey too old to sync at all
  local newMajor, newMinor = tostring(newest):match("^(%d+)%.(%d+)")
  for _, row in ipairs(all) do
    row.old = VersionLess(row.version, newest)
    local major, minor = tostring(row.version):match("^(%d+)%.(%d+)")
    if row.rank == 5 then
      row.versionColor = "808080"
    elseif not row.old then
      row.versionColor = "33ff99"
    elseif major == newMajor and minor == newMinor then
      row.versionColor = "ffd100"
    else
      row.versionColor = "ff5555"
    end
  end

  local query = expanded and (frame.searchText or ""):lower() or "" -- the box is hidden when folded
  local rows = {}
  for _, row in ipairs(all) do
    local keep = true
    for _, spec in pairs(HEADING_FILTERS) do
      local o = ActiveOption(spec)
      if o.test and not o.test(row) then keep = false end
    end
    if keep and query ~= "" and not row.name:lower():find(query, 1, true) then keep = false end
    if keep then rows[#rows + 1] = row end
  end
  frame.search:SetShown(expanded)
  frame.onlineAll = all
  SortRows(rows)
  local t = frame.onlineTable
  for _, h in ipairs(t.headings) do
    local sorted = (ns.db.onlineSort or "rank") == h.key
    local spec = HEADING_FILTERS[h.key]
    local o = spec and ActiveOption(spec)
    local filtered = o and o.key ~= "all"
    h.text:SetText(filtered and o.label or h.label)
    if filtered then
      h.text:SetTextColor(0.4, 0.8, 1)
    elseif sorted then
      h.text:SetTextColor(1, 1, 1)
    else
      h.text:SetTextColor(1, 0.82, 0)
    end
    h.arrow:SetVertexColor(filtered and 0.4 or 1, filtered and 0.8 or 1, filtered and 1 or 1)
  end

  local bottom -- the lowest thing shown, to size the window
  if expanded then
    t:Show()
    frame.peers:Hide()
    local total = #rows
    local visible = math.min(total, VISIBLE_MAX)
    local maxOffset = math.max(0, total - VISIBLE_MAX)
    t.offset = math.min(t.offset or 0, maxOffset)
    for i = 1, visible do
      local data = rows[i + t.offset]
      local row = TableRow(i)
      row.data = data
      row.crown:SetShown(data.host and true or false)
      local name = data.name
      if query ~= "" then -- the matching part in gold
        local s, e = name:lower():find(query, 1, true)
        if s then name = name:sub(1, s - 1) .. "|cffffd100" .. name:sub(s, e) .. "|r" .. name:sub(e + 1) end
      end
      row.name:SetText(name)
      row.version:SetText("|cff" .. (data.versionColor or "999999") .. "v" .. tostring(data.version) .. "|r")
      row.status:SetText("|cff" .. data.color .. data.text .. "|r")
      if data.lastSync then
        row.last:SetText("|cff" .. SyncAgeColor(data.lastSync) .. Ago(data.lastSync) .. "|r")
      else
        -- no time to show, but hosting: it holds the master list, so it's in sync by definition
        row.last:SetText(data.host and "|cff33ff99host|r" or "|cff808080-|r")
      end
      row:Show()
    end
    for i = visible + 1, #t.rows do t.rows[i]:Hide() end
    t.empty:SetText(query ~= "" and string.format('No one online matches "%s".', frame.searchText)
      or "Nobody matches this filter.")
    t.empty:SetShown(total == 0)

    -- scroll bar, only when there are more rows than fit
    local scroll = t.scroll
    scroll:SetShown(maxOffset > 0)
    if maxOffset > 0 then
      scroll:SetHeight(visible * ROW_H)
      scroll.ignore = true
      scroll:SetMinMaxValues(0, maxOffset)
      scroll:SetValue(t.offset)
      scroll.ignore = false
      scroll:GetThumbTexture():SetHeight(math.max(16, visible * ROW_H * visible / total))
    end

    -- footer: how many are shown, when that isn't everyone
    local footer
    if maxOffset > 0 then
      footer = string.format("%d-%d of %d", t.offset + 1, t.offset + visible, total)
      if total < #all then footer = footer .. string.format(" (%d online)", #all) end
    elseif total < #all and total > 0 then
      footer = string.format("Showing %d of %d", total, #all)
    end
    t.footer:SetText(footer and ("|cff999999" .. footer .. "|r") or "")
    t.footer:SetShown(footer ~= nil)
    t:SetHeight(t.head:GetHeight() + 4 + math.max(visible, 1) * ROW_H + (footer and 16 or 0))
    bottom = t
  else
    t:Hide()
    local counts, order = {}, {}
    for _, row in ipairs(rows) do
      local key = "|cff" .. row.color .. row.text:gsub(" with .*$", "") .. "|r"
      if not counts[key] then counts[key] = 0; order[#order + 1] = key end
      counts[key] = counts[key] + 1
    end
    local parts = {}
    for _, key in ipairs(order) do parts[#parts + 1] = counts[key] .. " " .. key end
    frame.peers:SetText(table.concat(parts, "   "))
    frame.peers:Show()
    bottom = frame.peers
  end

  -- the Sync Monitor goes under the list; the window grows or shrinks to fit both
  local top, listTop = frame:GetTop(), bottom:GetTop()
  if top and listTop then
    local h = bottom == t and t:GetHeight() or frame.peers:GetStringHeight()
    local monTop = top - listTop + h + 12
    local mon = frame.monitor
    mon:ClearAllPoints()
    mon:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -monTop)
    mon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -monTop)
    frame:SetHeight(monTop + mon:GetHeight() + 4)
  end
end

----------------------------------------------------------------------------------------------

local function Refresh()
  if not frame or not frame:IsShown() then return end
  for _, cb in ipairs(frame.checks) do
    cb:SetChecked((cb.get and cb.get()) or (not cb.get and ns.db[cb.key]) and true or false)
  end

  RefreshOnline()

  local last = ns.LastSync and ns.LastSync() or 0
  frame.status:SetText(string.format("Last sync\n%s", last > 0 and date("%d %b %H:%M", last) or "never"))
end

local function Build()
  frame = CreateFrame("Frame", "AuctionatorSyncFrame", UIParent, "BackdropTemplate")
  frame:SetSize(FRAME_W, 500)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", ns.DragStart) -- moves its docked group; Alt-drag undocks it
  frame:SetScript("OnDragStop", ns.DragStop)
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

  -- the settings, side by side on one line
  frame.checks = {}
  local y = -42
  for i, opt in ipairs(OPTIONS) do
    local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 12 + (i - 1) * 240, y)
    cb.key, cb.get = opt.key, opt.get
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(opt.label)
    cb:SetScript("OnClick", function(self)
      local on = self:GetChecked() and true or false
      if opt.get then opt.onClick(on) else
        ns.db[self.key] = on
        if opt.onClick then opt.onClick(on) end
      end
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
  end
  y = y - 26

  local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  sync:SetSize(90, 24)
  sync:SetPoint("TOPLEFT", 16, y - 8)
  sync:SetText("Sync now")
  sync:SetScript("OnClick", function() ns.CatchUp(true) end)

  local priceButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  priceButton:SetSize(80, 24)
  priceButton:SetPoint("TOPRIGHT", -16, y - 8)
  priceButton:SetText("Price List")
  priceButton:SetScript("OnClick", function() ns.TogglePriceList() end)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("LEFT", sync, "RIGHT", 12, 0)
  frame.status:SetPoint("RIGHT", priceButton, "LEFT", -8, 0)
  frame.status:SetJustifyH("LEFT")

  local header = CreateFrame("Button", nil, frame)
  header:SetPoint("TOPLEFT", 16, y - 50)
  header:SetSize(FRAME_W - 32 - 170, 16)
  header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header.text:SetPoint("LEFT")
  header:SetScript("OnClick", function()
    ns.db.onlineExpanded = ns.db.onlineExpanded == false
    Refresh()
  end)
  header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ns.db.onlineExpanded == false and "Click to show everyone" or "Click to fold to a summary")
    GameTooltip:AddLine("|T" .. CROWN .. ":0|t hosting: serving a handshake right now. Anyone in sync can host.", 1, 1, 1, true)
    GameTooltip:AddLine("|cff33ff99in sync|r: holds the master list (the price list most players have).", 1, 1, 1, true)
    GameTooltip:AddLine("|cffffd100handshaking / waiting to sync|r: getting the master list.", 1, 1, 1, true)
    GameTooltip:AddLine("|cffff5555not in sync yet|r: different prices for now (a fresh scan going out, or re-syncing within 2 minutes).", 1, 1, 1, true)
    GameTooltip:AddLine("|cff808080needs update|r: an older AuctionatorSync that can't sync with this one.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  header:SetScript("OnLeave", GameTooltip_Hide)
  frame.onlineHeader = header

  -- The heading menu: sort choices, then (Version, Status) filters, each with a tick on the
  -- current one. Built by hand: the game's own dropdown menus aren't reliable on Forever.
  -- A click anywhere else closes it.
  local menu = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  menu:SetWidth(150)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  menu:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
  menu:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
  menu:EnableMouse(true)
  menu:Hide()
  menu.items = {}
  local ITEM_H = 18
  local function MenuItem(i)
    local item = menu.items[i]
    if item then return item end
    item = CreateFrame("Button", nil, menu)
    item:SetHeight(ITEM_H)
    item:SetPoint("TOPLEFT", 1, -1 - (i - 1) * ITEM_H)
    item:SetPoint("RIGHT", -1, 0)
    item.hl = item:CreateTexture(nil, "HIGHLIGHT")
    item.hl:SetAllPoints()
    item.hl:SetColorTexture(1, 0.82, 0, 0.18)
    item.check = item:CreateTexture(nil, "OVERLAY")
    item.check:SetSize(14, 14)
    item.check:SetPoint("LEFT", 4, 0)
    item.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    item.text = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    item.text:SetPoint("LEFT", 22, 0)
    item:SetScript("OnClick", function(self)
      if not self.onClick then return end
      self.onClick()
      menu:Hide()
      Refresh()
    end)
    menu.items[i] = item
    return item
  end
  -- entries: { title = "Sort" } | { label, checked, onClick }
  function menu:Open(anchor, entries)
    if self:IsShown() and self.anchor == anchor then self:Hide(); return end
    self.anchor = anchor
    for i, e in ipairs(entries) do
      local item = MenuItem(i)
      item.onClick = e.onClick
      if e.title then
        item.text:SetText("|cff999999" .. e.title .. "|r")
        item.text:SetPoint("LEFT", 6, 0)
        item.check:Hide()
        item.hl:Hide()
      else
        item.text:SetText(e.label)
        item.text:SetPoint("LEFT", 22, 0)
        item.check:SetShown(e.checked and true or false)
        item.hl:Show()
      end
      item:Show()
    end
    for i = #entries + 1, #self.items do self.items[i]:Hide() end
    self:SetHeight(#entries * ITEM_H + 2)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -4, -2)
    self:Show()
  end
  menu:SetScript("OnUpdate", function(self)
    if (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton"))
      and not self:IsMouseOver() and not (self.anchor and self.anchor:IsMouseOver()) then
      self:Hide()
    end
  end)
  frame.headingMenu = menu

  local function HeadingMenu(col)
    local entries = { { title = "Sort" } }
    local sortKey, sortDesc = ns.db.onlineSort or "rank", ns.db.onlineSortDesc and true or false
    for _, so in ipairs(col.sorts) do
      entries[#entries + 1] = {
        label = so.label,
        checked = sortKey == col.key and sortDesc == so.desc,
        onClick = function() ns.db.onlineSort, ns.db.onlineSortDesc = col.key, so.desc end,
      }
    end
    local spec = HEADING_FILTERS[col.key]
    if spec then
      entries[#entries + 1] = { title = "Show" }
      local current = ActiveOption(spec).key
      for _, o in ipairs(spec.options) do
        local n = 0
        for _, row in ipairs(frame.onlineAll or {}) do
          if not o.test or o.test(row) then n = n + 1 end
        end
        entries[#entries + 1] = {
          label = (o.color and ("|cff" .. o.color .. o.label .. "|r") or o.label) .. "  |cff999999" .. n .. "|r",
          checked = o.key == current,
          onClick = function() ns.db[spec.db] = o.key end,
        }
      end
    end
    return entries
  end

  -- folded: one summary line
  frame.peers = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.peers:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  frame.peers:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  frame.peers:SetJustifyH("LEFT")
  frame.peers:SetJustifyV("TOP")

  -- unfolded: the table, with column headings over a thin line
  local t = CreateFrame("Frame", nil, frame)
  t:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  t:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  t.rows = {}
  t.head = CreateFrame("Frame", nil, t)
  t.head:SetPoint("TOPLEFT")
  t.head:SetPoint("RIGHT")
  t.head:SetHeight(16)
  t.headings = {}
  for i, col in ipairs(COLUMNS) do
    local h = CreateFrame("Button", nil, t.head)
    h:SetPoint("LEFT", col.x, 0)
    h:SetHeight(16)
    h:SetWidth(((COLUMNS[i + 1] and COLUMNS[i + 1].x) or (FRAME_W - 32 - SCROLL_W - 4)) - col.x - 4)
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetPoint("LEFT")
    h.key, h.label = col.key, col.label
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    h.arrow = h:CreateTexture(nil, "ARTWORK")
    h.arrow:SetSize(12, 12)
    h.arrow:SetPoint("LEFT", h.text, "RIGHT", 1, 0)
    h.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    h:SetScript("OnClick", function(self) frame.headingMenu:Open(self, HeadingMenu(col)) end)
    t.headings[#t.headings + 1] = h
  end
  t.empty = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  t.empty:SetPoint("TOPLEFT", t.head, "BOTTOMLEFT", 20, -4)
  t.empty:SetText("Nobody matches this filter.")
  local line = t.head:CreateTexture(nil, "ARTWORK")
  line:SetPoint("BOTTOMLEFT", 0, -1)
  line:SetPoint("BOTTOMRIGHT", 0, -1)
  line:SetHeight(1)
  line:SetColorTexture(1, 0.82, 0, 0.35)
  frame.onlineTable = t

  -- footer under the rows ("1-16 of 20", "Showing 3 of 6")
  t.footer = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  t.footer:SetPoint("BOTTOMLEFT", 20, 2)

  -- scroll bar (the mouse wheel works anywhere on the table)
  local scroll = CreateFrame("Slider", nil, t, "BackdropTemplate")
  scroll:SetPoint("TOPRIGHT", t.head, "BOTTOMRIGHT", 0, -2)
  scroll:SetWidth(SCROLL_W)
  scroll:SetOrientation("VERTICAL")
  scroll:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
  scroll:SetBackdropColor(1, 1, 1, 0.05)
  scroll:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
  scroll:GetThumbTexture():SetSize(SCROLL_W, 40)
  scroll:GetThumbTexture():SetVertexColor(1, 0.82, 0, 0.5)
  scroll:SetValueStep(1)
  scroll:SetObeyStepOnDrag(true)
  scroll:SetScript("OnValueChanged", function(self, value)
    if self.ignore then return end
    t.offset = math.floor(value + 0.5)
    RefreshOnline()
  end)
  scroll:Hide()
  t.scroll = scroll
  t.offset = 0
  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, (self.offset or 0) - delta * 3)
    RefreshOnline()
  end)

  -- name search, right of the "Online" heading
  local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  search:SetSize(150, 20)
  search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, y - 48)
  search:SetAutoFocus(false)
  search:SetTextInsets(0, 18, 0, 0) -- room for the x
  local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", 4, 0)
  hint:SetText("Search names")
  local clearSearch = CreateFrame("Button", nil, search)
  clearSearch:SetSize(16, 16)
  clearSearch:SetPoint("RIGHT", -2, 0)
  clearSearch.text = clearSearch:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  clearSearch.text:SetPoint("CENTER", 0, 1)
  clearSearch.text:SetText("x")
  clearSearch.text:SetTextColor(0.7, 0.7, 0.7)
  clearSearch:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.82, 0) end)
  clearSearch:SetScript("OnLeave", function(self) self.text:SetTextColor(0.7, 0.7, 0.7) end)
  clearSearch:SetScript("OnClick", function()
    search:SetText("")
    search:ClearFocus()
  end)
  clearSearch:Hide()
  search:SetScript("OnTextChanged", function(self)
    frame.searchText = self:GetText() or ""
    clearSearch:SetShown(frame.searchText ~= "")
    hint:SetShown(frame.searchText == "" and not self:HasFocus())
    t.offset = 0
    RefreshOnline()
  end)
  -- clicking in selects everything, so typing replaces it
  search:SetScript("OnEditFocusGained", function(self)
    hint:Hide()
    C_Timer.After(0, function() if self:HasFocus() then self:HighlightText() end end)
  end)
  search:SetScript("OnEditFocusLost", function(self) hint:SetShown((self:GetText() or "") == "") end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  frame.search = search

  -- the Sync Monitor and the log, under the online list (RefreshOnline places it)
  frame.monitor = ns.BuildMonitorSection(frame, function()
    if frame:IsShown() then RefreshOnline() end
  end)

  frame:SetScript("OnShow", function()
    Refresh()
    ns.RefreshLogSection(true)
    ns.RefreshMonitor()
  end)
  C_Timer.NewTicker(5, Refresh)
  frame:Hide() -- a new frame starts shown; start hidden so the first /async opens it
end

function ns.ShowWindow(show)
  if not frame then Build() end
  if show and not frame:IsShown() then
    ns.PlaceWindow(frame)
    frame:Show()
  elseif not show then
    frame:Hide()
  end
  Refresh()
end

function ns.ToggleWindow()
  if not frame then Build() end
  if not frame:IsShown() then ns.PlaceWindow(frame) end
  frame:SetShown(not frame:IsShown())
  Refresh()
end
