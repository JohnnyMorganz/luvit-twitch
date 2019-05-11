local timer = require('timer')
local Queue = require('class')('Queue')

function Queue:__init(client)
  self.client = client
  self.queue = {}
  self.burstLimit = 4
  self.sendInterval = 2200
  self.availableSends = self.burstLimit
  self.enabled = true
end

function Queue:enable()
  self.enabled = true
end

function Queue:disable()
  self.enabled = false
  self:stop()
end

function Queue:start()
  self:stop()

  if self.enabled then
    self.sendTask = timer.setInterval(self.sendInterval, function()
      if self.client.floodProtection then
        self:newSendAvailable()
        self:process()
      end
    end)
  end
end

function Queue:stop()
  if self.sendTask then
    timer.clearInterval(self.sendTask)
  end
end

function Queue:push(message)
  table.insert(self.queue, message)
  self:process()
end

function Queue:pop()
  return table.remove(self.queue, 1)
end

function Queue:clear()
  self.queue = {}
  self.availableSends = self.burstLimit
end

function Queue:isReady()
  return #self.queue > 0
end

function Queue:peek()
  return self.queue[1]
end

function Queue:peekSize()
  local peekMessage = self:peek()
  return peekMessage and (peekMessage:len()+2) or 0
end

function Queue:canSend()
  return self.availableSends > 0 or not self.client.floodProtection
end

function Queue:newSendAvailable()
  if self.availableSends < self.burstLimit then
    self.availableSends = self.availableSends + 1
  end
end

function Queue:process()
  while self:isReady() and self:canSend() do
    local message = self:pop()
    self.client:_sendRaw(message)
    if self.client.floodProtection then
      self.availableSends = self.availableSends - 1
    end
  end
end

return Queue