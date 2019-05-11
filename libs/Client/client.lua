local Emitter = require('utils/EventEmitter')
local Queue = require('utils/Queue')
local parser = require('utils/parser')

local http = require('coro-http')
local dns = require('dns')
local net = require('net')
local tls = require('tls')
local timer = require('timer')
local json = require('json')

local Client = require('class')('Client', Emitter)
local f = string.format

function Client:__init(options)
  Emitter.__init(self)
  self._ws = {}

  self.options = options
  self.options.channels = self.options.channels or {}
  self.options.connection = self.options.connection or {}
  self.options.identity = self.options.identity or {}
  self.options.options = self.options.options or {}

  self.clientId = self.options.options.clientId or nil

  -- Websocket Connection --
  self.secure = self.options.connection.secure or false
  self.connected = false
  self.connecting = false

  self.maxReconnectAttempts = self.options.connection.maxReconnectAttempts or math.huge
  self.allowReconnect = self.options.connection.reconnect or false
  self.reconnectInterval = self.options.connection.reconnectInterval or 1000

  self.reconnections = 0
  self.reconnectionTask = nil

  self.sendQueue = Queue(self)
  self.floodProtection = self.options.options.floodProtection or true

  -- Data --
  self.emotes = ''
  self.emotesets = {}

  self.channels = {}
  self.currentLatency = 0
  self.globaluserstate = {}
  self.lastJoined = ''
  self.moderators = {}
  self.username = ''
  self.userstate = {}

  self.debug = self.options.options.debug or false
end

function Client:_log(message, ...)
  if self.debug then
    message = string.format(message, ...)
    print(message)
  end
end

function Client:_sendRaw(message)
  if self.sock then
    self.sock:write(tostring(message) .. '\r\n')
  end
end

function Client:_completeConnection()
  self:_log('[CONNECTION] Sending login data')

  self.username = self.options.identity.username or 'Fan' .. math.random(1, 10000)
  self.password = self.options.identity.password or 'MEME'
  self:_sendRaw('CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership')
  self:_sendRaw('PASS ' .. self.password)
  self:_sendRaw('NICK ' .. self.username)
end

function Client:_handlesock(socket)
  socket:on('data', function(data)
    self:emit('raw', data)

    local lines = parser.split(data, '\r\n')
    for _, line in pairs(lines) do
      self:handleMessage(parser.websocketMessage(line))
      self:emit('data', line)
    end
  end)

  socket:on("error", function (err)
		self:_disconnected(err.message, err)
	end)
	socket:on("close", function (...)
		self:_disconnected("Socket closed", ...)
	end)
	socket:on("end", function (...)
		self:_disconnected("Socket ended", ...)
  end)
end

function Client:_connected()
  self.reconnections = 0
  self.connecting = false
  self.connected = true
  self.intentionalDisconnect = false
  self.sendQueue:start()
  self:_log('[CONNECTION] Connected')
  self:emit('connected')
end

function Client:_disconnected(reason, err, retry)
  self.moderators = {}
  self.userstate = {}
  self.globaluserstate = {}

  local wasConnected = self.connected
  local wasConnecting = self.connecting

  self.connected = false
  self.connecting = false
  self.sendQueue:clear()

  if wasConnected or wasConnecting then
    self:emit('disconnect', reason, err)
    self.socket:close()
    if retry then
      if not self.intentionalDisconnect and self.allowReconnect and self.reconnections < self.maxReconnectAttempts then
        self.reconnectionTask = timer.setTimeout(self.reconnectInterval, function()
          self:connect(self.reconnections + 1)
        end)
      end
    end
  end
end

function Client:_openConnection()
  self.intentionalDisconnect = false
  self.connecting = true
  self.sendQueue:clear()
  self:emit('connecting')

  self:_log('[CONNECTION] Connecting')

  if self.reconnectionTask then
    timer.clearTimer(self.reconnectionTask)
    self.reconnectionTask = nil
  end

  return dns.resolve4('irc.chat.twitch.tv', function(err, addresses)
    local resolvedip
		for _,a in ipairs(addresses) do
			if a.address then
				resolvedip = a.address
				break
			end
    end

		if not resolvedip then
			self:_disconnected("Could not resolve address for "..tostring(self.server), err, false)
			return
    end

		if self.secure then
			local options = {host=resolvedip, port=self.port}
      self.sock = tls.connect (options, function()
				self:_handlesock(self.sock)
				self:_completeConnection(self.nick, resolvedip)
			end)
			self.sock:on('error', function(...)
				assert(false, ...)
			end)
		else
			self.sock = net.createConnection(self.port, resolvedip, function(err)
				if err then assert(err) end
				self:_handlesock(self.sock)
				self:_completeConnection(self.nick, resolvedip)
			end)
		end
  end)
