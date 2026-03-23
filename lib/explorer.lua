-- explorer.lua
-- phase-based mutation engine for seance
-- cycles: SUMMON → HAUNT → POSSESS → RELEASE
-- each phase has duration, intensity arc, mutation probabilities

local Explorer = {}
Explorer.__index = Explorer

-- phases
Explorer.PHASE_NAMES = {"SUMMON", "HAUNT", "POSSESS", "RELEASE"}

-- phase configs: {duration_min_bars, duration_max_bars, intensity_start, intensity_end}
Explorer.PHASE_CONFIG = {
  {16, 32, 0.10, 0.40},  -- SUMMON: building tension from near-silence
  {24, 48, 0.35, 0.70},  -- HAUNT: ghostly, mellotron-heavy
  {16, 32, 0.65, 1.00},  -- POSSESS: full intensity, everything screaming
  {24, 40, 0.55, 0.10},  -- RELEASE: decaying, thinning, reverb tails
}

-- per-phase mutation probabilities: {tape, moog, seq, matrix, fx}
Explorer.PHASE_PROBS = {
  {0.15, 0.10, 0.10, 0.05, 0.10},  -- SUMMON: minimal mutations
  {0.40, 0.25, 0.20, 0.20, 0.25},  -- HAUNT: moderate, tape-heavy
  {0.50, 0.60, 0.50, 0.40, 0.35},  -- POSSESS: heavy mutations everywhere
  {0.25, 0.15, 0.15, 0.10, 0.30},  -- RELEASE: dropping off, fx stays
}

-- mutation intervals (steps between mutation checks)
Explorer.INTERVALS = {
  tape = 16,
  moog = 12,
  seq = 8,
  matrix = 24,
  fx = 20,
}

function Explorer.new()
  local self = setmetatable({}, Explorer)
  self.active = false
  self.phase = 1
  self.phase_beat = 0
  self.phase_length = 96
  self.intensity = 0.1
  self.intensity_start = 0.1
  self.intensity_end = 0.4
  self.step_count = 0
  self.pending = {}
  self.last_mutation = ""
  self.flash = nil -- {text, timer}
  return self
end

function Explorer:enter_phase(phase_num, pace_mult)
  pace_mult = pace_mult or 1.0
  self.phase = phase_num
  self.phase_beat = 0
  local cfg = self.PHASE_CONFIG[phase_num]
  local min_bars = math.floor(cfg[1] * pace_mult)
  local max_bars = math.floor(cfg[2] * pace_mult)
  self.phase_length = math.random(min_bars, max_bars) * 4 -- bars → beats
  self.intensity_start = cfg[3]
  self.intensity_end = cfg[4]
  self.intensity = cfg[3]
  self.flash = {self.PHASE_NAMES[phase_num], 10}
end

function Explorer:next_phase(pace_mult)
  local next = self.phase % 4 + 1
  self:enter_phase(next, pace_mult)
end

-- called every beat (1/4 note)
function Explorer:beat(pace_mult)
  if not self.active then return end
  self.phase_beat = self.phase_beat + 1

  -- lerp intensity
  local progress = self.phase_beat / math.max(self.phase_length, 1)
  progress = math.min(progress, 1)
  self.intensity = self.intensity_start + (self.intensity_end - self.intensity_start) * progress

  -- phase transition
  if self.phase_beat >= self.phase_length then
    self:next_phase(pace_mult)
  end
end

-- called every sequencer step
-- returns list of pending changes: {type, param, delta} or {type, action, ...}
function Explorer:step(mindset_weights)
  if not self.active then return {} end
  self.pending = {}
  self.step_count = self.step_count + 1

  local probs = self.PHASE_PROBS[self.phase]
  local int = self.intensity

  -- check each domain at its interval
  if self.step_count % self.INTERVALS.tape == 0 then
    if math.random() < probs[1] * int * (mindset_weights[1] or 1) then
      self:mutate_tape(int)
    end
  end

  if self.step_count % self.INTERVALS.moog == 0 then
    if math.random() < probs[2] * int * (mindset_weights[2] or 1) then
      self:mutate_moog(int)
    end
  end

  if self.step_count % self.INTERVALS.seq == 0 then
    if math.random() < probs[3] * int * (mindset_weights[3] or 1) then
      self:mutate_seq(int)
    end
  end

  if self.step_count % self.INTERVALS.matrix == 0 then
    if math.random() < probs[4] * int * (mindset_weights[4] or 1) then
      self:mutate_matrix(int)
    end
  end

  if self.step_count % self.INTERVALS.fx == 0 then
    if math.random() < probs[5] * int * (mindset_weights[5] or 1) then
      self:mutate_fx(int)
    end
  end

  return self.pending
