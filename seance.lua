-- seance
-- summoning analog ghosts
--
-- four spirits haunting this rack:
--   TAPE  — mellotron tape deck ensemble
--   MOOG  — minimoog 3-osc mono beast
--   SEQ   — doepfer/arp 1601 sequencer
--   MATRIX — arp 2500 modulation routing
--
-- PERFORMANCE MACROS:
--   ENC1: SPIRIT — tape/moog blend + character
--   ENC2: FILTER — cutoff sweep + resonance
--   ENC3: CHAOS  — mutation density + seq wildness
--   (hold K3 for shift: E1=verb E2=porta E3=length)
--
-- KEYS:
--   K2: play/stop sequencer
--   K3 tap: regenerate sequence
--   K2+K3: toggle explorer
--   K2 long press: cycle mindset
--
-- EXPLORER MINDSETS:
--   MELLOTRON / MINIMOOG / SEQUENCER / MODULAR / FULL SEANCE
--
-- EXPLORER PHASES:
--   SUMMON → HAUNT → POSSESS → RELEASE
--
-- MIDI in: plays tape (mellotron) voices
-- MIDI out: sequencer note output
-- grid: sequencer steps (always visible)

engine.name = "Seance"

local musicutil = require "musicutil"
local lattice_lib = require "lattice"

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local SEQ_MAX = 16
local DIVISIONS = {1, 1/2, 1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1", "1/2", "1/4", "1/8", "1/16", "1/32"}
local DIR_NAMES = {">>", "<<", "<>", "??"}
local VOICE_NAMES = {"strings", "flutes", "choir"}
local SHAPE_NAMES = {"sin", "tri", "sqr", "ramp"}

-- explorer
local PHASE_NAMES = {"SUMMON", "HAUNT", "POSSESS", "RELEASE"}
local MINDSET_NAMES = {"MELLOTRON", "MINIMOOG", "SEQUENCER", "MODULAR", "FULL SEANCE"}

-- phase configs: {duration_min, duration_max, intensity_start, intensity_end}
local PHASE_CONFIG = {
  {16, 32, 0.15, 0.45},  -- SUMMON: building
  {24, 48, 0.40, 0.70},  -- HAUNT: ghostly
  {16, 32, 0.70, 1.00},  -- POSSESS: full intensity
  {24, 40, 0.60, 0.15},  -- RELEASE: decaying
}

-- mindset mutation weights: {tape, moog, seq, matrix, fx}
local MINDSET_WEIGHTS = {
  {0.80, 0.10, 0.10, 0.30, 0.50},  -- MELLOTRON
  {0.20, 0.80, 0.20, 0.30, 0.40},  -- MINIMOOG
  {0.10, 0.20, 0.90, 0.20, 0.20},  -- SEQUENCER
  {0.30, 0.30, 0.20, 0.90, 0.40},  -- MODULAR
  {0.60, 0.60, 0.60, 0.60, 0.60},  -- FULL SEANCE
}

-- mindset mutation intervals (steps between mutations)
local MINDSET_INTERVALS = {12, 8, 4, 6, 6}

-- mindset phase duration multipliers
local MINDSET_PACE = {1.5, 0.8, 0.7, 1.0, 1.0}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- macro positions (0-1)
local macro = {
  spirit = 0.4,   -- E1: tape(0) ↔ moog(1)
  filter = 0.3,   -- E2: filter sweep
  chaos = 0.2,    -- E3: chaos level
}

local shift = false
local k2_held = false
local k3_held = false
local k2_time = 0

-- tape (mellotron) voice tracking
local tape_voices = {}
local tape_next_id = 1

-- moog mono state
local moog_note_on = false

-- sequencer
local seq = {
  data = {},
  pos = 0,
  playing = false,
  dir = 1,
  pend_fwd = true,
  last_note = nil,
  scale_notes = {},
}

-- matrix (arp 2500)
local matrix = {}

-- lfos
local lfo = {
  phase = {0, 0, 0},
  rate = {0.2, 0.8, 2.5},
  shape = {1, 2, 3},
  val = {0, 0, 0},
}
local sh_val = 0

-- explorer
local explorer = {
  active = false,
  mindset = 5,           -- start on FULL SEANCE
  phase = 1,             -- SUMMON
  phase_beat = 0,        -- beats into current phase
  phase_length = 96,     -- beats for this phase (will be set on phase enter)
  intensity = 0.3,
  intensity_start = 0.15,
  intensity_end = 0.45,
  mutation_clock = 0,
  flash = nil,           -- flash indicator: {name, timer}
  last_mutation = "",     -- what just changed
}

-- display
local anim_frame = 0
local reel_angle = 0

-- hardware
local g = grid.connect()
local midi_out_device
local midi_in_device
local my_lattice
local seq_sprocket
local mod_sprocket
local explorer_sprocket

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function scale_generate()
  local s = musicutil.SCALES[params:get("seq_scale")]
  seq.scale_notes = musicutil.generate_scale(
    params:get("seq_root"), s.name, 4
  )
end

local function note_in_scale(degree)
  if #seq.scale_notes == 0 then return 60 end
  local idx = util.clamp(degree, 1, #seq.scale_notes)
  return seq.scale_notes[idx]
end

local function lfo_compute(shape, ph)
  local p = ph % 1
  if shape == 1 then return math.sin(p * 2 * math.pi)
  elseif shape == 2 then return p < 0.5 and (p * 4 - 1) or (3 - p * 4)
  elseif shape == 3 then return p < 0.5 and 1 or -1
  else return p * 2 - 1 end
end

local function mod_sum(dst_idx)
  local total = 0
  for s = 1, 4 do
    local val = s <= 3 and lfo.val[s] or sh_val
    total = total + (matrix[s][dst_idx] * val)
  end
  return total
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function rand_delta(range)
  return (math.random() * 2 - 1) * range
end

local function seq_regenerate()
  scale_generate()
  for i = 1, SEQ_MAX do
    seq.data[i] = {
      degree = math.random(1, math.min(#seq.scale_notes, 14)),
      vel = math.random(70, 127),
      active = math.random() > 0.25,
    }
  end
  explorer.flash = {"REGEN", 8}
end

local function explorer_flash(name)
  explorer.flash = {name, 6}
end

----------------------------------------------------------------
-- MACRO APPLICATION
-- maps macro knob positions → engine params
----------------------------------------------------------------

local function apply_spirit()
  local s = macro.spirit
  -- crossfade tape ↔ moog
  local tape_lvl = lerp(0.7, 0.15, s)
  local moog_lvl = lerp(0.15, 0.7, s)
  engine.tape_level(tape_lvl)
  engine.moog_level(moog_lvl)
  -- tape voice morphs with spirit
  engine.tape_voice_type(s * 2) -- 0=strings → 2=choir
  -- more tape = more reverb
  local verb = lerp(0.45, 0.15, s)
  engine.verb_mix(verb)
end

local function apply_filter()
  local f = macro.filter
  -- exponential mapping for cutoff (20-18000)
  local cutoff = 20 * math.pow(18000/20, f)
  -- resonance rises with cutoff, tastefully
  local res = lerp(0.1, 2.5, f * f)
  -- tape tone follows
  local tape_tone = lerp(400, 10000, f)
  engine.moog_cutoff(cutoff + mod_sum(2) * 4000)
  engine.moog_res(util.clamp(res + mod_sum(3) * 1.0, 0, 3.5))
  engine.tape_tone(util.clamp(tape_tone, 100, 12000))
end

local function apply_chaos()
  -- chaos affects explorer mutation rate and seq behavior
  -- but also immediately affects seq division
  local c = macro.chaos
  local div_idx = math.floor(lerp(2, 6, c) + 0.5)
  if seq_sprocket then
    seq_sprocket:set_division(DIVISIONS[util.clamp(div_idx, 1, 6)])
  end
end

local function apply_all_macros()
  apply_spirit()
  apply_filter()
  apply_chaos()
end

----------------------------------------------------------------
-- MODULATION (runs at high rate)
----------------------------------------------------------------

local function update_modulation()
  -- tape warble from params + modulation
  local w = params:get("tape_warble") + mod_sum(1) * 0.5
  engine.tape_warble(util.clamp(w, 0, 1))

  -- moog pw from params + modulation
  local p = params:get("moog_pw") + mod_sum(4) * 0.4
  engine.moog_pw(util.clamp(p, 0.05, 0.95))

  -- re-apply filter (modulation sources change)
  apply_filter()
end

----------------------------------------------------------------
-- TAPE (MELLOTRON)
----------------------------------------------------------------

local function tape_note_on(note, vel)
  local id = tape_next_id
  tape_next_id = tape_next_id + 1
  if tape_next_id > 10000 then tape_next_id = 1 end
  tape_voices[note] = id
  engine.tape_on(id, musicutil.note_num_to_freq(note), vel)
end

local function tape_note_off(note)
  local id = tape_voices[note]
  if id then
    engine.tape_off(id)
    tape_voices[note] = nil
  end
end

----------------------------------------------------------------
-- MOOG
----------------------------------------------------------------

local function moog_play(note, vel)
  engine.moog_hz(musicutil.note_num_to_freq(note))
  engine.moog_vel(vel)
  if not moog_note_on then
    engine.moog_gate(1)
    moog_note_on = true
  end
  seq.last_note = note
end

local function moog_stop()
  if moog_note_on then
    engine.moog_gate(0)
    moog_note_on = false
  end
end

----------------------------------------------------------------
-- SEQUENCER
----------------------------------------------------------------

local function seq_advance()
  local len = params:get("seq_length")
  local dir = seq.dir
  -- chaos can override direction
  if macro.chaos > 0.7 and math.random() < (macro.chaos - 0.7) * 2 then
    dir = 4 -- random
  end

  if dir == 1 then
    seq.pos = seq.pos % len + 1
  elseif dir == 2 then
    seq.pos = seq.pos - 1
    if seq.pos < 1 then seq.pos = len end
  elseif dir == 3 then
    if seq.pend_fwd then
      seq.pos = seq.pos + 1
      if seq.pos >= len then seq.pend_fwd = false end
    else
      seq.pos = seq.pos - 1
      if seq.pos <= 1 then seq.pend_fwd = true end
    end
    seq.pos = util.clamp(seq.pos, 1, len)
  else
    seq.pos = math.random(1, len)
  end
end

local function seq_tick()
  if not seq.playing then return end

  -- stop previous note
  if seq.last_note then
    moog_stop()
    if midi_out_device then
      midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
    end
    seq.last_note = nil
  end

  seq_advance()

  local step = seq.data[seq.pos]
  if step and step.active then
    local xpose = math.floor(mod_sum(5) * 12 + 0.5)
    local degree = util.clamp(step.degree + xpose, 1, #seq.scale_notes)
    local note = note_in_scale(degree)
    local vel = step.vel

    moog_play(note, vel)

    if midi_out_device then
      midi_out_device:note_on(note, vel, params:get("midi_out_ch"))
    end

    -- s&h trigger every 4 steps
    if seq.pos % 4 == 1 then
      sh_val = math.random() * 2 - 1
    end
  end

  -- chaos: random step toggling
  if macro.chaos > 0.8 and math.random() < (macro.chaos - 0.8) * 3 then
    local rand_step = math.random(1, params:get("seq_length"))
    seq.data[rand_step].active = not seq.data[rand_step].active
  end

  -- explorer mutation clock
  if explorer.active then
    explorer.mutation_clock = explorer.mutation_clock + 1
    local interval = MINDSET_INTERVALS[explorer.mindset]
    if explorer.mutation_clock >= interval then
      explorer.mutation_clock = 0
      explorer_mutate()
    end
  end
end

local function mod_tick()
  for i = 1, 3 do
    lfo.phase[i] = lfo.phase[i] + (lfo.rate[i] / 96)
    if lfo.phase[i] > 1000 then lfo.phase[i] = lfo.phase[i] - 1000 end
    lfo.val[i] = lfo_compute(lfo.shape[i], lfo.phase[i])
  end
  update_modulation()
end

----------------------------------------------------------------
-- EXPLORER SYSTEM
----------------------------------------------------------------

local function explorer_enter_phase(phase_num)
  explorer.phase = phase_num
  explorer.phase_beat = 0
  local cfg = PHASE_CONFIG[phase_num]
  local pace = MINDSET_PACE[explorer.mindset]
  local dur_min = math.floor(cfg[1] * pace)
  local dur_max = math.floor(cfg[2] * pace)
  explorer.phase_length = math.random(dur_min, dur_max) * 4 -- convert bars to beats
  explorer.intensity_start = cfg[3]
  explorer.intensity_end = cfg[4]
  explorer.intensity = cfg[3]
  explorer_flash(PHASE_NAMES[phase_num])
end

local function explorer_next_phase()
  local next = explorer.phase % 4 + 1
  explorer_enter_phase(next)
end

-- mutation functions for each domain
local function mutate_tape(intensity)
  local roll = math.random()
  if roll < 0.3 then
    -- warble drift
    local w = params:get("tape_warble") + rand_delta(0.15 * intensity)
    params:set("tape_warble", util.clamp(w, 0.05, 0.9))
    explorer.last_mutation = "warble"
  elseif roll < 0.6 then
    -- voice morph via spirit macro
    macro.spirit = util.clamp(macro.spirit + rand_delta(0.15 * intensity), 0, 1)
    apply_spirit()
    explorer.last_mutation = "spirit"
  elseif roll < 0.8 then
    -- attack/release drift
    local a = params:get("tape_attack") + rand_delta(0.3 * intensity)
    params:set("tape_attack", util.clamp(a, 0.005, 1.5))
    explorer.last_mutation = "tape env"
  else
    -- release drift
    local r = params:get("tape_release") + rand_delta(1.0 * intensity)
    params:set("tape_release", util.clamp(r, 0.1, 6.0))
    explorer.last_mutation = "tape rel"
  end
end

local function mutate_moog(intensity)
  local roll = math.random()
  if roll < 0.35 then
    -- filter sweep via macro
    macro.filter = util.clamp(macro.filter + rand_delta(0.2 * intensity), 0.05, 0.95)
    apply_filter()
    explorer.last_mutation = "filter"
  elseif roll < 0.55 then
    -- pulse width drift
    local pw = params:get("moog_pw") + rand_delta(0.2 * intensity)
    params:set("moog_pw", util.clamp(pw, 0.1, 0.9))
    explorer.last_mutation = "pw"
  elseif roll < 0.75 then
    -- osc mix shift
    local which = math.random(1, 3)
    local names = {"moog_osc1", "moog_osc2", "moog_osc3"}
    local v = params:get(names[which]) + rand_delta(0.3 * intensity)
    params:set(names[which], util.clamp(v, 0.0, 1.0))
    explorer.last_mutation = "osc mix"
  else
    -- portamento shift
    local p = params:get("moog_porta") + rand_delta(0.15 * intensity)
    params:set("moog_porta", util.clamp(p, 0, 0.8))
    explorer.last_mutation = "porta"
  end
end

local function mutate_seq(intensity)
  local len = params:get("seq_length")
  local roll = math.random()
  if roll < 0.3 then
    -- toggle 1-3 steps
    local count = math.ceil(intensity * 3)
    for _ = 1, count do
      local s = math.random(1, len)
      seq.data[s].active = not seq.data[s].active
    end
    explorer.last_mutation = "steps"
  elseif roll < 0.5 then
    -- shift pitches
    local count = math.ceil(intensity * 4)
    for _ = 1, count do
      local s = math.random(1, len)
      local d = seq.data[s].degree + math.random(-3, 3)
      seq.data[s].degree = util.clamp(d, 1, #seq.scale_notes)
    end
    explorer.last_mutation = "pitch"
  elseif roll < 0.65 then
    -- change direction
    seq.dir = math.random(1, 4)
    params:set("seq_direction", seq.dir)
    explorer.last_mutation = "dir " .. DIR_NAMES[seq.dir]
  elseif roll < 0.8 then
    -- change length
    local new_len = len + math.random(-2, 2)
    params:set("seq_length", util.clamp(new_len, 4, SEQ_MAX))
    explorer.last_mutation = "len"
  else
    -- change scale (dramatic!)
    if intensity > 0.6 then
      local num_scales = #musicutil.SCALES
      params:set("seq_scale", math.random(1, num_scales))
      scale_generate()
      explorer.last_mutation = "scale!"
    else
      -- shift root
      local root = params:get("seq_root") + math.random(-2, 2)
      params:set("seq_root", util.clamp(root, 24, 72))
      scale_generate()
      explorer.last_mutation = "root"
    end
  end
end

local function mutate_matrix(intensity)
  local roll = math.random()
  if roll < 0.4 then
    -- set/clear a random routing
    local s = math.random(1, 4)
    local d = math.random(1, 5)
    if math.random() < 0.6 then
      matrix[s][d] = rand_delta(0.7 * intensity)
    else
      matrix[s][d] = 0
    end
    explorer.last_mutation = "route"
  elseif roll < 0.7 then
    -- change lfo rate
    local which = math.random(1, 3)
    lfo.rate[which] = util.clamp(lfo.rate[which] + rand_delta(1.5 * intensity), 0.01, 15)
    params:set("lfo_rate_" .. which, lfo.rate[which])
    explorer.last_mutation = "lfo" .. which
  else
    -- change lfo shape
    local which = math.random(1, 3)
    lfo.shape[which] = math.random(1, 4)
    params:set("lfo_shape_" .. which, lfo.shape[which])
    explorer.last_mutation = "shape"
  end
end

local function mutate_fx(intensity)
  local roll = math.random()
  if roll < 0.5 then
    local room = params:get("verb_room") + rand_delta(0.2 * intensity)
    params:set("verb_room", util.clamp(room, 0.1, 0.95))
    explorer.last_mutation = "room"
  else
    local damp = params:get("verb_damp") + rand_delta(0.2 * intensity)
    params:set("verb_damp", util.clamp(damp, 0.1, 0.9))
    explorer.last_mutation = "damp"
  end
end

function explorer_mutate()
  local weights = MINDSET_WEIGHTS[explorer.mindset]
  local intensity = explorer.intensity

  -- roll for each domain
  if math.random() < weights[1] * intensity then mutate_tape(intensity) end
  if math.random() < weights[2] * intensity then mutate_moog(intensity) end
  if math.random() < weights[3] * intensity then mutate_seq(intensity) end
  if math.random() < weights[4] * intensity then mutate_matrix(intensity) end
  if math.random() < weights[5] * intensity then mutate_fx(intensity) end
end

local function explorer_beat_tick()
  if not explorer.active then return end

  explorer.phase_beat = explorer.phase_beat + 1

  -- lerp intensity
  local progress = explorer.phase_beat / math.max(explorer.phase_length, 1)
  progress = util.clamp(progress, 0, 1)
  explorer.intensity = lerp(explorer.intensity_start, explorer.intensity_end, progress)

  -- phase transition
  if explorer.phase_beat >= explorer.phase_length then
    explorer_next_phase()
  end
end

----------------------------------------------------------------
-- MIDI INPUT
----------------------------------------------------------------

local function on_midi_event(data)
  local msg = midi.to_msg(data)
  if msg.ch ~= params:get("midi_in_ch") then return end
  if msg.type == "note_on" and msg.vel > 0 then
    tape_note_on(msg.note, msg.vel)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    tape_note_off(msg.note)
  end
end

----------------------------------------------------------------
-- PARAMS
----------------------------------------------------------------

local function setup_params()
  params:add_separator("SEANCE")

  -- TAPE
  params:add_group("tape_grp", "TAPE (Mellotron)", 5)
  params:add_control("tape_warble", "warble",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("tape_warble", function(v) engine.tape_warble(v) end)
  params:add_control("tape_attack", "attack",
    controlspec.new(0.005, 2, 'exp', 0, 0.08, "s"))
  params:set_action("tape_attack", function(v) engine.tape_attack(v) end)
  params:add_control("tape_release", "release",
    controlspec.new(0.05, 8, 'exp', 0, 1.2, "s"))
  params:set_action("tape_release", function(v) engine.tape_release(v) end)
  params:add_control("tape_level", "level",
    controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("tape_level", function(v) engine.tape_level(v) end)
  params:add_control("tape_tone", "tone",
    controlspec.new(100, 12000, 'exp', 1, 2000, "hz"))
  params:set_action("tape_tone", function(v) engine.tape_tone(v) end)

  -- MOOG
  params:add_group("moog_grp", "MOOG (MiniMoog)", 7)
  params:add_control("moog_cutoff", "cutoff",
    controlspec.new(20, 18000, 'exp', 1, 1200, "hz"))
  params:set_action("moog_cutoff", function(v) engine.moog_cutoff(v) end)
  params:add_control("moog_res", "resonance",
    controlspec.new(0, 3.5, 'lin', 0.01, 0.3))
  params:set_action("moog_res", function(v) engine.moog_res(v) end)
  params:add_control("moog_porta", "portamento",
    controlspec.new(0, 2, 'lin', 0.001, 0.05, "s"))
  params:set_action("moog_porta", function(v) engine.moog_porta(v) end)
  params:add_control("moog_pw", "pulse width",
    controlspec.new(0.05, 0.95, 'lin', 0.01, 0.5))
  params:set_action("moog_pw", function(v) engine.moog_pw(v) end)
  params:add_control("moog_osc1", "osc 1 (saw)",
    controlspec.new(0, 1, 'lin', 0.01, 1.0))
  params:set_action("moog_osc1", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)
  params:add_control("moog_osc2", "osc 2 (pulse)",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("moog_osc2", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)
  params:add_control("moog_osc3", "osc 3 (sub)",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("moog_osc3", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)

  -- SEQUENCER
  params:add_group("seq_grp", "SEQUENCER (1601)", 6)
  params:add_number("seq_length", "length", 1, SEQ_MAX, 16)
  params:add_option("seq_division", "division", DIV_NAMES, 5)
  params:set_action("seq_division", function(v)
    if seq_sprocket then seq_sprocket:set_division(DIVISIONS[v]) end
  end)
  params:add_option("seq_direction", "direction", DIR_NAMES, 1)
  params:set_action("seq_direction", function(v) seq.dir = v end)
  params:add_number("seq_root", "root note", 24, 72, 36)
  params:set_action("seq_root", function() scale_generate() end)
  params:add_option("seq_scale", "scale",
    (function()
      local names = {}
      for i, s in ipairs(musicutil.SCALES) do names[i] = s.name end
      return names
    end)(), 1)
  params:set_action("seq_scale", function() scale_generate() end)
  params:add_number("seq_swing", "swing", 50, 80, 50)

  -- REVERB
  params:add_group("fx_grp", "REVERB", 3)
  params:add_control("verb_mix", "mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("verb_mix", function(v) engine.verb_mix(v) end)
  params:add_control("verb_room", "room",
    controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("verb_room", function(v) engine.verb_room(v) end)
  params:add_control("verb_damp", "damp",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("verb_damp", function(v) engine.verb_damp(v) end)

  -- MIDI
  params:add_group("midi_grp", "MIDI", 2)
  params:add_number("midi_out_ch", "midi out ch", 1, 16, 1)
  params:add_number("midi_in_ch", "midi in ch", 1, 16, 1)

  -- LFOs
  params:add_group("lfo_grp", "LFO (Modulation)", 6)
  for i = 1, 3 do
    params:add_control("lfo_rate_" .. i, "lfo " .. i .. " rate",
      controlspec.new(0.01, 20, 'exp', 0.01, lfo.rate[i], "hz"))
    params:set_action("lfo_rate_" .. i, function(v) lfo.rate[i] = v end)
    params:add_option("lfo_shape_" .. i, "lfo " .. i .. " shape",
      SHAPE_NAMES, lfo.shape[i])
    params:set_action("lfo_shape_" .. i, function(v) lfo.shape[i] = v end)
  end
end

----------------------------------------------------------------
-- INIT
----------------------------------------------------------------

function init()
  setup_params()

  midi_out_device = midi.connect(1)
  midi_in_device = midi.connect(1)
  midi_in_device.event = on_midi_event

  scale_generate()

  -- init sequencer
  for i = 1, SEQ_MAX do
    seq.data[i] = {
      degree = math.random(1, math.min(#seq.scale_notes, 14)),
      vel = math.random(70, 127),
      active = math.random() > 0.25,
    }
  end

  -- init matrix
  for s = 1, 4 do
    matrix[s] = {}
    for d = 1, 5 do
      matrix[s][d] = 0
    end
  end

  -- lattice
  my_lattice = lattice_lib:new()

  seq_sprocket = my_lattice:new_sprocket{
    action = seq_tick,
    division = DIVISIONS[params:get("seq_division")],
    enabled = true,
  }

  mod_sprocket = my_lattice:new_sprocket{
    action = mod_tick,
    division = 1/96,
    enabled = true,
  }

  explorer_sprocket = my_lattice:new_sprocket{
    action = explorer_beat_tick,
    division = 1/4,
    enabled = true,
  }

  my_lattice:start()

  -- apply initial macros
  apply_all_macros()

  -- init explorer phase
  explorer_enter_phase(1)

  -- screen refresh
  local screen_metro = metro.init()
  screen_metro.event = function()
    anim_frame = anim_frame + 1
    reel_angle = reel_angle + (seq.playing and 0.06 or 0.01)
    -- decay flash
    if explorer.flash and explorer.flash[2] > 0 then
      explorer.flash[2] = explorer.flash[2] - 1
    end
    redraw()
  end
  screen_metro.time = 1 / 15
  screen_metro:start()

  -- grid
  if g.device then
    g.key = grid_key
    grid_redraw()
  end
end

----------------------------------------------------------------
-- INPUT
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    if shift then
      -- shift+E1: reverb room
      params:delta("verb_room", d)
    else
      -- SPIRIT macro
      macro.spirit = util.clamp(macro.spirit + d * 0.02, 0, 1)
      apply_spirit()
    end

  elseif n == 2 then
    if shift then
      -- shift+E2: portamento
      params:delta("moog_porta", d)
    else
      -- FILTER macro
      macro.filter = util.clamp(macro.filter + d * 0.015, 0, 1)
      apply_filter()
    end

  elseif n == 3 then
    if shift then
      -- shift+E3: seq length
      params:delta("seq_length", d)
    else
      -- CHAOS macro
      macro.chaos = util.clamp(macro.chaos + d * 0.02, 0, 1)
      apply_chaos()
    end
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_held = true
      k2_time = util.time()
      -- check K2+K3 combo
      if k3_held then
        explorer.active = not explorer.active
        if explorer.active then
          explorer_enter_phase(1)
          explorer_flash("EXPLORE")
        else
          explorer_flash("MANUAL")
        end
      end
    else
      k2_held = false
      local held_time = util.time() - k2_time
      if not k3_held then
        if held_time > 0.5 then
          -- long press: cycle mindset
          explorer.mindset = explorer.mindset % #MINDSET_NAMES + 1
          explorer_flash(MINDSET_NAMES[explorer.mindset])
        else
          -- short press: play/stop
          seq.playing = not seq.playing
          if not seq.playing then
            moog_stop()
            if seq.last_note and midi_out_device then
              midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
            end
            seq.last_note = nil
            seq.pos = 0
          end
        end
      end
    end

  elseif n == 3 then
    if z == 1 then
      k3_held = true
      shift = true
      -- check K2+K3 combo
      if k2_held then
        explorer.active = not explorer.active
        if explorer.active then
          explorer_enter_phase(1)
          explorer_flash("EXPLORE")
        else
          explorer_flash("MANUAL")
        end
      end
    else
      k3_held = false
      shift = false
      -- short tap (if K2 wasn't held): regenerate
      if not k2_held then
        seq_regenerate()
      end
    end
  end
end

----------------------------------------------------------------
-- GRID
----------------------------------------------------------------

function grid_key(x, y, z)
  if z == 0 then return end
  local len = params:get("seq_length")
  if x <= len then
    if y == 1 then
      seq.data[x].active = not seq.data[x].active
    elseif y >= 2 and y <= 8 then
      seq.data[x].degree = util.clamp((9 - y) * 2, 1, #seq.scale_notes)
      seq.data[x].active = true
    end
  end
  grid_redraw()
end

function grid_redraw()
  if not g.device then return end
  g:all(0)
  local len = params:get("seq_length")
  for x = 1, math.min(16, len) do
    local step = seq.data[x]
    if x == seq.pos and seq.playing then
      for y = 1, 8 do g:led(x, y, 2) end
    end
    if step.active then
      local row = util.clamp(9 - math.ceil(step.degree / 2), 2, 8)
      g:led(x, row, x == seq.pos and 15 or 8)
    end
    g:led(x, 1, step.active and 6 or 1)
  end
  -- explorer intensity on right columns
  if explorer.active then
    local bright = math.floor(explorer.intensity * 12) + 2
    for y = 1, 8 do
      g:led(16, y, y <= math.floor(explorer.intensity * 8) and bright or 1)
    end
  end
  g:refresh()
end

----------------------------------------------------------------
-- SCREEN
----------------------------------------------------------------

local function draw_macro_bar(y, name, value, label_right)
  local bar_x = 32
  local bar_w = 72
  local bar_h = 6
  local fill_w = math.floor(value * bar_w)

  -- name
  screen.level(10)
  screen.move(2, y + 5)
  screen.text(name)

  -- bar background
  screen.level(2)
  screen.rect(bar_x, y, bar_w, bar_h)
  screen.fill()

  -- bar fill
  screen.level(8)
  screen.rect(bar_x, y, fill_w, bar_h)
  screen.fill()

  -- bar outline
  screen.level(4)
  screen.rect(bar_x, y, bar_w, bar_h)
  screen.stroke()

  -- right label
  screen.level(6)
  screen.move(108, y + 5)
  screen.text(label_right)
end

function redraw()
  screen.clear()

  -- header
  screen.level(15)
  screen.move(2, 7)
  screen.text("seance")

  -- phase name (if explorer active)
  if explorer.active then
    screen.level(12)
    local phase_name = PHASE_NAMES[explorer.phase]
    screen.move(128 - screen.text_extents(phase_name), 7)
    screen.text(phase_name)

    -- intensity dot
    local dot_bright = math.floor(explorer.intensity * 12) + 3
    screen.level(dot_bright)
    screen.circle(42, 4, 2)
    screen.fill()
  else
    screen.level(3)
    screen.move(108, 7)
    screen.text(seq.playing and "PLAY" or "stop")
  end

  -- flash indicator
  if explorer.flash and explorer.flash[2] > 0 then
    screen.level(15)
    screen.move(50, 7)
    screen.text(explorer.flash[1])
  end

  -- separator
  screen.level(2)
  screen.move(0, 10)
  screen.line(128, 10)
  screen.stroke()

  -- macro bars
  local spirit_label = macro.spirit < 0.4 and "TAPE" or (macro.spirit > 0.6 and "MOOG" or "blend")
  draw_macro_bar(13, "SPIRIT", macro.spirit, spirit_label)

  local cutoff_val = 20 * math.pow(18000/20, macro.filter)
  local cutoff_str = cutoff_val >= 1000 and string.format("%.1fk", cutoff_val/1000)
    or string.format("%d", math.floor(cutoff_val))
  draw_macro_bar(22, "FILTER", macro.filter, cutoff_str)

  draw_macro_bar(31, "CHAOS", macro.chaos, string.format("%.0f%%", macro.chaos * 100))

  -- separator
  screen.level(2)
  screen.move(0, 40)
  screen.line(128, 40)
  screen.stroke()

  -- sequencer mini view
  local len = params:get("seq_length")
  local step_w = math.max(2, math.floor(124 / len))
  local max_deg = math.max(#seq.scale_notes, 1)

  for i = 1, len do
    local x = 2 + (i - 1) * step_w
    local step = seq.data[i]

    if step.active then
      local h = math.floor((step.degree / max_deg) * 14)
      h = util.clamp(h, 1, 14)
      screen.level(i == seq.pos and 15 or 4)
      screen.rect(x, 54 - h, step_w - 1, h)
      screen.fill()
    else
      screen.level(1)
      screen.pixel(x, 53)
      screen.fill()
    end

    if i == seq.pos and seq.playing then
      screen.level(15)
      screen.rect(x, 55, step_w - 1, 1)
      screen.fill()
    end
  end

  -- bottom status bar
  screen.level(2)
  screen.move(0, 58)
  screen.line(128, 58)
  screen.stroke()

  -- mindset + explorer status
  screen.level(explorer.active and 10 or 4)
  screen.move(2, 64)
  screen.text(MINDSET_NAMES[explorer.mindset])

  if explorer.active then
    -- pulsing dot
    local pulse = math.floor(math.abs(math.sin(anim_frame * 0.15)) * 10) + 5
    screen.level(pulse)
    screen.circle(72, 62, 2)
    screen.fill()
    screen.level(6)
    screen.move(77, 64)
    screen.text("exploring")
  else
    screen.level(3)
    screen.move(72, 64)
    screen.text("manual")
  end

  -- last mutation indicator (subtle)
  if explorer.active and explorer.last_mutation ~= "" then
    screen.level(3)
    screen.move(128 - screen.text_extents(explorer.last_mutation), 64)
    screen.text(explorer.last_mutation)
  end

  screen.update()
  grid_redraw()
end

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------

function cleanup()
  if my_lattice then my_lattice:destroy() end
  engine.tape_all_off()
  moog_stop()
  if midi_out_device and seq.last_note then
    midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
  end
end
