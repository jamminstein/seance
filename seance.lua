-- seance
-- summoning analog ghosts
--
-- four spirits haunting this rack:
--   TAPE   — mellotron tape deck ensemble
--   MOOG   — minimoog 3-osc mono beast
--   SEQ    — doepfer/arp 1601 sequencer
--   MATRIX — arp 2500 modulation routing
--
-- three autonomous layers:
--   EXPLORER  — phase cycle (SUMMON/HAUNT/POSSESS/RELEASE)
--   BANDMATE  — style personality + breathing + song form
--   CHAOS     — polynomial modulation source (logistic map)
--
-- PERFORMANCE MACROS:
--   E1: SPIRIT — tape/moog blend + character
--   E2: FILTER — cutoff sweep + resonance
--   E3: CHAOS  — mutation density + seq wildness
--   (hold K3: E1=verb E2=porta E3=length)
--
-- KEYS:
--   K2 tap: play/stop
--   K2 long: cycle mindset
--   K3 tap: regenerate sequence
--   K3 hold: shift
--   K2+K3: toggle bandmate on/off
--
-- MINDSETS:
--   MELLOTRON / MINIMOOG / SEQUENCER / MODULAR / FULL SEANCE
--
-- MIDI in: plays tape (mellotron) voices
-- MIDI out: sequencer note output
-- grid: sequencer steps (always visible)

engine.name = "Seance"

