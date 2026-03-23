-- bandmate.lua
-- creative bandmate for seance — not a parameter randomizer
-- handles: style personality, breathing, song form
--
-- 5 mindsets, each a different musician at the rack:
--   MELLOTRON — tape-focused, slow, ghostly
--   MINIMOOG  — filter-obsessed, aggressive sweeps
--   SEQUENCER — pattern-focused, rhythmic interest
--   MODULAR   — matrix routing, evolving modulation
--   FULL SEANCE — all combined, maximum drama

local Bandmate = {}
Bandmate.__index = Bandmate

Bandmate.MINDSET_NAMES = {"MELLOTRON", "MINIMOOG", "SEQUENCER", "MODULAR", "FULL SEANCE"}

-- mindset weights: how much each domain matters {tape, moog, seq, matrix, fx}
Bandmate.MINDSET_WEIGHTS = {
  {0.85, 0.10, 0.10, 0.25, 0.50},  -- MELLOTRON
  {0.15, 0.85, 0.15, 0.30, 0.40},  -- MINIMOOG
  {0.10, 0.15, 0.90, 0.15, 0.15},  -- SEQUENCER
  {0.25, 0.25, 0.15, 0.90, 0.35},  -- MODULAR
  {0.60, 0.60, 0.55, 0.55, 0.55},  -- FULL SEANCE
}

-- explorer pace multiplier per mindset (mellotron = slow, sequencer = fast)
Bandmate.PACE = {1.6, 0.8, 0.6, 1.0, 1.0}

-- song form templates: list of {phase_name, min_bars, max_bars}
Bandmate.FORMS = {
  -- A-B-A (classic)
  {{"home",8,16}, {"depart",6,12}, {"home",8,16}, {"depart",4,8}, {"home",8,12}},
  -- build-drop
  {{"home",8,12}, {"grow",6,10}, {"grow",4,8}, {"silence",1,2}, {"home",8,16}},
  -- call-response
  {{"home",4,8}, {"depart",4,8}, {"home",4,8}, {"depart",4,8}, {"grow",4,6}, {"home",4,8}},
  -- rondo
  {{"home",6,10}, {"depart",4,6}, {"home",4,8}, {"grow",4,8}, {"home",6,10}},
  -- arc
  {{"home",6,10}, {"grow",4,8}, {"grow",4,6}, {"depart",4,8}, {"silence",1,2}, {"home",8,12}},
}

function Bandmate.new()
  local self = setmetatable({}, Bandmate)
  self.mindset = 5 -- FULL SEANCE default
  self.active = false

  -- breathing system
  self.energy = 0.7
  self.breathing = true
  self.breath_phase = "play" -- play / fade / silence / build
  self.breath_bar = 0
  self.breath_target = 0.7

  -- song form
  self.form_enabled = true
  self.form_type = 1
  self.form_section = 1
  self.form_bar = 0
  self.form_phase = "home"
  self.form_section_length = 32
  self.home_state = nil -- snapshot for restoring

  -- pending changes to return
  self.pending = {}
  self.beat_count = 0

  return self
end

function Bandmate:set_mindset(idx)
  self.mindset = idx
end

function Bandmate:get_weights()
  return self.MINDSET_WEIGHTS[self.mindset]
end

function Bandmate:get_pace()
  return self.PACE[self.mindset]
end

----------------------------------------------------------------
-- BREATHING
-- a living energy arc: play → fade → silence → build → play
-- the bandmate breathes. it doesn't just play constantly.
----------------------------------------------------------------

function Bandmate:update_breathing()
  if not self.breathing then return end
  self.breath_bar = self.breath_bar + 1

  if self.breath_phase == "play" then
    -- playing at full energy, occasionally start to fade
    if self.breath_bar > 16 and math.random() < 0.06 then
      self.breath_phase = "fade"
      self.breath_bar = 0
    end

  elseif self.breath_phase == "fade" then
    -- energy draining
    self.energy = math.max(0, self.energy - 0.08)
    if self.energy <= 0.05 then
      self.breath_phase = "silence"
      self.breath_bar = 0
      self.energy = 0
    end

  elseif self.breath_phase == "silence" then
    -- resting. silence is music too.
    if self.breath_bar >= 2 and math.random() < 0.5 then
      self.breath_phase = "build"
      self.breath_bar = 0
    end

  elseif self.breath_phase == "build" then
    -- energy rising
    self.energy = math.min(1, self.energy + 0.12)
    if self.energy >= 0.9 then
      self.breath_phase = "play"
      self.breath_bar = 0
    end
  end
end

----------------------------------------------------------------
-- SONG FORM
-- macro structure: home → depart → grow → silence
-- gives the bandmate narrative direction
----------------------------------------------------------------

