local MAX_MESSAGE_SIZE = 500

local IRCMessage = require('class')('IRCMessage')

function IRCMessage:__init(command, ...)
  self.command = command
  self.args = {...}
end

function IRCMessage:clone()
  return IRCMessage(self.command, unpack(self.args))
end

function IRCMessage:lastArg()
  return self.args[#self.args]
end

function IRCMessage:getAndDiscardMatches(str, pattern, maxMatches)
  local matches = {str:match(pattern)}
  if matches[1] ~= nil then
    while maxMatches and #matches > maxMatches do
      table.remove(matches)
    end
    return str:gsub(pattern, '', maxMatches), unpack(matches)
  else
    return str, nil
  end
end

function IRCMessage:size()
  return tostring(self):len() + 2
end

function IRCMessage:toServerMessage(connection)
  local serverMessage = self:clone()
  serverMessage.nick = connection.nick
end

return IRCMessage