local musicutil = require "musicutil"
local lattice_lib = require "lattice"
local Explorer = include "lib/explorer"
local Bandmate = include "lib/bandmate"
local Chaos = include "lib/chaos"

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local SEQ_MAX = 16
local DIVISIONS = {1, 1/2, 1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1", "1/2", "1/4", "1/8", "1/16", "1/32"}
local DIR_NAMES = {">>", "<<", "<>", "??"}
local SHAPE_NAMES = {"sin", "tri", "sqr", "ramp"}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- autonomous layers
local explorer = Explorer.new()
local bandmate = Bandmate.new()
local chaos = Chaos.new()

-- macro positions (0-1)
local macro = {
  spirit = 0.4,
  filter = 0.3,
  chaos = 0.2,
}

local shift = false
local k2_held = false
local k3_held = false
local k2_time = 0

-- tape (mellotron)
local tape_voices = {}
local tape_next_id = 1

-- moog
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

-- display
local anim_frame = 0
local reel_angle = 0
local flash_text = nil
local flash_timer = 0

-- hardware
local g = grid.connect()
local midi_out_device
local midi_in_device
local my_lattice
local seq_sprocket
local mod_sprocket
local beat_sprocket

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
  return seq.scale_notes[util.clamp(degree, 1, #seq.scale_notes)]
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
  -- add chaos modulation
  total = total + chaos:get_bipolar(math.min(dst_idx, 4)) * 0.15
  return total
end

local function lerp(a, b, t) return a + (b - a) * t end

local function set_flash(text)
  flash_text = text
  flash_timer = 12
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
  set_flash("REGEN")
end

----------------------------------------------------------------
-- MACRO APPLICATION
----------------------------------------------------------------

local function apply_spirit()
  local s = macro.spirit
  engine.tape_level(lerp(0.7, 0.12, s))
  engine.moog_level(lerp(0.12, 0.7, s))
  engine.tape_voice_type(s * 2)
  engine.verb_mix(lerp(0.45, 0.12, s))
end

local function apply_filter()
  local f = macro.filter
  local cutoff = 20 * math.pow(18000 / 20, f) + mod_sum(2) * 3000
  local res = lerp(0.1, 2.5, f * f) + mod_sum(3) * 0.8
  local tape_tone = lerp(400, 10000, f)
  engine.moog_cutoff(util.clamp(cutoff, 20, 18000))
  engine.moog_res(util.clamp(res, 0, 3.5))
  engine.tape_tone(util.clamp(tape_tone, 100, 12000))
end

local function apply_chaos_macro()
  local c = macro.chaos
  local div_idx = math.floor(lerp(2, 6, c) + 0.5)
  if seq_sprocket then
    seq_sprocket:set_division(DIVISIONS[util.clamp(div_idx, 1, 6)])
  end
  -- chaos smoothing: low chaos = smooth, high chaos = stepped
  chaos:set_smooth(lerp(0.8, 0.05, c))
end

local function apply_all_macros()
  apply_spirit()
  apply_filter()
  apply_chaos_macro()
end

----------------------------------------------------------------
-- CHANGE APPLICATION
-- both explorer and bandmate return pending changes
-- this function applies them uniformly
----------------------------------------------------------------

local function apply_changes(changes)
  if not changes then return end
  for _, ch in ipairs(changes) do
    if ch.type == "delta" then
      -- param delta
      if ch.param == "macro_spirit" then
        macro.spirit = util.clamp(macro.spirit + ch.delta, 0, 1)
        apply_spirit()
      elseif ch.param == "macro_filter" then
        macro.filter = util.clamp(macro.filter + ch.delta, 0.02, 0.98)
        apply_filter()
      elseif ch.param == "macro_chaos" then
        macro.chaos = util.clamp(macro.chaos + ch.delta, 0, 1)
        apply_chaos_macro()
      else
        params:delta(ch.param, ch.delta)
      end

    elseif ch.type == "seq_toggle" then
      local len = params:get("seq_length")
      for _ = 1, (ch.count or 1) do
        local s = math.random(1, len)
        seq.data[s].active = not seq.data[s].active
      end

    elseif ch.type == "seq_pitch" then
      local len = params:get("seq_length")
      for _ = 1, (ch.count or 1) do
        local s = math.random(1, len)
        local d = seq.data[s].degree + math.random(-(ch.range or 2), (ch.range or 2))
        seq.data[s].degree = util.clamp(d, 1, #seq.scale_notes)
      end

    elseif ch.type == "seq_direction" then
      seq.dir = math.random(1, 4)
      params:set("seq_direction", seq.dir)

    elseif ch.type == "seq_length" then
      local new_len = params:get("seq_length") + (ch.delta or 0)
      params:set("seq_length", util.clamp(new_len, 4, SEQ_MAX))

    elseif ch.type == "seq_scale" then
      params:set("seq_scale", math.random(1, #musicutil.SCALES))
      scale_generate()

    elseif ch.type == "seq_root" then
      local root = params:get("seq_root") + (ch.delta or 0)
      params:set("seq_root", util.clamp(root, 24, 72))
      scale_generate()

    elseif ch.type == "matrix_set" then
      if ch.src and ch.dst then
        matrix[ch.src][ch.dst] = ch.val or 0
      end

    elseif ch.type == "lfo_rate" then
      if ch.which then
        lfo.rate[ch.which] = util.clamp(lfo.rate[ch.which] + (ch.delta or 0), 0.01, 15)
        params:set("lfo_rate_" .. ch.which, lfo.rate[ch.which])
      end

    elseif ch.type == "lfo_shape" then
      if ch.which then
        lfo.shape[ch.which] = ch.val or 1
        params:set("lfo_shape_" .. ch.which, lfo.shape[ch.which])
      end

    elseif ch.type == "chaos_drift" then
      chaos:drift(ch.amount or 0.1)

    elseif ch.type == "home_pull" and bandmate:get_home_state() then
      -- gently pull macros toward saved home state
      local home = bandmate:get_home_state()
      local str = ch.strength or 0.05
      if home.spirit then
        macro.spirit = lerp(macro.spirit, home.spirit, str)
        apply_spirit()
      end
      if home.filter then
        macro.filter = lerp(macro.filter, home.filter, str)
        apply_filter()
      end
    end
  end
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
  -- chaos macro can override direction randomly
  if macro.chaos > 0.7 and math.random() < (macro.chaos - 0.7) * 2 then
    dir = 4
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

    moog_play(note, step.vel)

    if midi_out_device then
      midi_out_device:note_on(note, step.vel, params:get("midi_out_ch"))
    end

    if seq.pos % 4 == 1 then
      sh_val = math.random() * 2 - 1
    end
  end

  -- chaos step toggle at high chaos
  if macro.chaos > 0.8 and math.random() < (macro.chaos - 0.8) * 2.5 then
    local rs = math.random(1, params:get("seq_length"))
    seq.data[rs].active = not seq.data[rs].active
  end

  -- explorer step mutations
  local ex_changes = explorer:step(bandmate:get_weights())
  apply_changes(ex_changes)

  -- chaos polynomial advance
  chaos:step()
end

-- LFO/modulation tick (high rate)
local function mod_tick()
  for i = 1, 3 do
    lfo.phase[i] = lfo.phase[i] + (lfo.rate[i] / 96)
    if lfo.phase[i] > 1000 then lfo.phase[i] = lfo.phase[i] - 1000 end
    lfo.val[i] = lfo_compute(lfo.shape[i], lfo.phase[i])
  end
  -- modulation affects filter + warble + pw
  local w = params:get("tape_warble") + mod_sum(1) * 0.5
  engine.tape_warble(util.clamp(w, 0, 1))
  local p = params:get("moog_pw") + mod_sum(4) * 0.4
  engine.moog_pw(util.clamp(p, 0.05, 0.95))
  apply_filter()
end

-- beat tick: explorer phases + bandmate breathing/form
local function beat_tick()
  -- explorer phase progression
  explorer:beat(bandmate:get_pace())

  -- bandmate beat (breathing + form + style mutations)
  local bm_changes = bandmate:beat()
  apply_changes(bm_changes)

  -- sync explorer flash to display
  if explorer.flash and explorer.flash[2] > 0 then
    set_flash(explorer.flash[1])
    explorer.flash[2] = 0
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

  params:add_group("tape_grp", "TAPE (Mellotron)", 5)
  params:add_control("tape_warble", "warble", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("tape_warble", function(v) engine.tape_warble(v) end)
  params:add_control("tape_attack", "attack", controlspec.new(0.005, 2, 'exp', 0, 0.08, "s"))
  params:set_action("tape_attack", function(v) engine.tape_attack(v) end)
  params:add_control("tape_release", "release", controlspec.new(0.05, 8, 'exp', 0, 1.2, "s"))
  params:set_action("tape_release", function(v) engine.tape_release(v) end)
  params:add_control("tape_level", "level", controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("tape_level", function(v) engine.tape_level(v) end)
  params:add_control("tape_tone", "tone", controlspec.new(100, 12000, 'exp', 1, 2000, "hz"))
  params:set_action("tape_tone", function(v) engine.tape_tone(v) end)

  params:add_group("moog_grp", "MOOG (MiniMoog)", 7)
  params:add_control("moog_cutoff", "cutoff", controlspec.new(20, 18000, 'exp', 1, 1200, "hz"))
  params:set_action("moog_cutoff", function(v) engine.moog_cutoff(v) end)
  params:add_control("moog_res", "resonance", controlspec.new(0, 3.5, 'lin', 0.01, 0.3))
  params:set_action("moog_res", function(v) engine.moog_res(v) end)
  params:add_control("moog_porta", "portamento", controlspec.new(0, 2, 'lin', 0.001, 0.05, "s"))
  params:set_action("moog_porta", function(v) engine.moog_porta(v) end)
  params:add_control("moog_pw", "pulse width", controlspec.new(0.05, 0.95, 'lin', 0.01, 0.5))
  params:set_action("moog_pw", function(v) engine.moog_pw(v) end)
  params:add_control("moog_osc1", "osc 1 (saw)", controlspec.new(0, 1, 'lin', 0.01, 1.0))
  params:set_action("moog_osc1", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)
  params:add_control("moog_osc2", "osc 2 (pulse)", controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("moog_osc2", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)
  params:add_control("moog_osc3", "osc 3 (sub)", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("moog_osc3", function()
    engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3"))
  end)

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
      local n = {}
      for i, s in ipairs(musicutil.SCALES) do n[i] = s.name end
      return n
    end)(), 1)
  params:set_action("seq_scale", function() scale_generate() end)
  params:add_number("seq_swing", "swing", 50, 80, 50)

  params:add_group("fx_grp", "REVERB", 3)
  params:add_control("verb_mix", "mix", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("verb_mix", function(v) engine.verb_mix(v) end)
  params:add_control("verb_room", "room", controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("verb_room", function(v) engine.verb_room(v) end)
  params:add_control("verb_damp", "damp", controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("verb_damp", function(v) engine.verb_damp(v) end)

  params:add_group("midi_grp", "MIDI", 2)
  params:add_number("midi_out_ch", "midi out ch", 1, 16, 1)
  params:add_number("midi_in_ch", "midi in ch", 1, 16, 1)

  params:add_group("lfo_grp", "LFO (Modulation)", 6)
  for i = 1, 3 do
    params:add_control("lfo_rate_" .. i, "lfo " .. i .. " rate",
      controlspec.new(0.01, 20, 'exp', 0.01, lfo.rate[i], "hz"))
    params:set_action("lfo_rate_" .. i, function(v) lfo.rate[i] = v end)
    params:add_option("lfo_shape_" .. i, "lfo " .. i .. " shape", SHAPE_NAMES, lfo.shape[i])
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

  for i = 1, SEQ_MAX do
    seq.data[i] = {
      degree = math.random(1, math.min(#seq.scale_notes, 14)),
      vel = math.random(70, 127),
      active = math.random() > 0.25,
    }
  end

  for s = 1, 4 do
    matrix[s] = {}
    for d = 1, 5 do matrix[s][d] = 0 end
  end

  -- setup chaos routes
  chaos:route("tape_warble", 1, 0.1, 0)
  chaos:route("moog_cutoff", 2, 0.15, 0)
  chaos:route("moog_pw", 3, 0.1, 0)

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

  beat_sprocket = my_lattice:new_sprocket{
    action = beat_tick,
    division = 1/4,
    enabled = true,
  }

  my_lattice:start()

  apply_all_macros()
  explorer:enter_phase(1)

  -- screen refresh
  local scr = metro.init()
  scr.event = function()
    anim_frame = anim_frame + 1
    reel_angle = reel_angle + (seq.playing and 0.06 or 0.01)
    if flash_timer > 0 then flash_timer = flash_timer - 1 end
    redraw()
  end
  scr.time = 1 / 15
  scr:start()

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
      params:delta("verb_room", d)
    else
      macro.spirit = util.clamp(macro.spirit + d * 0.02, 0, 1)
      apply_spirit()
    end
  elseif n == 2 then
    if shift then
      params:delta("moog_porta", d)
    else
      macro.filter = util.clamp(macro.filter + d * 0.015, 0, 1)
      apply_filter()
    end
  elseif n == 3 then
    if shift then
      params:delta("seq_length", d)
    else
      macro.chaos = util.clamp(macro.chaos + d * 0.02, 0, 1)
      apply_chaos_macro()
    end
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_held = true
      k2_time = util.time()
      if k3_held then
        -- K2+K3: toggle bandmate + explorer
        local turning_on = not bandmate.active
        if turning_on then
          bandmate:start()
          explorer.active = true
          explorer:enter_phase(1, bandmate:get_pace())
          -- save current state as home
          bandmate:save_home({spirit=macro.spirit, filter=macro.filter})
          set_flash("BANDMATE ON")
        else
          bandmate:stop()
          explorer.active = false
          set_flash("MANUAL")
        end
      end
    else
      k2_held = false
      local held = util.time() - k2_time
      if not k3_held then
        if held > 0.5 then
          -- long press: cycle mindset
          local m = bandmate.mindset % #Bandmate.MINDSET_NAMES + 1
          bandmate:set_mindset(m)
          explorer.active = bandmate.active -- keep sync
          set_flash(Bandmate.MINDSET_NAMES[m])
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
      if k2_held then
        local turning_on = not bandmate.active
        if turning_on then
          bandmate:start()
          explorer.active = true
          explorer:enter_phase(1, bandmate:get_pace())
          bandmate:save_home({spirit=macro.spirit, filter=macro.filter})
          set_flash("BANDMATE ON")
        else
          bandmate:stop()
          explorer.active = false
          set_flash("MANUAL")
        end
      end
    else
      k3_held = false
      shift = false
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
  -- explorer intensity column + breathing indicator
  if bandmate.active then
    local int = explorer.intensity
    for y = 1, 8 do
      g:led(16, y, y <= math.floor(int * 8) and math.floor(int * 10) + 3 or 1)
    end
    -- breathing indicator on col 15
    local br = bandmate.energy
    for y = 1, 8 do
      g:led(15, y, y <= math.floor(br * 8) and math.floor(br * 8) + 2 or 0)
    end
  end
  g:refresh()
end

----------------------------------------------------------------
-- SCREEN
----------------------------------------------------------------

local function draw_bar(y, name, value, label)
  local bx, bw, bh = 34, 68, 5
  local fw = math.floor(value * bw)
  screen.level(10)
  screen.move(2, y + 4)
  screen.text(name)
  screen.level(2)
  screen.rect(bx, y, bw, bh)
  screen.fill()
  screen.level(8)
  screen.rect(bx, y, fw, bh)
  screen.fill()
  screen.level(3)
  screen.rect(bx, y, bw, bh)
  screen.stroke()
  screen.level(6)
  screen.move(106, y + 4)
  screen.text(label)
end

function redraw()
  screen.clear()

  -- header line
  screen.level(15)
  screen.move(2, 7)
  screen.text("seance")

  if bandmate.active then
    -- phase name
    screen.level(11)
    local pn = Explorer.PHASE_NAMES[explorer.phase]
    screen.move(128 - screen.text_extents(pn), 7)
    screen.text(pn)
    -- breathing state dot
    local bphase = bandmate.breath_phase
    local dot_b = bphase == "play" and 12 or (bphase == "silence" and 2 or 7)
    screen.level(dot_b)
    screen.circle(44, 4, 2)
    screen.fill()
  else
    screen.level(3)
    screen.move(112, 7)
    screen.text(seq.playing and "PLAY" or "stop")
  end

  -- flash
  if flash_timer > 0 and flash_text then
    screen.level(15)
    local fw = screen.text_extents(flash_text)
    screen.move(64 - fw / 2, 7)
    screen.text(flash_text)
  end

  screen.level(1)
  screen.move(0, 10)
  screen.line(128, 10)
  screen.stroke()

  -- macro bars
  local sp_label = macro.spirit < 0.35 and "TAPE" or (macro.spirit > 0.65 and "MOOG" or "blend")
  draw_bar(12, "SPIRIT", macro.spirit, sp_label)

  local cv = 20 * math.pow(18000 / 20, macro.filter)
  draw_bar(20, "FILTER", macro.filter,
    cv >= 1000 and string.format("%.1fk", cv / 1000) or string.format("%d", math.floor(cv)))

  draw_bar(28, "CHAOS", macro.chaos, string.format("%.0f%%", macro.chaos * 100))

  screen.level(1)
  screen.move(0, 36)
  screen.line(128, 36)
  screen.stroke()

  -- sequencer mini view
  local len = params:get("seq_length")
  local sw = math.max(2, math.floor(124 / len))
  local max_deg = math.max(#seq.scale_notes, 1)
  for i = 1, len do
    local x = 2 + (i - 1) * sw
    local step = seq.data[i]
    if step.active then
      local h = util.clamp(math.floor((step.degree / max_deg) * 16), 1, 16)
      screen.level(i == seq.pos and 15 or 4)
      screen.rect(x, 53 - h, sw - 1, h)
      screen.fill()
    else
      screen.level(1)
      screen.pixel(x, 52)
      screen.fill()
    end
    if i == seq.pos and seq.playing then
      screen.level(15)
      screen.rect(x, 54, sw - 1, 1)
      screen.fill()
    end
  end

  screen.level(1)
  screen.move(0, 57)
  screen.line(128, 57)
  screen.stroke()

  -- status bar: mindset + layers
  screen.level(bandmate.active and 10 or 4)
  screen.move(2, 64)
  screen.text(Bandmate.MINDSET_NAMES[bandmate.mindset])

  if bandmate.active then
    -- pulsing explore dot
    local pulse = math.floor(math.abs(math.sin(anim_frame * 0.12)) * 8) + 5
    screen.level(pulse)
    screen.circle(68, 62, 2)
    screen.fill()

    -- form phase
    screen.level(5)
    screen.move(74, 64)
    screen.text(bandmate.form_phase)

    -- last mutation
    if explorer.last_mutation ~= "" then
      screen.level(3)
      local lm = explorer.last_mutation
      screen.move(128 - screen.text_extents(lm), 64)
      screen.text(lm)
    end
  else
    screen.level(3)
    screen.move(74, 64)
    screen.text("manual")
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
