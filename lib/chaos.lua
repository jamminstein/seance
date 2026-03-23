-- chaos.lua
-- polynomial chaos modulation source for seance
-- logistic map + henon-like coupling
-- 4 independent channels, routable to any destination

local Chaos = {}
Chaos.__index = Chaos

function Chaos.new()
  local self = setmetatable({}, Chaos)
  -- 4 independent chaos channels
  self.x = {0.1, 0.5, 0.3, 0.7}
  self.y = {0.4, 0.2, 0.8, 0.6}
  self.coeff_x = 3.72  -- logistic parameter (chaos onset ~3.57)
  self.coeff_y = 2.8
  self.smooth = 0.3     -- 0=stepped, 1=smooth
  self.outputs = {0, 0, 0, 0}
  self.prev_outputs = {0, 0, 0, 0}

  -- routing: {param_name = {ch, depth, offset}}
  self.routes = {}

  return self
end

-- advance one step of the polynomial
function Chaos:step()
  for i = 1, 4 do
    self.prev_outputs[i] = self.outputs[i]

    -- logistic map
    local nx = self.coeff_x * self.x[i] * (1 - self.x[i])
    -- henon-like coupling
    local ny = 1 - (self.coeff_y * self.x[i] * self.x[i]) + 0.3 * self.y[i]

    -- clamp to prevent escape
    self.x[i] = math.max(0.001, math.min(0.999, nx))
    self.y[i] = math.max(-1, math.min(1, ny))

    -- combine to output (0-1)
    local raw = (self.x[i] + (self.y[i] + 1) * 0.25) / 1.5
    raw = math.max(0, math.min(1, raw))

    -- smoothing (slew between steps)
    self.outputs[i] = self.prev_outputs[i] + (raw - self.prev_outputs[i]) * (1 - self.smooth)
  end
end

-- get channel output (0-1)
function Chaos:get(ch)
  return self.outputs[ch] or 0
end

-- get bipolar (-1 to 1)
function Chaos:get_bipolar(ch)
  return (self.outputs[ch] or 0.5) * 2 - 1
end

-- route a chaos channel to a parameter
function Chaos:route(param, ch, depth, offset)
  self.routes[param] = {ch=ch, depth=depth or 0.5, offset=offset or 0}
end

-- remove a route
function Chaos:unroute(param)
  self.routes[param] = nil
end

-- get routed value for a param (returns delta to add to base value)
function Chaos:get_routed(param)
  local r = self.routes[param]
  if not r then return 0 end
  return self:get_bipolar(r.ch) * r.depth + r.offset
end

-- drift coefficients (used by explorer/bandmate to push chaos)
function Chaos:drift(amount)
  self.coeff_x = math.max(3.2, math.min(3.99, self.coeff_x + (math.random() * 2 - 1) * amount))
  self.coeff_y = math.max(1.5, math.min(3.5, self.coeff_y + (math.random() * 2 - 1) * amount * 0.5))
end

-- set smoothing (0=stepped, 1=smooth)
function Chaos:set_smooth(val)
  self.smooth = math.max(0, math.min(1, val))
end

-- reset to deterministic state
function Chaos:reset()
  self.x = {0.1, 0.5, 0.3, 0.7}
  self.y = {0.4, 0.2, 0.8, 0.6}
  self.coeff_x = 3.72
  self.coeff_y = 2.8
  self.outputs = {0, 0, 0, 0}
  self.prev_outputs = {0, 0, 0, 0}
end

return Chaos
