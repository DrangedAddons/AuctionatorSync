-- Transport. Anyone running AuctionatorSync syncs, no restrictions. Messages are hidden addon
-- data (never chat) and reach other players through every route the game allows:
--   GUILD   - your guild
--   CHANNEL - a hidden custom channel every AuctionatorSync user joins, so players outside your
--             guild and friends list are found too (removed from your chat windows)
--   WHISPER - one player by name (direct replies, and in-game friends at login)
--   BN      - Battle.net friends in this game
-- Every logical message is an encoded table split into chunks "<id>:<part>:<total>:<data>".
-- A message arriving twice (e.g. guild AND channel) is only handled once.
local _, ns = ...

local CTL = ChatThrottleLib
local CHUNK_ADDON = 240   -- addon messages are capped at 255 bytes
local CHUNK_BNET = 4000   -- BNSendGameData allows ~4KB
local REASSEMBLY_TIMEOUT = 300
local CHANNEL_NAME = "AuctionatorSyncData"

ns.peers = {} -- short name -> { name, version, proto, routes = {}, bnID, lastSeen, st, d, os, host }

----------------------------------------------------------------------------------------------
-- The hidden channel

ns.channelId = nil

local function HideChannel()
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local frame = _G["ChatFrame" .. i]
    if frame and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, frame, CHANNEL_NAME) end
  end
end

function ns.JoinChannel()
  local id = GetChannelName(CHANNEL_NAME)
  if not id or id == 0 then
    if JoinTemporaryChannel then pcall(JoinTemporaryChannel, CHANNEL_NAME) end
    id = GetChannelName(CHANNEL_NAME)
  end
  if id and id > 0 then
    if ns.channelId ~= id then ns.Log("joined the hidden AuctionatorSync channel (#%d)", id) end
    ns.channelId = id
    HideChannel()
  else
    ns.channelId = nil
    ns.Log("couldn't join the hidden channel: syncing with guild, friends and Battle.net only")
  end
end

-- Keep "joined channel" / "left channel" notices for our channel out of chat.
if ChatFrame_AddMessageEventFilter then
  -- the channel name sits at different argument positions for these events: check them all
  local function Filter(_, _, ...)
    for i = 1, select("#", ...) do
      local v = select(i, ...)
      if type(v) == "string" and v:find(CHANNEL_NAME, 1, true) then return true end
    end
    return false
  end
  for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
    "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
    ChatFrame_AddMessageEventFilter(event, Filter)
  end
end

----------------------------------------------------------------------------------------------
-- Friends (only used to find people at login; anyone with the addon is welcome)

