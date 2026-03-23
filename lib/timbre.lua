-- timbre.lua
-- timbre engineer for seance
-- surgically modifies synthesis parameters with creative intent
-- does NOT generate patterns or rhythms — that's the bandmate's job
-- this is the internal sound sculptor
--
-- 6 mindsets, each a different approach to shaping the ghost rack:
--   SCULPTOR    — slow, deliberate, one param at a time
--   ALCHEMIST   — cross-links parameters into relationships
--   PROVOCATEUR — tension/release: builds then snaps back
--   ARCHAEOLOGIST — explores hidden timbral territories
--   WEAVER      — counterpoint between tape and moog
--   PYROMANIAC  — everything burns toward maximum intensity

local Timbre = {}
Timbre.__index = Timbre

Timbre.MINDSET_NAMES = {
  "SCULPTOR", "ALCHEMIST", "PROVOCATEUR",
  "ARCHAEOLOGIST", "WEAVER", "PYROMANIAC"
}

-- param targets the timbre engineer can touch
-- {name, min, max, group} — group: "tape" or "moog"
Timbre.TARGETS = {
  {name = "tape_warble",  min = 0.05, max = 0.85, group = "tape"},
  {name = "tape_tone",    min = 200,  max = 10000, group = "tape"},
  {name = "tape_attack",  min = 0.01, max = 1.5,  group = "tape"},
  {name = "tape_release", min = 0.1,  max = 6.0,  group = "tape"},
  {name = "moog_cutoff",  min = 80,   max = 16000, group = "moog"},
  {name = "moog_res",     min = 0.05, max = 3.2,  group = "moog"},
  {name = "moog_pw",      min = 0.1,  max = 0.9,  group = "moog"},
  {name = "moog_porta",   min = 0.0,  max = 0.6,  group = "moog"},
  {name = "moog_osc1",    min = 0.0,  max = 1.0,  group = "moog"},
  {name = "moog_osc2",    min = 0.0,  max = 1.0,  group = "moog"},
  {name = "moog_osc3",    min = 0.0,  max = 1.0,  group = "moog"},
  {name = "moog_f_env",   min = 0,    max = 7000, group = "moog"},
}

function Timbre.new()
  local self = setmetatable({}, Timbre)
  self.active = true
  self.mindset = 1  -- SCULPTOR
  self.intensity = 0.4
  self.step_count = 0
  self.pending = {}
  self.last_action = ""

  -- sculptor state
  self.focus = 1          -- which param index we're focused on
  self.focus_timer = 0    -- how long on this param
  self.direction = 1      -- +1 or -1

  -- provocateur state
  self.tension = 0        -- 0-1, builds until snap
  self.tension_target = {} -- param snapshots before tension build
  self.building = false

  -- weaver state
  self.weave_phase = 0    -- oscillates: tape bright / moog bright

  -- archaeologist state
  self.territory = {}     -- unusual param combo being explored

  return self
end

function Timbre:set_mindset(idx)
  self.mindset = idx
  self.focus_timer = 0
  self.tension = 0
  self.building = false
  self.last_action = Timbre.MINDSET_NAMES[idx]
end

function Timbre:push(change)
  table.insert(self.pending, change)
end

function Timbre:push_delta(param, delta)
  self:push({type = "delta", param = param, delta = delta})
end

----------------------------------------------------------------
-- MINDSET FUNCTIONS
----------------------------------------------------------------

local mindset_fns = {}

