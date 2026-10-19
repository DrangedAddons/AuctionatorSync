-- Ways in: a minimap button (LibDBIcon, so minimap-button addons can collect it), the addon list
-- button at the top of the minimap, and an entry under Options > AddOns.
local _, ns = ...

local ICON = "Interface\\AddOns\\AuctionatorSync\\Images\\Icon"
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBI = LibStub and LibStub("LibDBIcon-1.0", true)

----------------------------------------------------------------------------------------------
-- Minimap button: left-click the settings window, right-click the Price List, drag to move

function ns.SetMinimapShown(on)
  ns.db.minimap.hide = not on
  if not DBI then return end
  if on then DBI:Show("AuctionatorSync") else DBI:Hide("AuctionatorSync") end
end

local function SetupMinimap()
  if not (LDB and DBI) then return end
  local launcher = LDB:NewDataObject("AuctionatorSync", {
    type = "launcher",
    text = "AuctionatorSync",
    icon = ICON,
    OnClick = function(_, button)
      if button == "RightButton" then ns.TogglePriceList() else ns.ToggleWindow() end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine("AuctionatorSync")
      tt:AddLine("|cffffd100Left-click|r: settings", 1, 1, 1)
      tt:AddLine("|cffffd100Right-click|r: Price List", 1, 1, 1)
      tt:AddLine("|cffffd100Drag|r to move this button", 1, 1, 1)
    end,
  })
  DBI:Register("AuctionatorSync", launcher, ns.db.minimap)
end

-- The addon list button at the top of the minimap (AddonCompartmentFunc in the .toc).
function AuctionatorSync_OnCompartmentClick(_, button)
  if button == "RightButton" then ns.TogglePriceList() else ns.ToggleWindow() end
end

----------------------------------------------------------------------------------------------
-- Options > AddOns > AuctionatorSync

local function CloseOptions()
  if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
end

local function SetupOptionsPage()
  local panel = CreateFrame("Frame")
  panel.name = "AuctionatorSync"

  local icon = panel:CreateTexture(nil, "ARTWORK")
  icon:SetSize(48, 48)
  icon:SetPoint("TOPLEFT", 16, -16)
  icon:SetTexture(ICON)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -4)
  title:SetText("AuctionatorSync |cff999999v" .. ns.VERSION .. "|r")

  local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetText("Auctionator companion addon - by Dranged")

  local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -16)
  text:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
  text:SetJustifyH("LEFT")
  text:SetSpacing(3)
  text:SetText("- Auction house price sync between players with AuctionatorSync installed.\n"
    .. "- New auction data is synced and shared automatically.\n"
    .. "- Browse the auction house listings at any time (/ah).")

  local settings = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  settings:SetSize(170, 26)
  settings:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -20)
  settings:SetText("Open settings")
  settings:SetScript("OnClick", function()
    CloseOptions()
    if not AuctionatorSyncFrame or not AuctionatorSyncFrame:IsShown() then ns.ToggleWindow() end
  end)

  local prices = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  prices:SetSize(170, 26)
  prices:SetPoint("LEFT", settings, "RIGHT", 10, 0)
  prices:SetText("Open Price List")
  prices:SetScript("OnClick", function()
    CloseOptions()
    if not AuctionatorSyncPriceListFrame or not AuctionatorSyncPriceListFrame:IsShown() then ns.TogglePriceList() end
  end)

  local help = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  help:SetPoint("TOPLEFT", settings, "BOTTOMLEFT", 0, -14)
  help:SetText("Also: /async for settings, /ah for the Price List, the minimap button, or a key under Keybindings > AddOns.")

  if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(panel, "AuctionatorSync")
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

ns.On("PLAYER_LOGIN", function()
  SetupMinimap()
  SetupOptionsPage()
end)
