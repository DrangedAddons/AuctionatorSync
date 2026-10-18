-- Transport: guild channel, whispers to friends-list friends, and Battle.net game data.
-- Every logical message is an encoded table split into chunks "<id>:<part>:<total>:<data>".
local _, ns = ...

local CTL = ChatThrottleLib
local CHUNK_ADDON = 240   -- addon messages are capped at 255 bytes
local CHUNK_BNET = 4000   -- BNSendGameData allows ~4KB
local REASSEMBLY_TIMEOUT = 300

ns.peers = {}     -- short name -> { name, via = "guild"|"friend"|"bnet", bnID, version, lastSeen }
local guildSet, friendSet = {}, {}

----------------------------------------------------------------------------------------------
-- Who we trust: guild members, friends-list friends, Battle.net friends on this realm.

function ns.RefreshRosters()
  wipe(guildSet)
  if IsInGuild() and GetNumGuildMembers then
    for i = 1, GetNumGuildMembers() do
      local name = GetGuildRosterInfo(i)
      if name then guildSet[ns.ShortName(name)] = true end
    end
  end
  wipe(friendSet)
  if C_FriendList and C_FriendList.GetNumFriends then
    for i = 1, C_FriendList.GetNumFriends() do
      local info = C_FriendList.GetFriendInfoByIndex(i)
      if info and info.name then friendSet[ns.ShortName(info.name)] = info end
    end
  end
end

function ns.IsGuildMember(name) return guildSet[ns.ShortName(name)] == true end
function ns.IsFriend(name) return friendSet[ns.ShortName(name)] ~= nil end

-- Online Battle.net friends in this game, on this realm: { {id, name}, ... }
function ns.BNetFriendsHere()
  local list = {}
  if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return list end
  local realm = GetRealmName()
  local _, numOnline = BNGetNumFriends()
  for i = 1, numOnline or 0 do
    local acc = C_BattleNet.GetFriendAccountInfo(i)
    local g = acc and acc.gameAccountInfo
    if g and g.isOnline and g.gameAccountID and g.characterName
      and (not BNET_CLIENT_WOW or g.clientProgram == BNET_CLIENT_WOW)
      and (not WOW_PROJECT_ID or not g.wowProjectID or g.wowProjectID == WOW_PROJECT_ID)
      and (not g.realmName or g.realmName == realm) then
      table.insert(list, { id = g.gameAccountID, name = g.characterName })
    end
  end
  return list
end

local function BNetNameFor(id)
  local info = C_BattleNet and C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetGameAccountInfoByID(id)
  return info and info.characterName
end

----------------------------------------------------------------------------------------------
-- Sending

local msgCounter = 0
local function NextId()
  msgCounter = msgCounter + 1
  return string.format("%x%x", math.random(0, 255), msgCounter)
end

