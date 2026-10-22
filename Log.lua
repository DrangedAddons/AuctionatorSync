-- The log: the bottom part of the Sync Monitor window (Monitor.lua builds the window and places
-- this under the monitor rows, moving it down as they grow). Lines come from ns.Log while Verbose
-- mode is on; the last few hundred are kept across /reload. Only you see it.
local _, ns = ...

local section
local LOG_MIN, LOG_MAX, LOG_DEFAULT = 100, 600, 220

function ns.LogHeight()
  return math.max(LOG_MIN, math.min(LOG_MAX, (ns.db and ns.db.logHeight) or LOG_DEFAULT))
end

-- win: the monitor window; relayout: called when the log's height changes (grip drag)
function ns.BuildLogSection(win, relayout)
  section = CreateFrame("Frame", nil, win)
  section:SetHeight(ns.LogHeight())

  local divider = section:CreateTexture(nil, "ARTWORK")
  divider:SetPoint("TOPLEFT", 4, 0)
  divider:SetPoint("TOPRIGHT", -4, 0)
  divider:SetHeight(1)
  divider:SetColorTexture(1, 0.82, 0, 0.35)

  local title = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -8)
  title:SetText("Log")

  section.state = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  section.state:SetPoint("LEFT", title, "RIGHT", 10, 0)

  local clear = CreateFrame("Button", nil, section, "UIPanelButtonTemplate")
  clear:SetSize(70, 20)
  clear:SetPoint("TOPRIGHT", -10, -4)
  clear:SetText("Clear")
  clear:SetScript("OnClick", function()
    wipe(ns.store.log)
    section.lines:Clear()
  end)

  local lines = CreateFrame("ScrollingMessageFrame", nil, section)
  lines:SetPoint("TOPLEFT", 12, -30)
  lines:SetPoint("BOTTOMRIGHT", -12, 14)
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
  section.lines = lines

  -- bottom-right grip: drag to make the log taller or shorter (remembered)
  local grip = CreateFrame("Button", nil, section)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  local function CursorY()
    local _, y = GetCursorPosition()
    return y / UIParent:GetEffectiveScale()
  end
  grip:SetScript("OnMouseDown", function(self)
    self.startY, self.startH = CursorY(), ns.LogHeight()
    self:SetScript("OnUpdate", function(g)
      local h = math.max(LOG_MIN, math.min(LOG_MAX, g.startH + (g.startY - CursorY())))
      if h ~= ns.db.logHeight then
        ns.db.logHeight = h
        section:SetHeight(h)
        relayout()
      end
    end)
  end)
  grip:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)

  return section
end

-- Reload the lines from the saved log (when the window opens) and update the recording note.
function ns.RefreshLogSection(reload)
  if not section then return end
  section.state:SetText(ns.db.verbose and "|cff33ff99recording|r"
    or "|cffff9966not recording (Verbose mode is off)|r")
  if reload then
    section.lines:Clear()
    for _, line in ipairs(ns.store.log) do section.lines:AddMessage(line) end
    section.lines:ScrollToBottom()
  end
end

function ns.OnLogLine(line)
  if section and section:IsVisible() then section.lines:AddMessage(line) end
end

-- The log lives in the Sync Monitor now.
function ns.ShowLog(show) ns.ShowMonitor(show) end
function ns.ToggleLog() ns.ToggleMonitor() end
