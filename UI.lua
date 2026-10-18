-- /async window: settings, Sync now, and who's online with AuctionatorSync.
local _, ns = ...

local frame

local OPTIONS = {
  { key = "guild", label = "Sync with my guild" },
  { key = "friends", label = "Sync with my friends list" },
  { key = "bnet", label = "Sync with Battle.net friends on this realm" },
  { key = "shareScans", label = "Share my scans automatically" },
  { key = "catchUpOnLogin", label = "Catch up on prices I missed when I log in" },
  { key = "announce", label = "Show chat messages",
    tip = "Sign-in and sync messages in chat. Replies to /async commands and Sync now always show." },
}

local function Ago(ts)
  local s = ns.Now() - (ts or 0)
  if s < 60 then return "just now" end
  if s < 3600 then return floor(s / 60) .. "m ago" end
  return floor(s / 3600) .. "h ago"
end

local VIA = { guild = "Guild", friend = "Friend", bnet = "Battle.net" }

local function Refresh()
  if not frame or not frame:IsShown() then return end
  for _, cb in ipairs(frame.checks) do cb:SetChecked(ns.db[cb.key] and true or false) end

  local lines = {}
  for _, peer in pairs(ns.peers) do
    local line = string.format("%s  |cff999999%s · v%s · %s|r", peer.name, VIA[peer.via] or peer.via,
      tostring(peer.version), Ago(peer.lastSeen))
    if peer.otherRealm then line = line .. "  |cffff9966(other realm/faction)|r" end
    lines[#lines + 1] = line
  end
  table.sort(lines)
  frame.peers:SetText(#lines > 0 and table.concat(lines, "\n")
    or "|cff999999No one else with AuctionatorSync seen yet.|r")

  local realm = ns.store.realms[ns.RealmKey() or ""]
  local last = realm and realm.lastCatchUp or 0
  frame.status:SetText(string.format("Realm: %s\nLast catch-up: %s", tostring(ns.RealmKey() or "?"),
    last > 0 and date("%d %b %H:%M", last) or "never"))
end

local function Build()
  frame = CreateFrame("Frame", "AuctionatorSyncFrame", UIParent, "BackdropTemplate")
  frame:SetSize(380, 420)
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

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("LEFT", sync, "RIGHT", 12, 0)
  frame.status:SetJustifyH("LEFT")

  local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header:SetPoint("TOPLEFT", 16, y - 48)
  header:SetText("Online with AuctionatorSync")

  frame.peers = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.peers:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  frame.peers:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  frame.peers:SetJustifyH("LEFT")
  frame.peers:SetJustifyV("TOP")
  frame.peers:SetSpacing(3)

  frame:SetScript("OnShow", Refresh)
  C_Timer.NewTicker(5, Refresh)
end

function ns.ToggleWindow()
  if not frame then Build() end
  frame:SetShown(not frame:IsShown())
  Refresh()
end
