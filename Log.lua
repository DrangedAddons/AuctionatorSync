-- Verbose mode's log window: what AuctionatorSync is doing and has done (/async log, or the
-- Verbose mode box in /async). Lines come from ns.Log; the last few hundred are kept across
-- /reload. Only you see it.
local _, ns = ...

local win

local function Build()
  win = CreateFrame("Frame", "AuctionatorSyncLogFrame", UIParent, "BackdropTemplate")
  win:SetSize(560, 320)
  win:SetPoint("CENTER", 0, -120)
  win:SetFrameStrata("DIALOG")
  win:SetMovable(true)
  win:SetResizable(true)
  if win.SetResizeBounds then win:SetResizeBounds(360, 160) end
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", ns.DragStart) -- moves its docked group; Alt-drag undocks it
  win:SetScript("OnDragStop", ns.DragStop)
  win:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
  })
  win:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
  win:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  table.insert(UISpecialFrames, "AuctionatorSyncLogFrame")

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText("AuctionatorSync log")

  win.state = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.state:SetPoint("LEFT", title, "RIGHT", 10, 0)

  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  local clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  clear:SetSize(70, 20)
  clear:SetPoint("RIGHT", close, "LEFT", -4, 0)

  -- the Sync Monitor, docked to this log when the settings window isn't open
  local monitor = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  monitor:SetSize(100, 20)
  monitor:SetPoint("RIGHT", clear, "LEFT", -4, 0)
  monitor:SetText("Sync Monitor")
  monitor:SetScript("OnClick", function()
    local settingsOpen = AuctionatorSyncFrame and AuctionatorSyncFrame:IsShown()
    ns.ToggleMonitor(not settingsOpen and win or nil)
  end)
  clear:SetText("Clear")
  clear:SetScript("OnClick", function()
    wipe(ns.store.log)
    win.lines:Clear()
  end)

  local lines = CreateFrame("ScrollingMessageFrame", nil, win)
  lines:SetPoint("TOPLEFT", 12, -34)
  lines:SetPoint("BOTTOMRIGHT", -12, 12)
  lines:SetFontObject(GameFontHighlightSmall)
  lines:SetJustifyH("LEFT")
  lines:SetFading(false)
  lines:SetMaxLines(500)
  lines:SetInsertMode("BOTTOM")
  lines:EnableMouseWheel(true)
  lines:SetScript("OnMouseWheel", function(self, delta)
    if IsShiftKeyDown() then
      if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
    elseif delta > 0 then
      self:ScrollUp()
    else
      self:ScrollDown()
    end
  end)
  win.lines = lines

  -- drag the bottom-right corner to resize
  local grip = CreateFrame("Button", nil, win)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing() end)

  win:SetScript("OnShow", function()
    win.state:SetText(ns.db.verbose and "|cff33ff99recording|r"
      or "|cffff9966not recording (Verbose mode is off)|r")
    lines:Clear()
    for _, line in ipairs(ns.store.log) do lines:AddMessage(line) end
    lines:ScrollToBottom()
  end)
  win:Hide()
end

function ns.OnLogLine(line)
  if win and win:IsShown() then win.lines:AddMessage(line) end
end

function ns.ShowLog(show)
  if not win then Build() end
  if show then
    -- dock beside whichever AuctionatorSync windows are open, without overlapping
    if not win:IsShown() then ns.PlaceWindow(win) end
    if win:IsShown() then win:GetScript("OnShow")() else win:Show() end
  else
    win:Hide()
  end
end

function ns.ToggleLog()
  if not win then Build() end
  ns.ShowLog(not win:IsShown())
end
