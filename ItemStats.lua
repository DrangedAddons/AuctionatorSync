-- Gear stats and slots for the Price List's Filter > Slot / Stats / Sort by stat, the same lists
-- CraftRoute's filter has. Stats are read from the item's own tooltip text (so "Equip:" lines like
-- spell damage count too), once per item, and only for gear and bags.
local _, ns = ...

-- { key, label, group }, in menu order
ns.STATS = {
  { "sta", "Stamina", "Attributes" }, { "str", "Strength", "Attributes" }, { "agi", "Agility", "Attributes" },
  { "int", "Intellect", "Attributes" }, { "spi", "Spirit", "Attributes" },
  { "heal", "Healing", "Spell" }, { "spell", "Spell damage", "Spell" },
  { "fire", "Fire damage", "Spell" }, { "frost", "Frost damage", "Spell" },
  { "shadow", "Shadow damage", "Spell" }, { "nature", "Nature damage", "Spell" },
  { "arcane", "Arcane damage", "Spell" }, { "holy", "Holy damage", "Spell" },
  { "scrit", "Spell crit %", "Spell" }, { "shit", "Spell hit %", "Spell" }, { "mp5", "Mana per 5 sec", "Spell" },
  { "ap", "Attack power", "Physical" }, { "rap", "Ranged attack power", "Physical" },
  { "crit", "Crit %", "Physical" }, { "hit", "Hit %", "Physical" },
  { "armor", "Armor", "Defense" }, { "def", "Defense", "Defense" }, { "dodge", "Dodge %", "Defense" },
  { "parry", "Parry %", "Defense" }, { "block", "Block", "Defense" }, { "hp5", "Health per 5 sec", "Defense" },
  { "rfire", "Fire", "Resistances" }, { "rfrost", "Frost", "Resistances" }, { "rnature", "Nature", "Resistances" },
  { "rshadow", "Shadow", "Resistances" }, { "rarcane", "Arcane", "Resistances" },
  { "slots", "Bag slots", "Bags" },
}

-- "Healing", "Fire resistance": a stat's name on its own
function ns.StatLabel(key)
  for _, s in ipairs(ns.STATS) do
    if s[1] == key then return s[3] == "Resistances" and (s[2] .. " resistance") or s[2] end
  end
  return key
end

----------------------------------------------------------------------------------------------
-- Slots: the item's equip location, with robes counted as chest and wands/guns as ranged.

local SAME_SLOT = { INVTYPE_ROBE = "INVTYPE_CHEST", INVTYPE_RANGEDRIGHT = "INVTYPE_RANGED" }
ns.SLOT_ORDER = {
  "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_CLOAK", "INVTYPE_CHEST", "INVTYPE_BODY",
  "INVTYPE_TABARD", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET",
  "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_WEAPON", "INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND",
  "INVTYPE_2HWEAPON", "INVTYPE_SHIELD", "INVTYPE_HOLDABLE", "INVTYPE_RANGED", "INVTYPE_THROWN",
  "INVTYPE_RELIC", "INVTYPE_AMMO", "INVTYPE_BAG", "INVTYPE_QUIVER",
}

function ns.SlotOf(equipLoc)
  if type(equipLoc) ~= "string" or equipLoc == "" or equipLoc:find("NON_EQUIP") then return nil end
  return SAME_SLOT[equipLoc] or equipLoc
end

function ns.SlotLabel(slot)
  local label = _G[slot]
  if type(label) == "string" and label ~= "" then return label end
  return (slot:gsub("^INVTYPE_", ""):lower():gsub("^%l", string.upper))
end

----------------------------------------------------------------------------------------------
-- Reading stats from tooltip lines (lower-cased). Same wording rules as CraftRoute's Search.lua.

local PRIMARY = { stamina = "sta", strength = "str", agility = "agi", intellect = "int", spirit = "spi",
  defense = "def" }
local SCHOOL = { fire = true, frost = true, shadow = true, nature = true, arcane = true, holy = true }

local function Add(t, k, v)
  v = tonumber(v)
  if k and v then t[k] = (t[k] or 0) + v end
end

local function ParseLine(t, l)
  local n, w = l:match("^%+(%d+) (%a+)$")
  if n and PRIMARY[w] then Add(t, PRIMARY[w], n) return end
  n, w = l:match("^%+?(%d+) (%a+) resistance")
  if n then Add(t, "r" .. w, n) return end
  n = l:match("^(%d+) armor$") if n then Add(t, "armor", n) return end
  n = l:match("^(%d+) block$") if n then Add(t, "block", n) return end
  n = l:match("^(%d+) slot") if n then Add(t, "slots", n) return end
  if not l:find("^equip:") then return end
  n = l:match("damage and healing done by magical spells and effects by up to (%d+)")
  if n then Add(t, "heal", n) Add(t, "spell", n) return end
  n = l:match("healing done by up to (%d+)") or l:match("healing done by spells and effects by up to (%d+)")
  if n then Add(t, "heal", n) end
  n = l:match("and damage done by up to (%d+)")
  if n then Add(t, "spell", n) end
  local school
  school, n = l:match("damage done by (%a+) spells and effects by up to (%d+)")
  if school and SCHOOL[school] then Add(t, school, n) end
  Add(t, "mp5", l:match("restores (%d+) mana per 5"))
  Add(t, "hp5", l:match("restores (%d+) health per 5"))
  if l:find("critical strike with spells") then Add(t, "scrit", l:match("by (%d+)%%"))
  elseif l:find("critical strike") then Add(t, "crit", l:match("by (%d+)%%")) end
  if l:find("hit with spells") then Add(t, "shit", l:match("by (%d+)%%"))
  elseif l:find("chance to hit") then Add(t, "hit", l:match("by (%d+)%%")) end
  Add(t, "rap", l:match("%+(%d+) ranged attack power"))
  if not l:find("ranged attack power") then Add(t, "ap", l:match("%+(%d+) attack power")) end
  Add(t, "def", l:match("increased defense %+(%d+)"))
  Add(t, "dodge", l:match("chance to dodge an attack by (%d+)%%"))
  Add(t, "parry", l:match("chance to parry an attack by (%d+)%%"))
  Add(t, "block", l:match("block value of your shield by (%d+)"))
