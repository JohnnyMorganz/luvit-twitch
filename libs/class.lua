local meta = {}

function meta:__call(...)
  local object = setmetatable({}, self)
  object:__init(...)
  return object
end

return setmetatable({}, {
  __call = function(_, name, ...)
    local class = setmetatable({}, meta)

    class.__name = name

    local extends = {...}
    for _, base in pairs(extends) do
      for key, value in pairs(base) do
        class[key] = value
      end
    end

    function class:__index(k)
      return class[k]
    end

    return class
  end
})