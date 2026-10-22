-- Sync Monitor: a torrent-client style view of who is syncing right now, with the log underneath
-- (Log.lua builds that part; it moves down as the rows above it grow).
--   top:    the master list (short fingerprint, prices, newest price) and how many are online
--   rows:   only players doing something right now - handshaking (with how many hosts, toward
--           which master list), receiving updates, sharing a scan, hosting others - with a
--           progress bar
--   below:  this character's own transfers in detail (pieces and batches)
--   footer: everyone else, compacted: in sync / not in sync yet / can't sync (old version)
local _, ns = ...

local win
local floor = math.floor
local ROW_H, MAX_ROWS, MAX_DETAIL = 20, 10, 6
local COLS = {
  { key = "name", label = "Player", x = 8 },
  { key = "activity", label = "Activity", x = 140 },
  { key = "amount", label = "Amount", x = 300 },
  { key = "progress", label = "Progress", x = 410 },
  { key = "hosts", label = "Hosts", x = 520 },
  { key = "hosting", label = "Hosting", x = 566 },
  { key = "target", label = "Syncing to", x = 628 },
}

local function Short(fp) return fp and tostring(fp):sub(1, 8) or "-" end

local function Ago(ts)
  if not ts then return "?" end
  local s = ns.Now() - ts
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

-- One player's activity: { name, activity, amount, progress, hosts, hosting, target, color }, or
-- nil when idle. The first of handshaking / receiving / sharing / hosting is the main activity
-- (its x / y goes in the Amount column); any others are added after it.
-- p: { st, pg, hs, hd, ht, ra, rt, sa, st2, hc, tg, hl, rx }
local function Amount(done, total)
  if not total or total <= 0 then return nil end
  return ns.Num(done or 0) .. " / " .. ns.Num(total)
end