end

local function Clean(text)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return (text:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The item's tooltip lines as plain text, or nil if the game hasn't got them yet.
local scanTip
local function TooltipLines(id)
  local lines = {}
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local ok, data = pcall(C_TooltipInfo.GetItemByID, id)
    if ok and data and type(data.lines) == "table" then
      for _, line in ipairs(data.lines) do
        if type(line.leftText) == "string" then lines[#lines + 1] = line.leftText end
      end
    end
  else
    if not scanTip then
      scanTip = CreateFrame("GameTooltip", "AuctionatorSyncScanTip", UIParent, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetItemByID(id)
    for i = 1, scanTip:NumLines() do
      local fs = _G["AuctionatorSyncScanTipTextLeft" .. i]
      local text = fs and fs:GetText()
      if text then lines[#lines + 1] = text end
    end
    scanTip:Hide()
  end
  if #lines < 2 then return nil end -- only the name: the item's data isn't in yet
  return lines
end

local NONE = {}
local cache = {} -- itemID -> { stat = value }

-- row: a Price List row ({ id, slot, classID }). Gear and bags only; anything else has no stats.
function ns.ItemStatsOf(row)
  if not row.slot and row.classID ~= 1 then return NONE end
  local t = cache[row.id]
  if t then return t end
  local lines = TooltipLines(row.id)
  if not lines then return NONE end -- try again next time
  t = {}
  for _, l in ipairs(lines) do ParseLine(t, Clean(l)) end
  cache[row.id] = t
  return t
end

----------------------------------------------------------------------------------------------
-- Bag and quiver slot counts, for the Price List's slot-count level under Container and Quiver.
-- From Wowhead Forever (items/containers and items/quivers, 22 Nov 2026). Anything not listed
-- (a bag added later) is read from its tooltip ("18 Slot Bag").
local BAG_SLOTS = {
  [804]=10, [805]=6, [828]=6, [856]=8, [857]=10, [918]=10, [932]=10, [933]=10, [1470]=10, [1537]=8,
  [1623]=12, [1652]=12, [1685]=14, [1725]=12, [1729]=10, [1977]=20, [2082]=8, [2657]=8, [3233]=8,
  [3343]=8, [3352]=10, [3762]=12, [3914]=14, [4238]=6, [4240]=8, [4241]=10, [4245]=10, [4496]=6,
  [4497]=10, [4498]=8, [4499]=12, [4500]=16, [4930]=6, [4957]=6, [4981]=12, [5081]=6, [5571]=6,
  [5572]=6, [5573]=8, [5574]=8, [5575]=10, [5576]=10, [5603]=8, [5762]=8, [5763]=10, [5764]=12,
  [5765]=12, [6446]=10, [6754]=8, [6756]=6, [9587]=14, [10050]=12, [10051]=14, [10683]=16,
  [10959]=16, [11324]=14, [11742]=16, [11845]=6, [13330]=18, [14046]=14, [14155]=18, [14156]=20,
  [16057]=12, [17966]=18, [19291]=14, [19914]=18, [20400]=16, [21193]=30, [21194]=32, [21195]=36,
  [21313]=12, [21340]=24, [21341]=32, [21342]=28, [22233]=16, [22243]=14, [22244]=16, [22246]=20,
  [22248]=26, [22249]=32, [22250]=12, [22251]=26, [22252]=32, [22679]=18, [221498]=12, [226697]=16,
  [239147]=24, [239148]=30, [242709]=48, [253391]=32, [253664]=6, [253667]=8, [253973]=10,
  [254035]=12, [254079]=14, [254133]=18, [254139]=20, [256935]=6, [260307]=18, [262801]=18,
  [267283]=26, [269504]=14, [270017]=10, [276891]=12, [276892]=10, [277113]=4, [277114]=4,
  [277115]=4, [277200]=6, [277332]=8, [277715]=6, [277845]=40, [277977]=6, [279271]=30, [279936]=6,
  [279939]=6, [280088]=6, [282015]=6, [282016]=8, [282017]=10, [282286]=6, [287962]=10, [287971]=8,
  -- quivers and ammo pouches
  [2101]=6, [2102]=6, [2662]=16, [2663]=16, [3573]=10, [3574]=10, [3604]=12, [3605]=12, [5439]=8,
  [5441]=8, [7278]=8, [7279]=8, [7371]=14, [7372]=14, [8217]=16, [8218]=16, [11362]=10, [11363]=10,
  [18714]=18, [19319]=16, [19320]=16, [274926]=14, [286734]=10,
}

local slotCache = {}
-- Slot count of a bag or quiver (nil if unknown yet: its tooltip hasn't loaded).
function ns.BagSlotsOf(id)
  if BAG_SLOTS[id] then return BAG_SLOTS[id] end
  if slotCache[id] ~= nil then return slotCache[id] or nil end
  local lines = TooltipLines(id)
  if not lines then return nil end
  local n
  for _, l in ipairs(lines) do
    n = tonumber(Clean(l):match("^(%d+) slot"))
    if n then break end
  end
  slotCache[id] = n or false
  return n
end
