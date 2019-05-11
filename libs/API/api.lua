-- Wrapper for API
local http = require('coro-http')
local json = require('json')

local API = require('class')('API')

function API:__init(clientID)
  self.baseUrl = ''
  self.clientId = clientID
end

return API