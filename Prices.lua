-- The Price List: every price in the master list (Auctionator's prices on this character), browsable
-- away from the auction house. Category sidebar (All, then each category, expandable into its
-- subcategories), a search box, and a sortable list: Price | Name | Available | Last seen.
--
-- Item names and quality colours need the game to load each item's details. So:
--   * a name book (AuctionatorSyncDB.names) keeps every resolved name and quality across sessions;
--   * a background warm-up after login asks the game for any item the book doesn't have yet,
--     a few dozen at a time;
--   * the list is only drawn once every item is resolved (a loading bar shows until then), and
--     items that never resolve (removed from the game) are left out, so no broken rows.
-- Icons and categories come from GetItemInfoInstant, which never needs loading.
local _, ns = ...

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local ClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
local SubClassInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo

----------------------------------------------------------------------------------------------
-- The name book and the warm-up

local WARM_BATCH = 40      -- items asked for per tick
local WARM_TICK = 0.1      -- seconds between ticks
local RETRY_AFTER = 20     -- seconds before asking again for an item that hasn't answered
local GIVE_UP_AFTER = 45   -- seconds before treating it as an item that won't resolve

local queue, qi = {}, 1
local waiting = {}  -- itemID -> { first asked, last asked }
local failed = {}   -- itemID -> true: not an item, or never answered (this session)
local warmTicker, warmTicks = nil, 0
local onProgress    -- the window's refresh, while it's open

local function Book() return ns.store.names end

local function Remember(id)
  local name, _, quality = GetInfo(id)
  if name then
    Book()[id] = { name, quality or 1 }
    waiting[id] = nil
    return true
  end
end

-- Every distinct item ID in the price list.
local function ItemIDs()
  local ids, seen = {}, {}
  for _, e in ipairs(ns.PriceEntries()) do
    local id = ns.ItemIDFromKey(e[1])
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

-- done = resolved or given up on; total = every item ID in the list
function ns.NameProgress()
  local done, total = 0, 0
  local book = Book()
  for _, id in ipairs(ItemIDs()) do
    total = total + 1
    if book[id] or failed[id] then done = done + 1 end
  end
  return done, total
end

local function WarmTick()
  local now = GetTime()
  local asked = 0
  while qi <= #queue and asked < WARM_BATCH do
    local id = queue[qi]
    qi = qi + 1
    if not Book()[id] and not failed[id] and not waiting[id] then
      if not GetInstant(id) then
        failed[id] = true -- not an item at all
      elseif not Remember(id) then
        waiting[id] = { now, now } -- GetItemInfo asked the game for it; the answer comes as an event
      end
      asked = asked + 1
    end
  end
  for id, w in pairs(waiting) do
    if now - w[1] > GIVE_UP_AFTER then
      waiting[id] = nil
      failed[id] = true
      ns.Log("item %d never loaded its details; left out of the Price List", id)
    elseif now - w[2] > RETRY_AFTER and not Remember(id) then
      w[2] = now
    end
  end
  warmTicks = warmTicks + 1
  local finished = qi > #queue and not next(waiting)
  if onProgress and (finished or warmTicks % 5 == 0) then onProgress() end -- the bar, twice a second
  if finished then
    warmTicker:Cancel()
    warmTicker = nil
    ns.Log("Price List item details ready: %s known", ns.Plural(select(2, ns.NameProgress()), "item"))
  end
end

-- Queue every item the book doesn't know yet (safe to call any time; repeats are cheap).
function ns.WarmNames()
  if not ns.store or not ns.store.names then return end
  queue, qi = {}, 1
  local book = Book()
  for _, id in ipairs(ItemIDs()) do
    if not book[id] and not failed[id] then queue[#queue + 1] = id end
  end
  if #queue == 0 then return end
  ns.Log("Price List: loading item details for %s in the background", ns.Plural(#queue, "item"))
  if not warmTicker then warmTicker = C_Timer.NewTicker(WARM_TICK, WarmTick) end
end

ns.On("GET_ITEM_INFO_RECEIVED", function(id, success)
  if not waiting[id] then return end
  if success == false then
    waiting[id] = nil
    failed[id] = true
  else
    Remember(id)
  end
end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if not (isLogin or isReload) then return end
  -- after the login rush, quietly
  C_Timer.After(20, function() ns.WarmNames() end)
end)

----------------------------------------------------------------------------------------------
-- Rows

local function Ago(ts)
  local s = ns.Now() - (ts or 0)
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  if s < 86400 then return math.floor(s / 3600) .. "h ago" end
  return math.floor(s / 86400) .. "d ago"
end

local function AgeColor(ts)
  local age = ns.Now() - ts
  if age < 3600 then return "33ff99" end      -- this hour
  if age < 86400 then return "ffd100" end     -- today
  if age < 7 * 86400 then return "ff5555" end -- this week
  return "808080"
end

local function QualityColor(q)
  if C_Item and C_Item.GetItemQualityColor then
    local r, g, b = C_Item.GetItemQualityColor(q or 1)
    if r then return r, g, b end
  end
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end

local function Money(copper)
  if GetMoneyString then return GetMoneyString(copper, true) end
  if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then return C_CurrencyInfo.GetCoinTextureString(copper) end
  return tostring(copper) .. "c"
end

-- All rows we can show: resolved names only.
local function BuildRows()
  local rows, book = {}, Book()
  for _, e in ipairs(ns.PriceEntries()) do
    local key = e[1]
    local id = ns.ItemIDFromKey(key)
    local known = id and book[id]
    if known then
      local _, _, _, _, icon, classID, subClassID = GetInstant(id)
      local extra = key:match("^g:%d+:(%d+)")
      local suffix = key:match("^gr:%d+:(.+)$")
      local name = known[1]
      if suffix then name = name .. " " .. suffix end
      rows[#rows + 1] = {
        key = key, id = id, name = name, extra = extra and ("ilvl " .. extra) or nil,
        quality = known[2], price = e[2], seen = e[3], avail = e[4],
        icon = icon, classID = classID or -1, subClassID = subClassID or -1,
      }
    end
  end
  return rows
end

----------------------------------------------------------------------------------------------
-- The window

local win
local ROW_H, SIDE_W, SIDE_ROW_H = 20, 180, 18
local state = { classID = nil, subClassID = nil, search = "" } -- this session's selection
local allRows = {}

local COLS = { -- x offsets inside the list
  { key = "price", label = "Price", x = 4, w = 110, right = true },
  { key = "name", label = "Name", x = 128, w = 250 },
  { key = "avail", label = "Available", x = 386, w = 64, right = true },
  { key = "seen", label = "Last seen", x = 460, w = 70 },
}

local function SortRows(rows)
  local key, desc = ns.db.priceSort or "name", ns.db.priceSortDesc and true or false
  table.sort(rows, function(a, b)
    local x, y
    if key == "name" then x, y = a.name:lower(), b.name:lower()
    elseif key == "price" then x, y = a.price, b.price
    elseif key == "avail" then x, y = a.avail or -1, b.avail or -1
    else x, y = b.seen, a.seen end -- "seen": most recent first
    if x ~= y then
      if desc then return x > y end
      return x < y
    end
    return a.name:lower() < b.name:lower()
  end)
end

local function Visible()
  local list = {}
  local search = state.search:lower()
  for _, row in ipairs(allRows) do
    if (not state.classID or row.classID == state.classID)
      and (not state.subClassID or row.subClassID == state.subClassID)
      and (search == "" or row.name:lower():find(search, 1, true)) then
      list[#list + 1] = row
    end
  end
  SortRows(list)
  return list
end

-- Sidebar entries: All, then each category (and its subcategories when expanded), with counts.
local function SideEntries()
  local classes, order = {}, {}
  for _, row in ipairs(allRows) do
    local c = classes[row.classID]
    if not c then
      c = { id = row.classID, count = 0, subs = {}, subOrder = {} }
      classes[row.classID] = c
      order[#order + 1] = row.classID
    end
    c.count = c.count + 1
    if not c.subs[row.subClassID] then
      c.subs[row.subClassID] = 0
      c.subOrder[#c.subOrder + 1] = row.subClassID
    end
    c.subs[row.subClassID] = c.subs[row.subClassID] + 1
  end
  table.sort(order)
  local entries = { { label = "All", count = #allRows, all = true } }
  ns.db.priceExpanded = ns.db.priceExpanded or {}
  for _, classID in ipairs(order) do
    local c = classes[classID]
    local expanded = ns.db.priceExpanded[classID]
    entries[#entries + 1] = { label = (ClassInfo and ClassInfo(classID)) or ("Category " .. classID),
      count = c.count, classID = classID, expandable = #c.subOrder > 1, expanded = expanded }
    if expanded then
      table.sort(c.subOrder)
      for _, sub in ipairs(c.subOrder) do
        entries[#entries + 1] = { label = (SubClassInfo and SubClassInfo(classID, sub)) or ("Type " .. sub),
          count = c.subs[sub], classID = classID, subClassID = sub, indent = true }
      end
    end
  end
  return entries
end

local Refresh

local function RefreshSide()
  local entries = SideEntries()
  local side = win.side
  local fit = side.fit
  side.offset = math.max(0, math.min(side.offset, #entries - fit))
  for i = 1, fit do
    local b = side.buttons[i]
    local e = entries[side.offset + i]
    if e then
      local selected = (e.all and not state.classID)
        or (e.classID == state.classID and e.subClassID == state.subClassID and not e.all)
      local mark = e.expandable and (e.expanded and "|cffffd100-|r " or "|cffffd100+|r ") or "  "
      b.text:SetText((e.indent and "      " or "") .. mark .. e.label .. "  |cff999999" .. ns.Num(e.count) .. "|r")
      b.text:SetTextColor(selected and 1 or 0.9, selected and 0.82 or 0.9, selected and 0 or 0.9)
      b.sel:SetShown(selected)
      b.entry = e
      b:Show()
    else
      b:Hide()
    end
  end
end

local function RefreshList()
  local rows = Visible()
  local list = win.list
  local fit = list.fit
  list.offset = math.max(0, math.min(list.offset, #rows - fit))
  list.scroll:SetMinMaxValues(0, math.max(0, #rows - fit))
  list.scroll:SetShown(#rows > fit)
  list.scroll.ignore = true
  list.scroll:SetValue(list.offset)
  list.scroll.ignore = nil
  for i = 1, fit do
    local line = list.lines[i]
    local row = rows[list.offset + i]
    if row then
      line.row = row
      line.icon:SetTexture(row.icon)
      line.name:SetText(row.name .. (row.extra and ("  |cff999999" .. row.extra .. "|r") or ""))
      line.name:SetTextColor(QualityColor(row.quality))
      line.price:SetText(Money(row.price))
      line.avail:SetText(row.avail and ns.Num(row.avail) or "|cff808080-|r")
      line.seen:SetText("|cff" .. AgeColor(row.seen) .. Ago(row.seen) .. "|r")
      line:Show()
    else
      line:Hide()
    end
  end
  win.count:SetText(string.format("%s of %s", ns.Num(#rows), ns.Plural(#allRows, "item")))
  list.empty:SetShown(#rows == 0)
  for _, h in ipairs(list.headings) do
    local active = (ns.db.priceSort or "name") == h.key
    h.text:SetText(h.label .. (active and (ns.db.priceSortDesc and " v" or " ^") or ""))
    h.text:SetTextColor(1, active and 1 or 0.82, active and 1 or 0)
  end
end

Refresh = function(rebuild)
  if not win or not win:IsShown() then return end
  local done, total = ns.NameProgress()
  if done < total then
    -- still loading item details: show the bar, not half-drawn rows
    win.loading:Show()
    win.loading.bar:SetMinMaxValues(0, math.max(total, 1))
    win.loading.bar:SetValue(done)
    win.loading.text:SetText(string.format("Loading item details... %s / %s", ns.Num(done), ns.Num(total)))
    win.list:Hide()
    win.side:Hide()
    return
  end
  win.loading:Hide()
  win.list:Show()
  win.side:Show()
  if rebuild or not win.built then
    allRows = BuildRows()
    win.built = true
  end
  RefreshSide()
  RefreshList()
end

local function Build()
  win = CreateFrame("Frame", "AuctionatorSyncPriceListFrame", UIParent, "BackdropTemplate")
  win:SetSize(760, 500)
  win:SetPoint("CENTER")
  win:SetFrameStrata("DIALOG")
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", win.StopMovingOrSizing)
  win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  win:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
  win:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  table.insert(UISpecialFrames, "AuctionatorSyncPriceListFrame")

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -10)
  title:SetText("Price List")
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  -- search
  local search = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
  search:SetSize(240, 20)
  search:SetPoint("TOPLEFT", 12 + SIDE_W + 10 + 6, -38) -- over the list's left edge (the box art sticks out ~6px)
  search:SetAutoFocus(false)
  local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", 4, 0)
  hint:SetText("Search")
  search:SetScript("OnTextChanged", function(self)
    state.search = self:GetText() or ""
    hint:SetShown(state.search == "" and not self:HasFocus())
    win.list.offset = 0
    Refresh()
  end)
  search:SetScript("OnEditFocusGained", function() hint:Hide() end)
  search:SetScript("OnEditFocusLost", function(self) hint:SetShown((self:GetText() or "") == "") end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  win.search = search

  win.count = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.count:SetPoint("RIGHT", win, "TOPRIGHT", -16, -48) -- level with the search box, at the far right
  win.count:SetJustifyH("RIGHT")

  -- sidebar
  local side = CreateFrame("Frame", nil, win, "BackdropTemplate")
  side:SetPoint("TOPLEFT", 12, -68)
  side:SetPoint("BOTTOMLEFT", 12, 12)
  side:SetWidth(SIDE_W)
  side:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  side:SetBackdropColor(0, 0, 0, 0.3)
  side:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  side.offset, side.buttons = 0, {}
  side.fit = math.floor((500 - 68 - 12 - 4) / SIDE_ROW_H)
  for i = 1, side.fit do
    local b = CreateFrame("Button", nil, side)
    b:SetHeight(SIDE_ROW_H)
    b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * SIDE_ROW_H)
    b:SetPoint("RIGHT", -2, 0)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.15)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetWordWrap(false)
    b:SetScript("OnClick", function(self)
      local e = self.entry
      if not e then return end
      if e.all then
        state.classID, state.subClassID = nil, nil
      elseif e.subClassID then
        state.classID, state.subClassID = e.classID, e.subClassID
      else
        -- a category: select it, and open/close its subcategories
        if state.classID == e.classID and not state.subClassID and e.expandable then
          ns.db.priceExpanded[e.classID] = not ns.db.priceExpanded[e.classID]
        else
          state.classID, state.subClassID = e.classID, nil
          if e.expandable then ns.db.priceExpanded[e.classID] = true end
        end
      end
      win.list.offset = 0
      Refresh()
    end)
    side.buttons[i] = b
  end
  side:EnableMouseWheel(true)
  side:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, self.offset - delta * 3)
    RefreshSide()
  end)
  win.side = side

  -- list
  local list = CreateFrame("Frame", nil, win, "BackdropTemplate")
  list:SetPoint("TOPLEFT", side, "TOPRIGHT", 10, 0)
  list:SetPoint("BOTTOMRIGHT", -12, 12)
  list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  list:SetBackdropColor(0, 0, 0, 0.3)
  list:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  list.offset, list.lines, list.headings = 0, {}, {}

  local head = CreateFrame("Frame", nil, list)
  head:SetPoint("TOPLEFT", 2, -2)
  head:SetPoint("TOPRIGHT", -18, -2)
  head:SetHeight(20)
  local line = head:CreateTexture(nil, "ARTWORK")
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  line:SetHeight(1)
  line:SetColorTexture(1, 0.82, 0, 0.35)
  for _, col in ipairs(COLS) do
    local h = CreateFrame("Button", nil, head)
    h:SetPoint("TOPLEFT", col.x, 0)
    h:SetSize(col.w, 20)
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if col.right then h.text:SetPoint("RIGHT", -2, 0) else h.text:SetPoint("LEFT", 2, 0) end
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    h.key, h.label = col.key, col.label
    if col.key == "avail" then
      h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Available")
        GameTooltip:AddLine("How many were listed when the item was last seen, on that day's scan.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      h:SetScript("OnLeave", GameTooltip_Hide)
    end
    h:SetScript("OnClick", function(self)
      if (ns.db.priceSort or "name") == self.key then
        ns.db.priceSortDesc = not ns.db.priceSortDesc
      else
        ns.db.priceSort, ns.db.priceSortDesc = self.key, false
      end
      Refresh()
    end)
    list.headings[#list.headings + 1] = h
  end

  list.fit = math.floor((500 - 68 - 12 - 24 - 4) / ROW_H)
  for i = 1, list.fit do
    local l = CreateFrame("Button", nil, list)
    l:SetHeight(ROW_H)
    l:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2 - (i - 1) * ROW_H)
    l:SetPoint("RIGHT", head, "RIGHT")
    local stripe = l:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
    local hl = l:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    l.price = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.price:SetPoint("RIGHT", l, "LEFT", COLS[1].x + COLS[1].w - 2, 0)
    l.price:SetJustifyH("RIGHT")
    l.icon = l:CreateTexture(nil, "ARTWORK")
    l.icon:SetSize(16, 16)
    l.icon:SetPoint("LEFT", COLS[2].x + 2, 0)
    l.name = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.name:SetPoint("LEFT", l.icon, "RIGHT", 4, 0)
    l.name:SetWidth(COLS[2].w - 24)
    l.name:SetJustifyH("LEFT")
    l.name:SetWordWrap(false)
    l.avail = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.avail:SetPoint("RIGHT", l, "LEFT", COLS[3].x + COLS[3].w - 2, 0)
    l.avail:SetJustifyH("RIGHT")
    l.seen = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.seen:SetPoint("LEFT", COLS[4].x + 2, 0)
    l:SetScript("OnEnter", function(self)
      if not self.row then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local _, link = GetInfo(self.row.id)
      if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetItemByID(self.row.id) end
      GameTooltip:Show()
    end)
    l:SetScript("OnLeave", GameTooltip_Hide)
    l:SetScript("OnClick", function(self)
      local _, link = self.row and GetInfo(self.row.id)
      if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end)
    list.lines[i] = l
  end

  -- scroll bar (mouse wheel works anywhere on the list)
  local scroll = CreateFrame("Slider", nil, list, "BackdropTemplate")
  scroll:SetPoint("TOPRIGHT", -3, -24)
  scroll:SetPoint("BOTTOMRIGHT", -3, 4)
  scroll:SetWidth(12)
  scroll:SetOrientation("VERTICAL")
  scroll:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
  scroll:SetBackdropColor(1, 1, 1, 0.05)
  scroll:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
  local thumb = scroll:GetThumbTexture()
  thumb:SetSize(12, 40)
  thumb:SetVertexColor(1, 0.82, 0, 0.5)
  scroll:SetValueStep(1)
  scroll:SetObeyStepOnDrag(true)
  scroll:SetScript("OnValueChanged", function(self, value)
    if self.ignore then return end
    list.offset = math.floor(value + 0.5)
    RefreshList()
  end)
  list.scroll = scroll
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, self.offset - delta * 3)
    RefreshList()
  end)

  list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  list.empty:SetPoint("TOP", head, "BOTTOM", 0, -20)
  list.empty:SetText("No prices match.")
  win.list = list

  -- loading bar, shown instead of the list until every item's details are in
  local loading = CreateFrame("Frame", nil, win)
  loading:SetPoint("TOPLEFT", 12, -68)
  loading:SetPoint("BOTTOMRIGHT", -12, 12)
  loading.text = loading:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  loading.text:SetPoint("CENTER", 0, 16)
  local bar = CreateFrame("StatusBar", nil, loading, "BackdropTemplate")
  bar:SetSize(320, 14)
  bar:SetPoint("CENTER", 0, -6)
  bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
  bar:SetStatusBarColor(1, 0.82, 0, 0.8)
  bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  bar:SetBackdropColor(0, 0, 0, 0.5)
  bar:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
  loading.bar = bar
  local sub = loading:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOP", bar, "BOTTOM", 0, -6)
  sub:SetText("Only needed once: names are saved for next time.")
  win.loading = loading

  win:SetScript("OnShow", function()
    ns.WarmNames()
    onProgress = function()
      local done, total = ns.NameProgress()
      Refresh(done >= total)
    end
    Refresh(true)
  end)
  win:SetScript("OnHide", function() onProgress = nil end)
  -- prices can change while it's open (a scan, a sync)
  C_Timer.NewTicker(5, function() if win:IsShown() then Refresh(true) end end)
  win:Hide()
end

function ns.TogglePriceList()
  if not win then Build() end
  win:SetShown(not win:IsShown())
end