function Bandmate:enter_form_section()
  local form = self.FORMS[self.form_type]
  if self.form_section > #form then
    -- cycle to new form
    self.form_type = math.random(1, #self.FORMS)
    self.form_section = 1
    form = self.FORMS[self.form_type]
  end

  local section = form[self.form_section]
  self.form_phase = section[1]
  self.form_bar = 0
  self.form_section_length = math.random(section[2], section[3]) * 4 -- bars→beats
end

function Bandmate:update_form()
  if not self.form_enabled then return end
  self.form_bar = self.form_bar + 1

  if self.form_bar >= self.form_section_length then
    self.form_section = self.form_section + 1
    self:enter_form_section()
  end
end

function Bandmate:save_home(state)
  self.home_state = {}
  for k, v in pairs(state) do
    self.home_state[k] = v
  end
end

function Bandmate:get_home_state()
  return self.home_state
end

----------------------------------------------------------------
-- STYLE-SPECIFIC BEHAVIOR
-- each mindset plays differently on each beat
----------------------------------------------------------------

local style_fns = {}

-- MELLOTRON: slow, ghostly, tape-focused
style_fns[1] = function(self, beat, energy)
  if beat % 16 == 0 and math.random() < energy * 0.3 then
    -- slow warble drift
    self:push({type="delta", param="tape_warble", delta=(math.random() * 2 - 1) * 0.06 * energy})
  end
  if beat % 32 == 0 and math.random() < energy * 0.2 then
    -- spirit drift (voice morph)
    self:push({type="delta", param="macro_spirit", delta=(math.random() * 2 - 1) * 0.08 * energy})
  end
  if beat % 48 == 0 and math.random() < energy * 0.15 then
    -- reverb swell
    self:push({type="delta", param="verb_mix", delta=math.random() * 0.1 * energy})
  end
end

-- MINIMOOG: filter sweeps, resonance peaks, aggressive
style_fns[2] = function(self, beat, energy)
  if beat % 4 == 0 and math.random() < energy * 0.4 then
    -- constant filter movement
    local sweep = (math.random() * 2 - 1) * 0.08 * energy
    self:push({type="delta", param="macro_filter", delta=sweep})
  end
  if beat % 8 == 0 and math.random() < energy * 0.25 then
    -- resonance spike
    self:push({type="delta", param="moog_res", delta=(math.random() * 2 - 1) * 0.4 * energy})
  end
  if beat % 16 == 0 and math.random() < energy * 0.2 then
    -- osc mix shift
    local osc = ({"moog_osc1", "moog_osc2", "moog_osc3"})[math.random(1,3)]
    self:push({type="delta", param=osc, delta=(math.random() * 2 - 1) * 0.2 * energy})
  end
end

-- SEQUENCER: pattern-focused, rhythmic mutations
style_fns[3] = function(self, beat, energy)
  if beat % 4 == 0 and math.random() < energy * 0.35 then
    -- toggle steps frequently
    self:push({type="seq_toggle", count=math.ceil(energy * 2)})
  end
  if beat % 8 == 0 and math.random() < energy * 0.25 then
    -- pitch shifts
    self:push({type="seq_pitch", count=math.ceil(energy * 3), range=math.ceil(energy * 3)})
  end
  if beat % 16 == 0 and math.random() < energy * 0.15 then
    -- direction change
    self:push({type="seq_direction"})
  end
  if beat % 32 == 0 and math.random() < energy * 0.1 then
    -- length change
    self:push({type="seq_length", delta=math.random(-2, 2)})
  end
end

-- MODULAR: matrix routing, LFO mutation, wiring changes
style_fns[4] = function(self, beat, energy)
  if beat % 8 == 0 and math.random() < energy * 0.35 then
    -- rewire a matrix connection
    local s = math.random(1, 4)
    local d = math.random(1, 5)
    local val = math.random() < 0.5 and ((math.random() * 2 - 1) * 0.5 * energy) or 0
    self:push({type="matrix_set", src=s, dst=d, val=val})
  end
  if beat % 12 == 0 and math.random() < energy * 0.3 then
    -- lfo rate drift
    local which = math.random(1, 3)
    self:push({type="lfo_rate", which=which, delta=(math.random() * 2 - 1) * 2.0 * energy})
  end
  if beat % 24 == 0 and math.random() < energy * 0.2 then
    -- lfo shape change
    self:push({type="lfo_shape", which=math.random(1,3), val=math.random(1,4)})
  end
  if beat % 16 == 0 and math.random() < energy * 0.15 then
    -- chaos coefficient drift
    self:push({type="chaos_drift", amount=energy * 0.3})
  end
end

-- FULL SEANCE: all combined, maximum drama
style_fns[5] = function(self, beat, energy)
  -- call all other styles at reduced probability
  for i = 1, 4 do
    if math.random() < 0.5 then
      style_fns[i](self, beat, energy * 0.7)
    end
  end
  -- plus extra dramatic gestures at high energy
  if energy > 0.7 and beat % 16 == 0 and math.random() < 0.3 then
    -- dramatic filter sweep
    local dir = math.random() < 0.5 and 1 or -1
    self:push({type="delta", param="macro_filter", delta=dir * 0.15})
  end
end

Bandmate.style_fns = style_fns

----------------------------------------------------------------
-- MAIN STEP (called every beat from lattice)
----------------------------------------------------------------

function Bandmate:beat()
  if not self.active then return {} end
  self.pending = {}
  self.beat_count = self.beat_count + 1

  -- breathing
  self:update_breathing()

  -- song form
  self:update_form()

  -- form-phase specific behavior
  if self.form_phase == "silence" then
    -- pull everything quiet
    if self.beat_count % 4 == 0 then
      self:push({type="delta", param="macro_filter", delta=-0.03})
      self:push({type="delta", param="verb_mix", delta=0.02})
    end
  elseif self.form_phase == "home" and self.home_state then
    -- gently pull toward home state
    if self.beat_count % 8 == 0 then
      self:push({type="home_pull", strength=0.05})
    end
  elseif self.form_phase == "grow" then
    -- build intensity
    self.energy = math.min(1, self.energy + 0.02)
  end

  -- style-specific mutations (scaled by energy)
  local effective_energy = self.energy * (0.3 + 0.7 * self.energy)
  if effective_energy > 0.05 then
    self.style_fns[self.mindset](self, self.beat_count, effective_energy)
  end

  return self.pending
end

function Bandmate:push(change)
  table.insert(self.pending, change)
end

function Bandmate:start()
  self.active = true
  self.energy = 0.7
  self.breath_phase = "play"
  self.breath_bar = 0
  self.form_section = 1
  self.form_type = math.random(1, #self.FORMS)
  self:enter_form_section()
end

function Bandmate:stop()
  self.active = false
end

return Bandmate