local function Activity(name, p, master)
  local parts, amount, progress, color = {}, nil, nil, "ffd100"
  if p.st == "syncing" then
    parts[#parts + 1] = "Handshaking" .. (p.hs and (": " .. p.hs) or "")
    amount = Amount(p.hd, p.ht)
    progress = p.pg or 0
  elseif p.st == "waiting" then
    parts[#parts + 1] = "Looking for hosts"
  end
  if (p.rt or 0) > 0 or (p.rx or 0) > 0 then
    parts[#parts + 1] = "Receiving"
    if not amount then amount = Amount(p.ra, p.rt) end
    if not progress and (p.rt or 0) > 0 then progress = floor((p.ra or 0) / p.rt * 100) end
  end
  if (p.st2 or 0) > 0 then
    parts[#parts + 1] = "Sharing"
    if not amount then amount = Amount(p.sa, p.st2) end
    if not progress then progress = floor((p.sa or 0) / p.st2 * 100) end
  end
  if (p.hl or 0) > 0 then
    parts[#parts + 1] = "Hosting"
    if #parts == 1 then color = "33ff99" end -- only hosting: it's in sync, serving others
  end
  if #parts == 0 then return nil end
  return { name = name, activity = table.concat(parts, " + "), amount = amount, progress = progress, hosts = p.hc,
    hosting = (p.hl or 0) > 0 and p.hl or nil, target = p.tg or (p.st == "syncing" and master) or nil, color = color }
end

local function Gather()
  local master = ns.Master()
  local active, inSync, behind, old = {}, {}, {}, {}
  local ra, rt = ns.ReceiveAmounts()
  local sa, st2 = ns.SendAmounts()
  local mine = Activity(ns.MyName(), { st = ns.state, pg = ns.syncProgress, hs = ns.syncStep, hd = ns.syncDone,
    ht = ns.syncTotal, ra = ra, rt = rt, sa = sa, st2 = st2, hc = ns.MyHostsCount(), tg = ns.MyTarget(),
    hl = ns.HostingCount(), rx = ns.Receiving() }, master)
  if mine then
    mine.me = true
    active[#active + 1] = mine
  elseif ns.Fingerprint() == master then
    inSync[#inSync + 1] = ns.MyName()
  else
    behind[#behind + 1] = ns.MyName()
  end
  for _, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) and not peer.otherRealm then
      if not ns.IsCompatible(peer) then
        old[#old + 1] = peer.name .. " (v" .. tostring(peer.version) .. ")"
      else
        local a = Activity(peer.name, peer, master)
        if a then
          active[#active + 1] = a
        elseif peer.d == master then
          inSync[#inSync + 1] = peer.name
        else
          behind[#behind + 1] = peer.name
        end
      end
    end
  end
  table.sort(active, function(x, y) return x.name < y.name end)
  table.sort(inSync)
  table.sort(behind)
  table.sort(old)
  return active, inSync, behind, old, master
end

local function DetailLines()
  local lines = {}
  for _, p in ipairs(ns.Pieces()) do
    local pct = p.done and 100 or (p.tot and p.tot > 0 and math.floor(p.got / p.tot * 100)) or 0
    lines[#lines + 1] = string.format("|cff99ff99<<|r piece from %s: %d sections, %s%s", p.host, p.sections,
      p.tot and (ns.Num(p.got) .. " / " .. ns.Num(p.tot) .. " prices") or "waiting for their reply",
      p.done and "  |cff33ff99done|r" or ("  " .. pct .. "%"))
  end
  for _, t in ipairs(ns.MyTransfers()) do
    local pct = t.tot > 0 and math.floor(t.done / t.tot * 100) or 0
    local secs = math.max(1, ns.Now() - (t.started or ns.Now()))
    local rate = t.done / secs
    local eta = rate > 0 and math.floor((t.tot - t.done) / rate) or nil
    lines[#lines + 1] = string.format("%s %s %s: %s / %s prices  %d%%%s",
      t.dir == "out" and "|cff66ccff>>|r" or "|cff99ff99<<|r", t.dir == "out" and "to" or "from", t.who or "?",
      ns.Num(t.done), ns.Num(t.tot), pct, eta and eta > 0 and ("  ~" .. eta .. "s left") or "")
    lines[#lines]= lines[#lines] .. "  |cff999999" .. (ns.KIND_WORDS[t.kind] or "scan prices") .. "|r"
  end
  return lines
end

local function Refresh()
  if not win or not win:IsShown() then return end
  local active, inSync, behind, old, master = Gather()
  local online = #active + #inSync + #behind + #old
  local count = tonumber(ns.Fingerprint():match("%-(%d+)$")) or 0
  win.summary:SetText(string.format("Master list |cffffffff%s|r  -  %s here  -  newest price %s  -  %s online",
    Short(master), ns.Plural(count, "price"), Ago(ns.NewestPrice() > 0 and ns.NewestPrice() or nil), ns.Num(online)))

  -- active rows
  for i = 1, MAX_ROWS do
    local row, a = win.rows[i], active[i]
    if a then
      row.name:SetText(a.name .. (a.me and " |cff999999(you)|r" or ""))
      row.activity:SetText("|cff" .. a.color .. a.activity .. "|r")
      row.amount:SetText(a.amount or "|cff666666-|r")
      if a.progress then
        row.bar:Show()
        row.bar:SetValue(a.progress)
        row.bar.text:SetText(a.progress .. "%")
      else
        row.bar:Hide()
      end
      row.hosts:SetText(a.hosts and tostring(a.hosts) or "|cff666666-|r")
      row.hosting:SetText(a.hosting and tostring(a.hosting) or "|cff666666-|r")
      row.target:SetText(a.target and Short(a.target) or "|cff666666-|r")
      row:Show()
    else
      row:Hide()
    end
  end
  win.none:SetShown(#active == 0)
  local shown = math.max(1, math.min(#active, MAX_ROWS))

  -- this character's own transfers
  local detail = DetailLines()
  for i = 1, MAX_DETAIL do
    local fs = win.detail[i]
    fs:SetText(detail[i] or "")
    fs:SetShown(detail[i] ~= nil)
  end
  local detailShown = math.min(#detail, MAX_DETAIL)
  win.detailHeader:SetShown(detailShown > 0)

  -- compact footer
  local foot = {}
  if #inSync > 0 then foot[#foot + 1] = string.format("|cff33ff99In sync (%d):|r %s", #inSync, table.concat(inSync, ", ")) end
  if #behind > 0 then foot[#foot + 1] = string.format("|cffff5555Not in sync yet (%d):|r %s", #behind, table.concat(behind, ", ")) end
  if #old > 0 then foot[#foot + 1] = string.format("|cff808080Can't sync, old version (%d):|r %s", #old, table.concat(old, ", ")) end
  local bench = {}
  for _, b in ipairs(ns.BenchedHosts()) do bench[#bench + 1] = string.format("%s (%dm)", b.name, math.ceil(b.left / 60)) end
  if #bench > 0 then
    foot[#foot + 1] = string.format("|cffff9966Benched as host (stalled or didn't answer):|r %s", table.concat(bench, ", "))
  end
  win.footer:SetText(table.concat(foot, "\n"))

  -- lay out the lower parts under however many rows there are
  local y = -66 - shown * ROW_H - 8
  win.detailHeader:ClearAllPoints()
  win.detailHeader:SetPoint("TOPLEFT", 12, y)
  if detailShown > 0 then y = y - 16 end
  for i = 1, MAX_DETAIL do
    win.detail[i]:ClearAllPoints()
    win.detail[i]:SetPoint("TOPLEFT", 20, y - (i - 1) * 14)
  end
  y = y - detailShown * 14 - (detailShown > 0 and 8 or 0)
  win.footer:ClearAllPoints()
  win.footer:SetPoint("TOPLEFT", 12, y)
  win.footer:SetPoint("RIGHT", win, "RIGHT", -12, 0)
  y = y - win.footer:GetStringHeight() - 10

  -- the log, right under it
  win.log:ClearAllPoints()
  win.log:SetPoint("TOPLEFT", win, "TOPLEFT", 0, y)
  win.log:SetPoint("RIGHT", win, "RIGHT")
  win:SetHeight(-y + ns.LogHeight())
  ns.RefreshLogSection(false)
end

local function Build()
  win = CreateFrame("Frame", "AuctionatorSyncMonitorFrame", UIParent, "BackdropTemplate")
  win:SetSize(700, 200)
  win:SetPoint("CENTER", 0, 150)
  win:SetFrameStrata("DIALOG")
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", ns.DragStart) -- moves its docked group; Alt-drag undocks it
  win:SetScript("OnDragStop", ns.DragStop)
  win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  win:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
  win:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  table.insert(UISpecialFrames, "AuctionatorSyncMonitorFrame")

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText("Sync Monitor")
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  win.summary = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.summary:SetPoint("TOPLEFT", 12, -30)
  win.summary:SetTextColor(0.75, 0.75, 0.75)

  -- column headings
  local head = CreateFrame("Frame", nil, win)
  head:SetPoint("TOPLEFT", 4, -46)
  head:SetPoint("TOPRIGHT", -4, -46)
  head:SetHeight(18)
  for _, col in ipairs(COLS) do
    local fs = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", col.x, 0)
    fs:SetText(col.label)
  end
  local line = head:CreateTexture(nil, "ARTWORK")
  line:SetPoint("BOTTOMLEFT", 0, -1)
  line:SetPoint("BOTTOMRIGHT", 0, -1)
  line:SetHeight(1)
  line:SetColorTexture(1, 0.82, 0, 0.35)

  win.rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, win)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2 - (i - 1) * ROW_H)
    row:SetPoint("RIGHT", head, "RIGHT")
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.05 or 0)
    for _, col in ipairs(COLS) do
      if col.key ~= "progress" then
        local fs = row:CreateFontString(nil, "OVERLAY", col.key == "name" and "GameFontHighlight" or "GameFontHighlightSmall")
        fs:SetPoint("LEFT", col.x, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row[col.key] = fs
      end
    end
    row.name:SetWidth(COLS[2].x - COLS[1].x - 6)
    row.activity:SetWidth(COLS[3].x - COLS[2].x - 6)
    row.amount:SetWidth(COLS[4].x - COLS[3].x - 6)
    local bar = CreateFrame("StatusBar", nil, row, "BackdropTemplate")
    bar:SetSize(COLS[5].x - COLS[4].x - 10, 12)
    bar:SetPoint("LEFT", COLS[4].x, 0)
    bar:SetMinMaxValues(0, 100)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(0.2, 0.6, 1, 0.85)
    bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    bar:SetBackdropColor(0, 0, 0, 0.5)
    bar:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")
    row.bar = bar
    win.rows[i] = row
  end
  win.none = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  win.none:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 8, -5)
  win.none:SetText("Nobody is syncing right now.")

  win.detailHeader = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  win.detailHeader:SetText("Transfers on this character")
  win.detail = {}
  for i = 1, MAX_DETAIL do
    local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    win.detail[i] = fs
  end

  win.footer = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.footer:SetJustifyH("LEFT")
  win.footer:SetSpacing(2)

  win.log = ns.BuildLogSection(win, function() Refresh() end)

  win:SetScript("OnShow", function()
    ns.RefreshLogSection(true)
    Refresh()
  end)
  C_Timer.NewTicker(1, Refresh)
  win:Hide()
end

function ns.ShowMonitor(show)
  if not win then Build() end
  if show then
    if not win:IsShown() then
      -- stays where it was, unless that's on top of another open window: then it moves to a free
      -- spot beside it (not attached)
      ns.PlaceWindow(win, nil, true)
      win:Show()
    end
    Refresh()
  else
    win:Hide()
  end
end

function ns.ToggleMonitor()
  if not win then Build() end
  ns.ShowMonitor(not win:IsShown())
end