end

function Explorer:push(change)
  table.insert(self.pending, change)
end

----------------------------------------------------------------
-- MUTATION FUNCTIONS
----------------------------------------------------------------

local function rand_delta(range)
  return (math.random() * 2 - 1) * range
end

function Explorer:mutate_tape(int)
  local roll = math.random()
  if roll < 0.3 then
    self:push({type="delta", param="tape_warble", delta=rand_delta(0.15 * int)})
    self.last_mutation = "warble"
  elseif roll < 0.5 then
    self:push({type="delta", param="macro_spirit", delta=rand_delta(0.12 * int)})
    self.last_mutation = "spirit"
  elseif roll < 0.7 then
    self:push({type="delta", param="tape_attack", delta=rand_delta(0.3 * int)})
    self.last_mutation = "tape atk"
  else
    self:push({type="delta", param="tape_release", delta=rand_delta(1.0 * int)})
    self.last_mutation = "tape rel"
  end
end

function Explorer:mutate_moog(int)
  local roll = math.random()
  if roll < 0.35 then
    self:push({type="delta", param="macro_filter", delta=rand_delta(0.2 * int)})
    self.last_mutation = "filter"
  elseif roll < 0.55 then
    self:push({type="delta", param="moog_pw", delta=rand_delta(0.2 * int)})
    self.last_mutation = "pw"
  elseif roll < 0.75 then
    local osc = ({"moog_osc1", "moog_osc2", "moog_osc3"})[math.random(1,3)]
    self:push({type="delta", param=osc, delta=rand_delta(0.25 * int)})
    self.last_mutation = "osc mix"
  else
    self:push({type="delta", param="moog_porta", delta=rand_delta(0.12 * int)})
    self.last_mutation = "porta"
  end
end

function Explorer:mutate_seq(int)
  local roll = math.random()
  if roll < 0.3 then
    local count = math.ceil(int * 3)
    self:push({type="seq_toggle", count=count})
    self.last_mutation = "steps"
  elseif roll < 0.5 then
    local count = math.ceil(int * 4)
    self:push({type="seq_pitch", count=count, range=math.ceil(int * 4)})
    self.last_mutation = "pitch"
  elseif roll < 0.65 then
    self:push({type="seq_direction"})
    self.last_mutation = "direction"
  elseif roll < 0.8 then
    self:push({type="seq_length", delta=math.random(-2, 2)})
    self.last_mutation = "length"
  else
    if int > 0.6 then
      self:push({type="seq_scale"})
      self.last_mutation = "scale!"
    else
      self:push({type="seq_root", delta=math.random(-2, 2)})
      self.last_mutation = "root"
    end
  end
end

function Explorer:mutate_matrix(int)
  local roll = math.random()
  if roll < 0.4 then
    local s = math.random(1, 4)
    local d = math.random(1, 5)
    local val = math.random() < 0.6 and rand_delta(0.6 * int) or 0
    self:push({type="matrix_set", src=s, dst=d, val=val})
    self.last_mutation = "route"
  elseif roll < 0.7 then
    local which = math.random(1, 3)
    self:push({type="lfo_rate", which=which, delta=rand_delta(2.0 * int)})
    self.last_mutation = "lfo" .. which
  else
    local which = math.random(1, 3)
    self:push({type="lfo_shape", which=which, val=math.random(1, 4)})
    self.last_mutation = "shape"
  end
end

function Explorer:mutate_fx(int)
  local roll = math.random()
  if roll < 0.4 then
    self:push({type="delta", param="verb_room", delta=rand_delta(0.2 * int)})
    self.last_mutation = "room"
  elseif roll < 0.7 then
    self:push({type="delta", param="verb_damp", delta=rand_delta(0.2 * int)})
    self.last_mutation = "damp"
  else
    self:push({type="delta", param="verb_mix", delta=rand_delta(0.15 * int)})
    self.last_mutation = "verb"
  end
end

return Explorer
