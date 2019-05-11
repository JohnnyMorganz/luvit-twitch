-- Wrapper for API
local http = require('coro-http')
local json = require('json')

local API = require('class')('API')

function API:__init(clientID, token)
  self.baseUrl = 'https://api.twitch.tv/helix/'
  self.clientId = clientID

  self.headers = {
    {'Client-ID', self.clientId}
  }

  if token then
    self.token = token
    table.insert(self.headers, {'Authorization', 'Bearer ' .. self.token})
  end
end

function API:_request(method, url, data)
  local _, mainThread = coroutine.running()
  assert(mainThread, 'HTTP requests must be made inside a coroutine!')

  url = self.baseUrl .. url

  local sendData = false

  if method == 'GET' and data then
    url = url .. '?'
    for k,v in pairs(data) do
    end
  elseif data then
    sendData = true
    data = json.encode(data)
  end

  local success, res, data = pcall(http.request, method, url, self.headers, (sendData and data))
  if success then
    print(res)
  else
    return false, res
  end
end

return API