end

function Client:_updateEmoteSet(sets)
  self.emotes = sets

  coroutine.wrap(function()
    local _, body = http.request('GET', 'https://api.twitch.tv/kraken/chat/emoticon_images?emotesets=' .. sets, {
      {'Authorization', 'OAuth ' .. self.password:gsub('oauth:', '')},
      {'Client-ID', self.clientId}
    })

    if body and json.decode(body) then
      body = json.decode(body)
      self.emotesets = body['emoticon_sets'] or {}
      return self:emit('emotesets', sets, self.emotesets)
    end
  end)()
end

function Client:handleMessage(message)
  if not message then return end

  local channel = parser.channel(message.params[1]) or nil
  local msg = message.params[2] or nil
  local messageId = message.tags['msg-id'] or nil

  message.tags = parser.badges(parser.badgeInfo(parser.emotes(message.tags)))
  if message.tags then
    local tags = message.tags
    for key, value in pairs(tags) do
      if key ~= 'emote-sets' and key ~= 'ban-duration' and key ~= 'bits' then
        if type(value) == 'boolean' then value = nil
        elseif value == '1' then value = true
        elseif value == '0' then value = false
        elseif type(value) == 'string' then value = parser.unescapeIRC(value) end
        tags[key] = value
      end
    end
  end

  if not message.prefix then
    if message.command == 'PING' then
      self:emit('ping')
      if self.connected then
        self:_send('PONG')
      end
    elseif message.command == 'PONG' then
      -- TODO
      self:_log('[WARN] Server sent PONG')
    else
      self:_log('[WARN] Could not parse message with NO PREFIX: %s', message.raw)
    end
    return
  elseif message.prefix == 'tmi.twitch.tv' then
    local ignore = {['002'] = true, ['003'] = true, ['004'] = true, ['375'] = true, ['376'] = true, ['CAP'] = true}
    if ignore[message.command] then return end

    if message.command == '001' then -- Welcome Message
      self.username = message.params[0]
    elseif message.command == '372' then -- Connected to Server
      self.userstate['#tmilua'] = {}
      return self:_connected()
    elseif message.command == 'NOTICE' then -- https://github.com/justintv/Twitch-API/blob/master/chat/capabilities.md#notice
      if messageId == 'subs_on' then
        self:_log('[$s] This room is now in subscribers-only mode', channel)
        self:emit('subscribers', channel, true)
      elseif messageId == 'subs_off' then
        self:_log('[$s] This room is no longer in subscribers-only mode', channel)
        self:emit('subscribers', channel, false)

      elseif messageId == 'emote_only_on' then
        self:_log('[$s] This room is now in emote-only mode', channel)
        self:emit('emoteonly', channel, true)
      elseif messageId == 'emote_only_off' then
        self:_log('[$s] This room is no longer in emote-only mode', channel)
        self:emit('emoteonly', channel, false)

      elseif messageId == 'r9k_on' then
        self:_log('[$s] This room is now in r9k mode', channel)
        self:emit('r9kmode', channel, true)
      elseif messageId == 'r9k_off' then
        self:_log('[$s] This room is no longer in r9k mode', channel)
        self:emit('r9kmode', channel, false)

      elseif messageId == 'room_mods' then
        local mods = parser.split(parser.split(msg, ': ')[2]:lower(), ', ')
        for _, mod in pairs(mods) do
          self.moderators[channel][mod] = true
        end
        self:emit('mods', channel, mods)
      elseif messageId == 'no_mods' then
        self.moderators[channel] = {}
        self:emit('mods', channel, {})

      -- TODO: Complete
      end
    elseif message.command == 'USERNOTICE' then
      -- TODO: Complete
      if messageId == 'raid' then
        local username = message.tags['msg-param-displayName'] or message.tags['msg-param-login']
        local viewers = message.tags['msg-param-viewerCount']
        self:emit('raided', channel, username, viewers)
      end
    elseif message.command == 'HOSTTARGET' then
      local messageSplit = parser.split(msg, ' ')
      local viewers = tonumber(messageSplit[2]) or 0

      if messageSplit[1] == '-' then
        self:_log('[%s] Exited host mode', channel)
        self:emit('unhost', channel, viewers)
      else
        self:_log('[%s] Now hosting %s for %s viewer(s)', channel, messageSplit[1], viewers)
        self:emit('host', channel, messageSplit[1], viewers)
      end
    elseif message.command == 'CLEARCHAT' then
      if #message.params > 1 then
        local duration = message.tags['ban-duration'] or nil

        if not duration then
          self:_log('[%s] %s has been banned', channel, msg)
          self:emit('ban', channel, msg, duration, message.tags)
        else
          self:_log('[%s] %s has been timed out for %s seconds', channel, msg, duration)
          self:emit('timeout', channel, msg, tonumber(duration), message.tags)
        end
      else
        self:_log('[%s] Chat was cleared by moderator', channel)
        self:emit('clearchat', channel)
      end
    elseif message.command == 'CLEARMSG' then
      if #message.params > 1 then
        local username = message.tags['login']
        local deletedMessage = msg
        local userstate = message.tags
        userstate['message-type'] = 'messagedeleted'

        self:_log('[%s] %s\'s message(s) has been deleted (%s)', channel, username, deletedMessage)
        self:emit('messageDeleted', channel, username, deletedMessage, userstate)
      end
    elseif message.command == 'RECONNECT' then
      self:_log('Received RECONNECT request from Twitch')
      self:_disconnected('Reconnecting')
    elseif message.command == 'USERSTATE' then
      message.tags.username = self.username

      if message.tags['user-type'] == 'mod' then
        self.moderators[self.lastJoined] = self.moderators[self.lastJoined] or {}
        self.moderators[self.lastJoined][self.username] = true
      end

      if not self.userstate[channel] then
        self.userstate[channel] = message.tags
        self.lastJoined = channel
        self.channels[channel] = true
        self:_log('Joined %s', channel)
        self:emit('join', channel, (parser.username(self:getUsername())))
      end

      if message.tags['emote-sets'] ~= self.emotes then
        self:_updateEmoteSet(message.tags['emote-sets'])
      end

      self.userstate[channel] = message.tags
    elseif message.command == 'GLOBALUSERSTATE' then
      self.globaluserstate = message.tags
      if message.tags['emote-sets'] then
        self:_updateEmoteSet(message.tags['emote-sets'])
      end
    elseif message.command == 'ROOMSTATE' then
      if parser.channel(self.lastJoined) == parser.channel(message.params[1]) then end -- Successfully joined
      message.tags.channel = parser.channel(message.params[1])
      self:emit('roomstate', parser.channel(message.params[1]), message.tags)

      if message.tags['subs-only'] then
        if message.tags['slow'] ~= nil then
          if type(message.tags.slow) == 'boolean' and not message.tags.slow then
            self:_log('[%s] This room is no longer in slow mode', channel)
            self:emit('slowmode', channel, false)
          else
            local minutes = tonumber(message.tags.slow)
            self:_log('[%s] This room is now in slow mode', channel)
            self:emit('slowmode', channel, true, minutes)
          end
        end
      end

      if message.tags['followers-only'] then
        if message.tags['followers-only'] == '-1' then
          self:_log('[%s] This room is no longer in followers-only mode', channel)
          self:emit('followersonly', channel, false, 0)
          self:emit('followersmode', channel, false, 0)
        else
          local minutes = tonumber(message.tags['followers-only'])
          self:_log('[%s] This room is now in follower-only mode', channel)
          self:emit('followersonly', channel, true, minutes)
          self:emit('followersmode', channel, true, minutes)
        end
      end
    else
      self:_log('[WARN] Unable to parse message from tmi.twitch.tv: %s', message.raw)
    end
  elseif message.prefix == 'jtv' then
    if message.command == 'MODE' then
      if msg == '+o' then
        self.moderators[channel] = self.moderators[channel] or {}
        self.moderators[channel][message.params[3]] = true
        self:emit('mod', channel, message.params[3])
      elseif msg == '-o' then
        self.moderators[channel] = self.moderators[channel] or {}
        self.moderators[channel][message.params[3]] = nil
        self:emit('unmod', channel, message.params[3])
      end
    else
      self:_log('[WARN] Unable to parse message from jtv: %s', message.raw)    end
  else
    if message.command == '353' then
      self:emit('names', message.params[2], parser.split(message.params[3], ' '))
    elseif message.command == 'JOIN' then
      local nick = parser.split(message.prefix, '!')[1]
      local isSelf = false
      if self.username == nick then
        self.lastJoined = channel
        self.channels[channel] = true
        isSelf = true
      end

      self:emit('join', channel, nick, isSelf)
      self:_log('User <%s> joined %s', nick, channel)
    elseif message.command == 'PART' then
      local isSelf = false
      local nick = parser.split(message.prefix, '!')[1]

      if self.username == nick then
        isSelf = true
        self.userstate[channel] = nil
        self.channels[channel] = nil
        self:_log('Left #%s', channel)
      end

      self:_log('User <%s> left %s', nick, channel)
      self:emit('left', channel, nick, isSelf)
    elseif message.command == 'WHISPER' then
      local nick = parser.split(message.prefix, '!')[1]
      self:_log('[WHISPER] <%s>: %s', nick, message)

      if not message.tags.username then message.tags.username = nick end
      message.tags['message-type'] = 'whisper'

      local from = parser.channel(message.tags.username)
      self:emit('whisper', from, message.tags.username, msg, message.tags)
      self:emit('message', from, message.tags.username, msg, message.tags)
    elseif message.command == 'PRIVMSG' then
      message.tags.username = parser.split(message.prefix, '!')[1]

      if message.tags.username == 'jtv' then
        local name = parser.username(parser.split(msg, ' ')[1])
        local autohost = msg:find('auto')

        -- Channel is being hosted
        if msg:find('hosting you for') then
          local count = msg:match('(%d+)')
          self:emit('hosted', channel, name, count, autohost)
        elseif message:find('hosting you') then -- No Viewers
          self:emit('hosted', channel, name, 0, autohost)
        end
      else
        local actionMessage = parser.actionMessage(msg)
        if actionMessage then
          message.tags['message-type'] = 'action'
          self:_log('[%s] *<%s>: %s', channel, message.tags.username, actionMessage[2])
          self:emit('action', channel, message.tags.username, actionMessage[2], message.tags)
          self:emit('message', channel, message.tags.username, actionMessage[2], message.tags)
        else
          if message.tags['bits'] then
            self:emit('cheer', channel, message.tags, msg)
          else
            message.tags['message-type'] = 'chat'
            self:_log('[%s] <%s>: %s', channel, message.tags.username, msg)
            self:emit('chat', channel, message.tags.username, msg, message.tags)
            self:emit('message', channel, message.tags.username, msg, message.tags)
          end
        end
      end
    end
  end