-- SCULPTOR: slow, deliberate, one param at a time
-- picks a param, nudges it in one direction, listens, moves on
mindset_fns[1] = function(self, intensity)
  self.focus_timer = self.focus_timer + 1

  -- change focus every 16-48 steps (slower at low intensity)
  local focus_dur = math.floor(48 - intensity * 32)
  if self.focus_timer > focus_dur then
    self.focus = math.random(1, #Timbre.TARGETS)
    self.direction = math.random() < 0.5 and 1 or -1
    self.focus_timer = 0
    self.last_action = "sculpt " .. Timbre.TARGETS[self.focus].name
  end

  -- nudge focused param gently
  if self.step_count % 4 == 0 then
    local t = Timbre.TARGETS[self.focus]
    local range = (t.max - t.min)
    local delta = self.direction * range * 0.008 * intensity
    self:push_delta(t.name, delta)
  end
end

-- ALCHEMIST: cross-links parameters into relationships
-- when one rises, another falls — transmutation
mindset_fns[2] = function(self, intensity)
  if self.step_count % 8 ~= 0 then return end

  -- pairs that transmute: {up_param, down_param}
  local pairs = {
    {"moog_cutoff", "tape_warble"},   -- bright moog = stable tape
    {"moog_res", "moog_pw"},          -- resonance peak narrows pulse
    {"tape_tone", "moog_porta"},      -- bright tape = tight moog
    {"tape_warble", "moog_cutoff"},   -- wobbly tape = dark moog
    {"moog_osc2", "moog_osc3"},      -- pulse up = sub down
    {"tape_release", "tape_attack"},  -- long release = short attack
  }

  local pair = pairs[math.random(1, #pairs)]
  local amount = 0.02 * intensity
  if math.random() < 0.5 then
    self:push_delta(pair[1], amount * (Timbre.TARGETS[1].max - Timbre.TARGETS[1].min) * 0.01)
    self:push_delta(pair[2], -amount * (Timbre.TARGETS[1].max - Timbre.TARGETS[1].min) * 0.01)
  else
    self:push_delta(pair[1], -amount * 100)
    self:push_delta(pair[2], amount * 100)
  end
  self.last_action = "transmute"
end

-- PROVOCATEUR: tension/release cycles
-- slowly builds filter/resonance/warble tension, then snaps everything back
mindset_fns[3] = function(self, intensity)
  if self.step_count % 4 ~= 0 then return end

  if not self.building then
    -- decide to start building
    if math.random() < 0.03 * intensity then
      self.building = true
      self.tension = 0
      self.tension_target = {}
      self.last_action = "building..."
    end
  end

  if self.building then
    self.tension = math.min(1, self.tension + 0.02 * intensity)

    -- push toward extremes
    self:push_delta("moog_cutoff", 200 * intensity * self.tension)
    self:push_delta("moog_res", 0.05 * intensity * self.tension)
    self:push_delta("tape_warble", 0.01 * intensity * self.tension)

    -- snap back at peak tension
    if self.tension >= 0.95 or (self.tension > 0.5 and math.random() < 0.08) then
      -- dramatic release: pull everything back hard
      self:push_delta("moog_cutoff", -800 * self.tension)
      self:push_delta("moog_res", -0.5 * self.tension)
      self:push_delta("tape_warble", -0.15 * self.tension)
      self.building = false
      self.tension = 0
      self.last_action = "SNAP!"
    end
  end
end

-- ARCHAEOLOGIST: explores hidden parameter territories
-- finds unusual combinations nobody visits
mindset_fns[4] = function(self, intensity)
  if self.step_count % 12 ~= 0 then return end

  -- unusual territories: param combos that sound interesting
  local territories = {
    -- extreme sub with high warble and dark filter
    {moog_osc3 = 1.0, moog_osc1 = 0.1, moog_osc2 = 0.1, moog_cutoff = -500, tape_warble = 0.1},
    -- resonant self-oscillation territory
    {moog_res = 0.3, moog_cutoff = 300, moog_pw = 0.1, moog_f_env = 1000},
    -- pure tape ghost (moog quiet, tape wide open)
    {tape_warble = 0.05, tape_tone = 500, tape_release = 1.0, moog_osc1 = -0.1},
    -- nasal territory
    {moog_pw = 0.15, moog_osc2 = 0.2, moog_cutoff = 200, moog_res = 0.1},
    -- wide stereo territory
    {tape_warble = 0.08, tape_attack = 0.1, moog_porta = 0.1, tape_release = 0.5},
    -- bright and glassy
    {moog_cutoff = 800, moog_f_env = 1500, tape_tone = 1000, moog_res = -0.1},
  }

  -- slowly drift toward a territory
  if #self.territory == 0 or math.random() < 0.05 then
    self.territory = territories[math.random(1, #territories)]
    self.last_action = "excavating"
  end

  for param, target_delta in pairs(self.territory) do
    local nudge = target_delta * 0.03 * intensity
    self:push_delta(param, nudge)
  end
end

-- WEAVER: counterpoint between tape and moog
-- when tape brightens, moog darkens and vice versa
mindset_fns[5] = function(self, intensity)
  if self.step_count % 6 ~= 0 then return end

  self.weave_phase = self.weave_phase + 0.02 * intensity
  local wave = math.sin(self.weave_phase)

  -- tape side: follows wave
  self:push_delta("tape_tone", wave * 100 * intensity)
  self:push_delta("tape_warble", wave * 0.01 * intensity)

  -- moog side: opposes wave
  self:push_delta("moog_cutoff", -wave * 150 * intensity)
  self:push_delta("moog_pw", -wave * 0.02 * intensity)

  -- osc mix counterpoint
  if math.abs(wave) > 0.7 then
    self:push_delta("moog_osc1", wave * 0.02 * intensity)
    self:push_delta("moog_osc2", -wave * 0.02 * intensity)
  end

  self.last_action = wave > 0 and "tape rising" or "moog rising"
end

-- PYROMANIAC: everything burns toward maximum
mindset_fns[6] = function(self, intensity)
  if self.step_count % 3 ~= 0 then return end

  -- push everything hot
  local fire = intensity * 0.8
  if math.random() < fire then
    self:push_delta("moog_res", 0.03 * fire)
  end
  if math.random() < fire then
    self:push_delta("moog_cutoff", 150 * fire)
  end
  if math.random() < fire then
    self:push_delta("tape_warble", 0.015 * fire)
  end
  if math.random() < fire * 0.5 then
    self:push_delta("moog_f_env", 100 * fire)
  end
  if math.random() < fire * 0.3 then
    self:push_delta("moog_pw", (math.random() * 2 - 1) * 0.03 * fire)
  end

  -- occasionally pull back (even pyromaniac needs contrast)
  if math.random() < 0.04 then
    self:push_delta("moog_cutoff", -600 * fire)
    self:push_delta("moog_res", -0.3 * fire)
    self.last_action = "embers"
  else
    self.last_action = "burning"
  end
end

Timbre.mindset_fns = mindset_fns

----------------------------------------------------------------
-- MAIN STEP (called every sequencer step)
----------------------------------------------------------------

function Timbre:step(energy)
  if not self.active then return {} end
  self.pending = {}
  self.step_count = self.step_count + 1

  -- effective intensity scales with external energy (from bandmate breathing)
  local eff = self.intensity * (0.3 + 0.7 * (energy or 0.7))

  -- skip during very low energy (silence is music)
  if eff < 0.05 then return {} end

  -- run mindset function
  self.mindset_fns[self.mindset](self, eff)

  return self.pending
end

return Timbre