local function OnlineFriends()
  local list = {}
  if C_FriendList and C_FriendList.GetNumFriends then
    for i = 1, C_FriendList.GetNumFriends() do
      local info = C_FriendList.GetFriendInfoByIndex(i)
      if info and info.name and info.connected then list[#list + 1] = info.name end
    end
  end
  return list
end

-- Online Battle.net friends playing this game: { {id, name}, ... }
local function BNetFriends()
  local list = {}
  if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return list end
  local _, numOnline = BNGetNumFriends()
  for i = 1, numOnline or 0 do
    local acc = C_BattleNet.GetFriendAccountInfo(i)
    local g = acc and acc.gameAccountInfo
    if g and g.isOnline and g.gameAccountID and g.characterName
      and (not BNET_CLIENT_WOW or g.clientProgram == BNET_CLIENT_WOW) then
      list[#list + 1] = { id = g.gameAccountID, name = g.characterName }
    end
  end
  return list
end

local function BNetNameFor(id)
  local info = C_BattleNet and C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetGameAccountInfoByID(id)
  return info and info.characterName
end

function ns.RefreshRosters() end -- kept for older callers; nothing to cache any more

----------------------------------------------------------------------------------------------
-- Sending

local msgCounter = 0
local function NextId()
  msgCounter = msgCounter + 1
  return string.format("%x%x", math.random(0, 255), msgCounter)
end

local function RouteName(target)
  if target.kind == "GUILD" then return "guild" end
  if target.kind == "CHANNEL" then return "channel" end
  return (target.name or tostring(target.id)) .. (target.kind == "BN" and " (Battle.net)" or "")
end

-- target = { kind = "GUILD" | "CHANNEL" } | { kind = "WHISPER", name } | { kind = "BN", id, name }
-- onSent: called once the message's last chunk has actually gone out (the throttle queues them).
function ns.Send(target, msg, prio, id, onSent)
  if not target then return end
  msg.v = ns.VERSION
  msg.p = ns.PROTOCOL
  msg.sid = ns.SESSION
  local text = ns.Encode(msg)
  if not text then return end
  local size = target.kind == "BN" and CHUNK_BNET or CHUNK_ADDON
  local total = math.ceil(#text / size)
  id = id or NextId()
  prio = prio or "NORMAL"
  for i = 1, total do
    local chunk = id .. ":" .. i .. ":" .. total .. ":" .. text:sub((i - 1) * size + 1, i * size)
    local cb = (i == total and onSent) and function() onSent() end or nil
    if target.kind == "BN" then
      CTL:BNSendGameData(prio, ns.PREFIX, chunk, "WHISPER", target.id, "AucSync" .. target.id, cb)
    elseif target.kind == "WHISPER" then
      CTL:SendAddonMessage(prio, ns.PREFIX, chunk, "WHISPER", target.name, "AucSync" .. target.name, cb)
    elseif target.kind == "CHANNEL" then
      CTL:SendAddonMessage(prio, ns.PREFIX, chunk, "CHANNEL", tostring(target.channel), "AucSyncChannel", cb)
    else
      CTL:SendAddonMessage(prio, ns.PREFIX, chunk, "GUILD", nil, "AucSyncGuild", cb)
    end
  end
  return id
end

-- To everyone online with the addon: guild + channel, plus Battle.net/whisper for players we
-- only reach that way. With discover = true (login), also every online friend and Battle.net
-- friend, since we don't know yet who has the addon. The same id goes on every route, so a
-- player reached twice only handles it once.
function ns.Broadcast(msg, prio, discover, onSent)
  local id = NextId()
  -- onSent fires once, when the first route has actually sent it
  local fired = false
  local function Sent()
    if onSent and not fired then
      fired = true
      onSent()
    end
  end
  local covered = {}
  local routes = {}
  if IsInGuild() then
    ns.Send({ kind = "GUILD" }, msg, prio, id, Sent)
    routes[#routes + 1] = "guild"
  end
  if ns.channelId then
    ns.Send({ kind = "CHANNEL", channel = ns.channelId }, msg, prio, id, Sent)
    routes[#routes + 1] = "channel"
  end
  for short, peer in pairs(ns.peers) do
    if peer.routes.guild or peer.routes.channel then covered[short] = true end
  end
  local direct = 0
  local function Direct(target, short)
    if covered[short] or ns.IsMe(target.name) then return end
    covered[short] = true
    ns.Send(target, msg, prio, id, Sent)
    direct = direct + 1
  end
  for short, peer in pairs(ns.peers) do
    if ns.IsPeerOnline(peer) then Direct(ns.ReplyTarget(peer), short) end
  end
  if discover then
    for _, name in ipairs(OnlineFriends()) do Direct({ kind = "WHISPER", name = name }, ns.ShortName(name)) end
    for _, f in ipairs(BNetFriends()) do Direct({ kind = "BN", id = f.id, name = f.name }, ns.ShortName(f.name)) end
  end
  if direct > 0 then routes[#routes + 1] = ns.Plural(direct, "player") .. " directly" end
  return table.concat(routes, ", ")
end

-- Where to answer one player directly.
function ns.ReplyTarget(peer)
  if peer.bnID and not peer.routes.whisper and not peer.routes.guild and not peer.routes.channel then
    return { kind = "BN", id = peer.bnID, name = peer.name }
  end
  return { kind = "WHISPER", name = peer.name }
end

----------------------------------------------------------------------------------------------
-- Who's online

local OFFLINE_AFTER = 200 -- seconds without a heartbeat

function ns.IsPeerOnline(peer)
  return peer.lastSeen ~= nil and ns.Now() - peer.lastSeen < OFFLINE_AFTER and not peer.gone
end

----------------------------------------------------------------------------------------------
-- Receiving

local buffers = {}
local handled = {} -- sender/id -> time, so a message arriving by two routes is handled once

local function Reassemble(key, text)
  local id, part, total, data = text:match("^(%x+):(%d+):(%d+):(.*)$")
  part, total = tonumber(part), tonumber(total)
  if not id or not part or not total or total < 1 or part > total then return nil end
  local bkey = key .. "/" .. id
  if handled[bkey] then return nil end
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
  handled[bkey] = GetTime()
  return table.concat(buf.parts)
end

C_Timer.NewTicker(60, function()
  local now = GetTime()
  for k, buf in pairs(buffers) do
    if now - buf.time > REASSEMBLY_TIMEOUT then buffers[k] = nil end
  end
  for k, t in pairs(handled) do
    if now - t > REASSEMBLY_TIMEOUT then handled[k] = nil end
  end
end)

local function Deliver(name, route, text, bnID)
  if not name or ns.IsMe(name) then return end
  local short = ns.ShortName(name)
  local whole = Reassemble(short, text)
  if not whole then return end
  local msg = ns.Decode(whole)
  if not msg or type(msg.t) ~= "string" or msg.sid == ns.SESSION then return end
  local peer = ns.peers[short]
  if not peer then
    peer = { name = name, routes = {} }
    ns.peers[short] = peer
  end
  peer.name = name
  peer.routes[route] = true
  if bnID then peer.bnID = bnID end
  if peer.sid and msg.sid and peer.sid ~= msg.sid and ns.CancelTransfersTo then
    ns.CancelTransfersTo(name, "they reloaded")
  end
  peer.sid = msg.sid or peer.sid
  peer.version, peer.proto, peer.lastSeen, peer.gone = msg.v, tonumber(msg.p) or 1, ns.Now(), nil
  ns.OnMessage(msg, peer)
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
  if prefix ~= ns.PREFIX or not sender then return end
  local route = (channel == "GUILD" and "guild") or (channel == "WHISPER" and "whisper")
    or (channel == "CHANNEL" and "channel")
  if not route then return end
  Deliver(Ambiguate and Ambiguate(sender, "none") or sender, route, text)
end)

ns.On("BN_CHAT_MSG_ADDON", function(prefix, text, _, senderID)
  if prefix ~= ns.PREFIX or not senderID then return end
  Deliver(BNetNameFor(senderID), "bnet", text, senderID)
end)

ns.On("PLAYER_LOGIN", function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
  end
  if C_FriendList and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
end)