end

function Client:connect(retries)
  if retries then
    if self.connected then return end
    self.reconnections = retries
    self:_log('Reconnecting #%s', self.reconnections)
  end

  if self.connected then self:disconnect('Reconnecting') end

  self.server = self.options.connection.server or 'irc-ws.chat.twitch.tv'
  self.port = self.options.connection.port or 6667

  if self.secure then self.port = 6697 end
  if self.port == 6697 then self.secure = true end

  return self:_openConnection()
end

function Client:disconnect(reason)
  self.intentionalDisconnect = true
  if self.connected then
    self:_send('QUIT ' .. reason)
  end
  self:_log('Disconnecting')
  self:_disconnected(reason or 'Quit')
end

function Client:_send(message)
  --[[local messages = {message}
  repeat
    local spilloverMessage = messages[#messages]:trimToSize()
    table.insert(messages, spilloverMessage)
  until spilloverMessage == nil

  for _, message in pairs(messages) do]]
    self.sendQueue:push(message)
  --end
end

-- Exposed Functions --
function Client:joinChannel(channel)
  if self.connected then
    channel = parser.channel(channel)
    self:_send('JOIN ' .. channel)
  end
end

function Client:leaveChannel(channel)
  if self.connected then
    channel = parser.channel(channel)
    self:_send('PART ' .. channel)
  end
end

function Client:followersOnly(channel, minutes)
  channel = parser.channel(channel)
  if type(minutes) == 'boolean' and not minutes then
    -- Off
    return self:sendCommand(channel, '/followersoff')
  else
    minutes = minutes or 30
    return self:sendCommand(channel, f('/followers %s', minutes))
  end
end

function Client:slowMode(channel, seconds)
  channel = parser.channel(channel)
  if type(seconds) == 'boolean' and not seconds then
    return self:sendCommand(channel, '/slowoff')
  else
    seconds = seconds or 300
    return self:sendCommand(channel, f('/slow %s', seconds))
  end
end

function Client:sendMessage(channel, message)
  if self.connected then
    channel = parser.channel(channel)
    self.userstate[channel] = self.userstate[channel] or {}

    -- Split Message if too long
    if message:len() >= 500 then
      -- TODO: Split
    end

    self:_send('PRIVMSG ' .. channel .. ' :' .. message)
  else
    return false
  end
end

function Client:sendCommand(channel, command)
  if self.connected then
    if channel then
      channel = parser.channel(channel)
      self:_send('PRIVMSG ' .. channel .. ' :' .. command)
    else
      self:_send(command)
    end
  else
    return false
  end
end

-- Exposed Getters --
function Client:getUsername()
  return self.username
end

function Client:getOptions()
  return self.options
end

function Client:getChannels()
  return self.channels
end

function Client:isMod(username, channel)
  channel = parser.channel(channel)
  username = parser.username(username)

  self.moderators[channel] = self.moderators[channel] or {}
  return self.moderators[channel][username]
end

return Client