-- target = { kind = "GUILD" } | { kind = "WHISPER", name = "Bob" } | { kind = "BN", id = 123 }
function ns.Send(target, msg, prio)
  if not target then return end
  msg.v = ns.VERSION
  msg.p = ns.PROTOCOL
  local text = ns.Encode(msg)
  if not text then return end
  local size = target.kind == "BN" and CHUNK_BNET or CHUNK_ADDON
  local total = math.ceil(#text / size)
  local id = NextId()
  prio = prio or "NORMAL"
  for i = 1, total do
    local chunk = id .. ":" .. i .. ":" .. total .. ":" .. text:sub((i - 1) * size + 1, i * size)
    if target.kind == "BN" then
      CTL:BNSendGameData(prio, ns.PREFIX, chunk, "WHISPER", target.id, "AucSync" .. target.id)
    elseif target.kind == "WHISPER" then
      CTL:SendAddonMessage(prio, ns.PREFIX, chunk, "WHISPER", target.name, "AucSync" .. target.name)
    else
      CTL:SendAddonMessage(prio, ns.PREFIX, chunk, "GUILD", nil, "AucSyncGuild")
    end
  end
  ns.Debug("sent %s to %s (%d part%s)", tostring(msg.t), target.name or tostring(target.id or "guild"),
    total, total == 1 and "" or "s")
end

-- Everyone we might reach, for HELLO (we don't know yet who has the addon).
function ns.AllTargets()
  local list, seen = {}, {}
  if ns.db.guild and IsInGuild() then
    table.insert(list, { kind = "GUILD" })
  end
  if ns.db.friends then
    for short, info in pairs(friendSet) do
      if info.connected and not (ns.db.guild and guildSet[short]) then
        seen[short] = true
        table.insert(list, { kind = "WHISPER", name = info.name })
      end
    end
  end
  if ns.db.bnet then
    for _, f in ipairs(ns.BNetFriendsHere()) do
      local short = ns.ShortName(f.name)
      if not seen[short] and not (ns.db.guild and guildSet[short]) then
        table.insert(list, { kind = "BN", id = f.id, name = f.name })
      end
    end
  end
  return list
end

-- Peers known to run AuctionatorSync: one guild message covers every guild peer.
function ns.PeerTargets()
  local list, guildDone = {}, false
  for _, peer in pairs(ns.peers) do
    if peer.via == "guild" then
      if not guildDone and ns.db.guild and IsInGuild() then
        guildDone = true
        table.insert(list, { kind = "GUILD" })
      end
    elseif peer.via == "bnet" then
      if ns.db.bnet and peer.bnID then table.insert(list, { kind = "BN", id = peer.bnID, name = peer.name }) end
    elseif ns.db.friends then
      table.insert(list, { kind = "WHISPER", name = peer.name })
    end
  end
  return list
end

-- Where to answer a peer directly.
function ns.ReplyTarget(peer)
  if peer.via == "bnet" and peer.bnID then return { kind = "BN", id = peer.bnID, name = peer.name } end
  return { kind = "WHISPER", name = peer.name }
end

----------------------------------------------------------------------------------------------
-- Receiving

local buffers = {}

local function Reassemble(key, text)
  local id, part, total, data = text:match("^(%x+):(%d+):(%d+):(.*)$")
  part, total = tonumber(part), tonumber(total)
  if not id or not part or not total or total < 1 or part > total then return nil end
  if total == 1 then return data end
  local bkey = key .. "/" .. id
  local buf = buffers[bkey]
  if not buf then
    buf = { total = total, got = 0, parts = {}, time = GetTime() }
    buffers[bkey] = buf
  end
  if not buf.parts[part] then
    buf.parts[part] = data
    buf.got = buf.got + 1
  end
  buf.time = GetTime()
  if buf.got < buf.total then return nil end
  buffers[bkey] = nil
  return table.concat(buf.parts)
end

C_Timer.NewTicker(60, function()
  local now = GetTime()
  for k, buf in pairs(buffers) do
    if now - buf.time > REASSEMBLY_TIMEOUT then buffers[k] = nil end
  end
end)

local function Deliver(peerKey, text, peerInfo)
  local whole = Reassemble(peerKey, text)
  if not whole then return end
  local msg = ns.Decode(whole)
  if not msg or type(msg.t) ~= "string" then return end
  local peer = ns.peers[peerKey]
  if not peer then
    peer = { name = peerInfo.name }
    ns.peers[peerKey] = peer
  end
  peer.via, peer.bnID, peer.name = peerInfo.via, peerInfo.bnID, peerInfo.name
  peer.version, peer.lastSeen = msg.v, ns.Now()
  ns.OnMessage(msg, peer)
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
  if prefix ~= ns.PREFIX or not sender then return end
  local short = ns.ShortName(sender)
  if short == ns.ShortName(ns.playerName) then return end
  local via
  if channel == "GUILD" then
    if not ns.db.guild then return end
    via = "guild"
  elseif channel == "WHISPER" then
    if ns.db.guild and ns.IsGuildMember(sender) then
      via = "guild"
    elseif ns.db.friends and ns.IsFriend(sender) then
      via = "friend"
    else
      return -- not someone we sync with
    end
  else
    return
  end
  Deliver(short, text, { name = Ambiguate and Ambiguate(sender, "none") or sender, via = via })
end)

ns.On("BN_CHAT_MSG_ADDON", function(prefix, text, _, senderID)
  if prefix ~= ns.PREFIX or not ns.db.bnet or not senderID then return end
  local name = BNetNameFor(senderID)
  if not name then return end
  Deliver(ns.ShortName(name), text, { name = name, via = "bnet", bnID = senderID })
end)

ns.On("PLAYER_LOGIN", function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
  end
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
  if C_FriendList and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
  ns.RefreshRosters()
end)

ns.On("GUILD_ROSTER_UPDATE", ns.RefreshRosters)
ns.On("FRIENDLIST_UPDATE", ns.RefreshRosters)
