-- seance
-- summoning analog ghosts
--
-- four spirits haunting this rack:
--   TAPE   — mellotron tape deck ensemble
--   MOOG   — minimoog 3-osc mono beast
--   SEQ    — doepfer/arp 1601 sequencer
--   MATRIX — arp 2500 modulation routing
--
-- four autonomous layers:
--   EXPLORER  — phase cycle (SUMMON/HAUNT/POSSESS/RELEASE)
--   BANDMATE  — style personality + breathing + song form
--   CHAOS     — polynomial modulation source
--   CONDUCTOR — robot mod, tames/rides params by personality
--
-- PAGES: E1 to navigate
--   PLAY   — macro performance (E2=filter E3=spirit)
--   SEQ    — sequencer view (E2=pitch E3=length)
--   MATRIX — mod routing (E2=navigate E3=amount)
--   ROBOT  — conductor status (E2=mindset E3=personality)
--
-- KEYS:
--   K2 tap: play/stop
--   K2 long: cycle mindset
--   K3 tap: regenerate sequence
--   K3 hold: shift (E2=chaos E3=verb room)
--   K2+K3: toggle robot on/off
--
-- MIDI in: mellotron voices | MIDI out: sequencer

engine.name = "Seance"

local musicutil = require "musicutil"
local lattice_lib = require "lattice"
local Explorer = include "lib/explorer"
local Bandmate = include "lib/bandmate"
local Chaos = include "lib/chaos"
local robot_profile = include "lib/robot_profile"

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local SEQ_MAX = 16
local DIVISIONS = {1, 1/2, 1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1", "1/2", "1/4", "1/8", "1/16", "1/32"}
local DIR_NAMES = {">>", "<<", "<>", "??"}
local SHAPE_NAMES = {"sin", "tri", "sqr", "ramp"}
local PAGES = {"PLAY", "SEQ", "MATRIX", "ROBOT"}
local MOD_SRC = {"LFO1", "LFO2", "LFO3", "S&H"}
local MOD_DST = {"warbl", "cut", "res", "pw", "xpos"}
local MOD_DST_FULL = {"warble", "cutoff", "res", "pw", "transpose"}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- autonomous layers
local explorer = Explorer.new()
local bandmate = Bandmate.new()
local chaos = Chaos.new()

-- robot / conductor
local robot = {
  active = false,
  personality = 1,  -- 1=chill, 2=aggressive, 3=chaotic
  conductor_beat = 0,
}

-- ui
local page = 1
local shift = false
local k2_held = false
local k3_held = false
local k2_time = 0
local flash_text = nil
local flash_timer = 0
local anim_frame = 0
local reel_angle = 0
local mat_cursor = {1, 1}

-- macros (0-1)
local macro = {spirit = 0.4, filter = 0.3, chaos = 0.2}

-- tape
local tape_voices = {}
local tape_next_id = 1

-- moog
local moog_note_on = false

-- sequencer
local seq = {
  data = {}, pos = 0, playing = false,
  dir = 1, pend_fwd = true, last_note = nil, scale_notes = {},
}

-- matrix
local matrix = {}

-- lfos
local lfo = {
  phase = {0, 0, 0},
  rate = {0.2, 0.8, 2.5},
  shape = {1, 2, 3},
  val = {0, 0, 0},
}
local sh_val = 0

-- hardware
local g = grid.connect()
local midi_out_device, midi_in_device
local my_lattice, seq_sprocket, mod_sprocket, beat_sprocket

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function scale_generate()
  local s = musicutil.SCALES[params:get("seq_scale")]
  seq.scale_notes = musicutil.generate_scale(params:get("seq_root"), s.name, 4)
end

local function note_in_scale(deg)
  if #seq.scale_notes == 0 then return 60 end
  return seq.scale_notes[util.clamp(deg, 1, #seq.scale_notes)]
end

local function lfo_compute(shape, ph)
  local p = ph % 1
  if shape == 1 then return math.sin(p * 2 * math.pi)
  elseif shape == 2 then return p < 0.5 and (p * 4 - 1) or (3 - p * 4)
  elseif shape == 3 then return p < 0.5 and 1 or -1
  else return p * 2 - 1 end
end

local function mod_sum(dst)
  local t = 0
  for s = 1, 4 do
    local v = s <= 3 and lfo.val[s] or sh_val
    t = t + (matrix[s][dst] * v)
  end
  t = t + chaos:get_bipolar(math.min(dst, 4)) * 0.12
  return t
end

local function lerp(a, b, t) return a + (b - a) * t end

local function set_flash(text)
  flash_text = text
  flash_timer = 14
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
  engine.tape_level(lerp(1.0, 0.3, s))
  engine.moog_level(lerp(0.3, 1.0, s))
  engine.tape_voice_type(s * 2)
  engine.verb_mix(util.clamp(lerp(0.45, 0.15, s) + chaos:get_routed("verb_mix"), 0, 1))
end

local function apply_filter()
  local f = macro.filter
  local cutoff = 20 * math.pow(18000 / 20, f) + mod_sum(2) * 3000
  local res = lerp(0.1, 2.5, f * f) + mod_sum(3) * 0.8
  engine.moog_cutoff(util.clamp(cutoff, 20, 18000))
  engine.moog_res(util.clamp(res, 0, 3.5))
  engine.tape_tone(util.clamp(lerp(400, 10000, f), 100, 12000))
end

local function apply_chaos_macro()
  local c = macro.chaos
  local div_idx = math.floor(lerp(2, 6, c) + 0.5)
  if seq_sprocket then seq_sprocket:set_division(DIVISIONS[util.clamp(div_idx, 1, 6)]) end
  chaos:set_smooth(lerp(0.8, 0.05, c))
end

local function apply_all_macros()
  apply_spirit()
  apply_filter()
  apply_chaos_macro()
end

----------------------------------------------------------------
-- CHANGE APPLICATION (uniform pipeline)
----------------------------------------------------------------

local function apply_changes(changes)
  if not changes then return end
  for _, ch in ipairs(changes) do
    if ch.type == "delta" then
      if ch.param == "macro_spirit" then
        macro.spirit = util.clamp(macro.spirit + ch.delta, 0, 1); apply_spirit()
      elseif ch.param == "macro_filter" then
        macro.filter = util.clamp(macro.filter + ch.delta, 0.02, 0.98); apply_filter()
      elseif ch.param == "macro_chaos" then
        macro.chaos = util.clamp(macro.chaos + ch.delta, 0, 1); apply_chaos_macro()
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
        seq.data[s].degree = util.clamp(
          seq.data[s].degree + math.random(-(ch.range or 2), (ch.range or 2)),
          1, #seq.scale_notes)
      end
    elseif ch.type == "seq_direction" then
      seq.dir = math.random(1, 4)
      params:set("seq_direction", seq.dir)
    elseif ch.type == "seq_length" then
      params:set("seq_length", util.clamp(params:get("seq_length") + (ch.delta or 0), 4, SEQ_MAX))
    elseif ch.type == "seq_scale" then
      params:set("seq_scale", math.random(1, #musicutil.SCALES)); scale_generate()
    elseif ch.type == "seq_root" then
      params:set("seq_root", util.clamp(params:get("seq_root") + (ch.delta or 0), 24, 72))
      scale_generate()
    elseif ch.type == "matrix_set" then
      if ch.src and ch.dst then matrix[ch.src][ch.dst] = ch.val or 0 end
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
      local home = bandmate:get_home_state()
      local str = ch.strength or 0.05
      if home.spirit then macro.spirit = lerp(macro.spirit, home.spirit, str); apply_spirit() end
      if home.filter then macro.filter = lerp(macro.filter, home.filter, str); apply_filter() end
    end
  end
end

----------------------------------------------------------------
-- CONDUCTOR (robot mod engine)
-- runs every bar, rides params based on personality
-- aware of explorer phase + bandmate form
----------------------------------------------------------------

local function conductor_tick()
  if not robot.active then return end
  robot.conductor_beat = robot.conductor_beat + 1
  if robot.conductor_beat % 4 ~= 0 then return end -- run every bar (4 beats)

  local tame = robot_profile.TAME_STRENGTH[robot.personality] or 0.08
  local phase_name = Explorer.PHASE_NAMES[explorer.phase] or "SUMMON"
  local hints = robot_profile.phase_hints[phase_name] or {}

  -- iterate profile params, modulate by weight
  for pname, pdef in pairs(robot_profile.params) do
    if math.random() < pdef.weight * (0.5 + bandmate.energy * 0.5) then
      local sens = pdef.sensitivity
      local dir = pdef.direction

      -- phase-aware biasing
      local bias = 0
      if hints.prefer_high then
        for _, hp in ipairs(hints.prefer_high) do
          if hp == pname then bias = 0.3 * sens end
        end
      end
      if hints.prefer_low then
        for _, lp in ipairs(hints.prefer_low) do
          if lp == pname then bias = -0.3 * sens end
        end
      end
      local suppress = false
      if hints.suppress then
        for _, sp in ipairs(hints.suppress) do
          if sp == pname then suppress = true end
        end
      end

      if not suppress then
        local delta = (math.random() * 2 - 1) * sens * 0.1 + bias * 0.1
        if dir == "up" then delta = math.abs(delta)
        elseif dir == "down" then delta = -math.abs(delta) end

        -- personality scaling: chill = small moves, chaotic = big
        delta = delta * ({0.4, 1.0, 1.8})[robot.personality]

        -- apply via macro or param
        if pname == "macro_spirit" then
          macro.spirit = util.clamp(macro.spirit + delta, pdef.range_lo or 0, pdef.range_hi or 1)
          apply_spirit()
        elseif pname == "macro_filter" then
          macro.filter = util.clamp(macro.filter + delta, pdef.range_lo or 0, pdef.range_hi or 1)
          apply_filter()
        elseif pname == "macro_chaos" then
          macro.chaos = util.clamp(macro.chaos + delta, pdef.range_lo or 0, pdef.range_hi or 1)
          apply_chaos_macro()
        elseif pname == "seq_direction" then
          if math.random() < 0.15 then
            seq.dir = math.random(1, 4)
            params:set("seq_direction", seq.dir)
          end
        elseif pname == "seq_length" then
          local len = params:get("seq_length") + math.random(-1, 1)
          params:set("seq_length", util.clamp(len, pdef.range_lo or 4, pdef.range_hi or 16))
        else
          params:delta(pname, delta)
        end
      end
    end
  end

  -- taming: pull harsh values back (skip at chaotic personality)
  if robot.personality < 3 then
    -- cap resonance
    if params:get("moog_res") > 2.8 then
      params:set("moog_res", lerp(params:get("moog_res"), 2.0, tame))
    end
    -- cap chaos macro
    if macro.chaos > 0.85 then
      macro.chaos = lerp(macro.chaos, 0.6, tame)
      apply_chaos_macro()
    end
  end

  -- form awareness: silence phase = quiet everything
  if bandmate.form_phase == "silence" then
    macro.filter = lerp(macro.filter, 0.15, tame * 2)
    apply_filter()
  end
end

----------------------------------------------------------------
-- TAPE / MOOG / SEQUENCER
----------------------------------------------------------------

local function tape_note_on(note, vel)
  local id = tape_next_id
  tape_next_id = (tape_next_id % 10000) + 1
  tape_voices[note] = id
  engine.tape_on(id, musicutil.note_num_to_freq(note), vel)
end

local function tape_note_off(note)
  local id = tape_voices[note]
  if id then engine.tape_off(id); tape_voices[note] = nil end
end

local function moog_play(note, vel)
  engine.moog_hz(musicutil.note_num_to_freq(note))
  engine.moog_vel(vel)
  if not moog_note_on then engine.moog_gate(1); moog_note_on = true end
  seq.last_note = note
end

local function moog_stop()
  if moog_note_on then engine.moog_gate(0); moog_note_on = false end
end

local function seq_advance()
  local len = params:get("seq_length")
  local dir = seq.dir
  if macro.chaos > 0.7 and math.random() < (macro.chaos - 0.7) * 2 then dir = 4 end
  if dir == 1 then seq.pos = seq.pos % len + 1
  elseif dir == 2 then seq.pos = seq.pos - 1; if seq.pos < 1 then seq.pos = len end
  elseif dir == 3 then
    if seq.pend_fwd then seq.pos = seq.pos + 1; if seq.pos >= len then seq.pend_fwd = false end
    else seq.pos = seq.pos - 1; if seq.pos <= 1 then seq.pend_fwd = true end end
    seq.pos = util.clamp(seq.pos, 1, len)
  else seq.pos = math.random(1, len) end
end

local function seq_tick()
  if not seq.playing then return end
  if seq.last_note then
    moog_stop()
    if midi_out_device then midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch")) end
    seq.last_note = nil
  end
  seq_advance()
  local step = seq.data[seq.pos]
  if step and step.active then
    local xpose = math.floor(mod_sum(5) * 12 + 0.5)
    local note = note_in_scale(util.clamp(step.degree + xpose, 1, #seq.scale_notes))
    moog_play(note, step.vel)
    if midi_out_device then midi_out_device:note_on(note, step.vel, params:get("midi_out_ch")) end
    if seq.pos % 4 == 1 then sh_val = math.random() * 2 - 1 end
  end
  -- chaos step toggle
  if macro.chaos > 0.8 and math.random() < (macro.chaos - 0.8) * 2 then
    seq.data[math.random(1, params:get("seq_length"))].active = not seq.data[math.random(1, params:get("seq_length"))].active
  end
  -- explorer step mutations
  apply_changes(explorer:step(bandmate:get_weights()))
  chaos:step()
end

local function mod_tick()
  for i = 1, 3 do
    lfo.phase[i] = lfo.phase[i] + (lfo.rate[i] / 96)
    if lfo.phase[i] > 1000 then lfo.phase[i] = lfo.phase[i] - 1000 end
    lfo.val[i] = lfo_compute(lfo.shape[i], lfo.phase[i])
  end
  engine.tape_warble(util.clamp(params:get("tape_warble") + mod_sum(1) * 0.5, 0, 1))
  engine.moog_pw(util.clamp(params:get("moog_pw") + mod_sum(4) * 0.4, 0.05, 0.95))
  apply_filter()
end

local function beat_tick()
  explorer:beat(bandmate:get_pace())
  apply_changes(bandmate:beat())
  conductor_tick()
  if explorer.flash and explorer.flash[2] > 0 then
    set_flash(explorer.flash[1]); explorer.flash[2] = 0
  end
end

----------------------------------------------------------------
-- MIDI
----------------------------------------------------------------

local function on_midi_event(data)
  local msg = midi.to_msg(data)
  if msg.ch ~= params:get("midi_in_ch") then return end
  if msg.type == "note_on" and msg.vel > 0 then tape_note_on(msg.note, msg.vel)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then tape_note_off(msg.note) end
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
  params:set_action("moog_osc1", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)
  params:add_control("moog_osc2", "osc 2 (pulse)", controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("moog_osc2", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)
  params:add_control("moog_osc3", "osc 3 (sub)", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("moog_osc3", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)

  params:add_group("seq_grp", "SEQUENCER (1601)", 6)
  params:add_number("seq_length", "length", 1, SEQ_MAX, 16)
  params:add_option("seq_division", "division", DIV_NAMES, 5)
  params:set_action("seq_division", function(v) if seq_sprocket then seq_sprocket:set_division(DIVISIONS[v]) end end)
  params:add_option("seq_direction", "direction", DIR_NAMES, 1)
  params:set_action("seq_direction", function(v) seq.dir = v end)
  params:add_number("seq_root", "root note", 24, 72, 36)
  params:set_action("seq_root", function() scale_generate() end)
  params:add_option("seq_scale", "scale", (function() local n={}; for i,s in ipairs(musicutil.SCALES) do n[i]=s.name end; return n end)(), 1)
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

  params:add_group("lfo_grp", "LFO", 6)
  for i = 1, 3 do
    params:add_control("lfo_rate_"..i, "lfo "..i.." rate", controlspec.new(0.01, 20, 'exp', 0.01, lfo.rate[i], "hz"))
    params:set_action("lfo_rate_"..i, function(v) lfo.rate[i] = v end)
    params:add_option("lfo_shape_"..i, "lfo "..i.." shape", SHAPE_NAMES, lfo.shape[i])
    params:set_action("lfo_shape_"..i, function(v) lfo.shape[i] = v end)
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
  seq_regenerate()

  for s = 1, 4 do matrix[s] = {}; for d = 1, 5 do matrix[s][d] = 0 end end

  chaos:route("tape_warble", 1, 0.1, 0)
  chaos:route("moog_cutoff", 2, 0.15, 0)
  chaos:route("moog_pw", 3, 0.1, 0)
  chaos:route("verb_mix", 4, 0.05, 0)

  my_lattice = lattice_lib:new()
  seq_sprocket = my_lattice:new_sprocket{action=seq_tick, division=DIVISIONS[params:get("seq_division")], enabled=true}
  mod_sprocket = my_lattice:new_sprocket{action=mod_tick, division=1/96, enabled=true}
  beat_sprocket = my_lattice:new_sprocket{action=beat_tick, division=1/4, enabled=true}
  my_lattice:start()

  apply_all_macros()
  explorer:enter_phase(1)

  local scr = metro.init()
  scr.event = function()
    anim_frame = anim_frame + 1
    reel_angle = reel_angle + (seq.playing and 0.06 or 0.01)
    if flash_timer > 0 then flash_timer = flash_timer - 1 end
    redraw()
  end
  scr.time = 1 / 15
  scr:start()

  if g.device then g.key = grid_key; grid_redraw() end
end

----------------------------------------------------------------
-- INPUT
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #PAGES)
    return
  end

  if page == 1 then -- PLAY
    if shift then
      if n == 2 then macro.chaos = util.clamp(macro.chaos + d * 0.02, 0, 1); apply_chaos_macro()
      elseif n == 3 then params:delta("verb_room", d) end
    else
      if n == 2 then macro.filter = util.clamp(macro.filter + d * 0.015, 0, 1); apply_filter()
      elseif n == 3 then macro.spirit = util.clamp(macro.spirit + d * 0.02, 0, 1); apply_spirit() end
    end

  elseif page == 2 then -- SEQ
    if shift then
      if n == 2 then params:delta("seq_scale", d)
      elseif n == 3 then params:delta("seq_division", d) end
    else
      if n == 2 then
        local len = params:get("seq_length")
        local s = util.clamp(seq.pos == 0 and 1 or seq.pos, 1, len)
        seq.data[s].degree = util.clamp(seq.data[s].degree + d, 1, #seq.scale_notes)
      elseif n == 3 then params:delta("seq_length", d) end
    end

  elseif page == 3 then -- MATRIX
    if n == 2 then
      if shift then mat_cursor[1] = util.clamp(mat_cursor[1] + d, 1, 4)
      else mat_cursor[2] = util.clamp(mat_cursor[2] + d, 1, 5) end
    elseif n == 3 then
      if shift and mat_cursor[1] <= 3 then
        -- shift+E3 on LFO row: tweak that LFO's rate
        local which = mat_cursor[1]
        lfo.rate[which] = util.clamp(lfo.rate[which] + d * 0.1, 0.01, 20)
        params:set("lfo_rate_" .. which, lfo.rate[which])
      elseif shift and mat_cursor[1] == 4 then
        -- shift+E3 on S&H row: tweak chaos coefficient
        chaos:drift(d * 0.02)
      else
        -- normal: set routing amount
        matrix[mat_cursor[1]][mat_cursor[2]] = util.clamp(
          matrix[mat_cursor[1]][mat_cursor[2]] + d * 0.05, -1, 1)
      end
    end

  elseif page == 4 then -- ROBOT
    if n == 2 then
      local m = bandmate.mindset + d
      m = util.clamp(m, 1, #Bandmate.MINDSET_NAMES)
      bandmate:set_mindset(m)
      set_flash(Bandmate.MINDSET_NAMES[m])
    elseif n == 3 then
      robot.personality = util.clamp(robot.personality + d, 1, 3)
      set_flash(robot_profile.PERSONALITIES[robot.personality])
    end
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_held = true; k2_time = util.time()
      if k3_held then
        robot.active = not robot.active
        if robot.active then
          bandmate:start(); explorer.active = true
          explorer:enter_phase(1, bandmate:get_pace())
          bandmate:save_home({spirit = macro.spirit, filter = macro.filter})
          set_flash("ROBOT ON")
        else
          bandmate:stop(); explorer.active = false
          set_flash("MANUAL")
        end
      end
    else
      k2_held = false
      if not k3_held then
        if util.time() - k2_time > 0.5 then
          local m = bandmate.mindset % #Bandmate.MINDSET_NAMES + 1
          bandmate:set_mindset(m)
          set_flash(Bandmate.MINDSET_NAMES[m])
        else
          seq.playing = not seq.playing
          if not seq.playing then
            moog_stop()
            if seq.last_note and midi_out_device then
              midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
            end
            seq.last_note = nil; seq.pos = 0
          end
        end
      end
    end
  elseif n == 3 then
    if z == 1 then
      k3_held = true; shift = true
      if k2_held then
        robot.active = not robot.active
        if robot.active then
          bandmate:start(); explorer.active = true
          explorer:enter_phase(1, bandmate:get_pace())
          bandmate:save_home({spirit = macro.spirit, filter = macro.filter})
          set_flash("ROBOT ON")
        else
          bandmate:stop(); explorer.active = false
          set_flash("MANUAL")
        end
      end
    else
      k3_held = false; shift = false
      if not k2_held then
        if page == 3 and mat_cursor[1] <= 3 then
          -- MATRIX page + LFO row: cycle LFO shape
          local which = mat_cursor[1]
          lfo.shape[which] = (lfo.shape[which] % 4) + 1
          params:set("lfo_shape_" .. which, lfo.shape[which])
          set_flash("LFO" .. which .. " " .. SHAPE_NAMES[lfo.shape[which]])
        elseif page == 2 then
          -- SEQ page: cycle direction
          seq.dir = (seq.dir % 4) + 1
          params:set("seq_direction", seq.dir)
          set_flash("dir " .. DIR_NAMES[seq.dir])
        else
          seq_regenerate()
        end
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
    if y == 1 then seq.data[x].active = not seq.data[x].active
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
    if x == seq.pos and seq.playing then for y = 1, 8 do g:led(x, y, 2) end end
    if step.active then
      g:led(x, util.clamp(9 - math.ceil(step.degree / 2), 2, 8), x == seq.pos and 15 or 8)
    end
    g:led(x, 1, step.active and 6 or 1)
  end
  if robot.active then
    for y = 1, 8 do
      g:led(16, y, y <= math.floor(explorer.intensity * 8) and math.floor(explorer.intensity * 10) + 3 or 1)
      g:led(15, y, y <= math.floor(bandmate.energy * 8) and math.floor(bandmate.energy * 8) + 2 or 0)
    end
  end
  g:refresh()
end

----------------------------------------------------------------
-- SCREEN PAGES
----------------------------------------------------------------

local function draw_header()
  -- page dots
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.pixel(54 + (i - 1) * 5, 2)
    screen.fill()
  end
  -- page name
  screen.level(15)
  screen.move(2, 7)
  screen.text(PAGES[page])
  -- right side: phase or play state
  if robot.active then
    screen.level(10)
    local pn = Explorer.PHASE_NAMES[explorer.phase]
    screen.move(128 - screen.text_extents(pn), 7)
    screen.text(pn)
  else
    screen.level(3)
    screen.move(112, 7)
    screen.text(seq.playing and "PLAY" or "stop")
  end
  -- flash
  if flash_timer > 0 and flash_text then
    screen.level(15)
    screen.move(64 - screen.text_extents(flash_text) / 2, 7)
    screen.text(flash_text)
  end
  screen.level(1)
  screen.move(0, 9); screen.line(128, 9); screen.stroke()
end

-- PAGE 1: PLAY — macro bars + mini seq
local function draw_play()
  -- spirit bar
  local sp = macro.spirit
  screen.level(10); screen.move(2, 19); screen.text("SPIRIT")
  screen.level(2); screen.rect(36, 13, 62, 6); screen.fill()
  screen.level(sp < 0.35 and 12 or (sp > 0.65 and 6 or 9))
  screen.rect(36, 13, math.floor(sp * 62), 6); screen.fill()
  screen.level(5); screen.move(102, 19)
  screen.text(sp < 0.35 and "TAPE" or (sp > 0.65 and "MOOG" or "blend"))

  -- filter bar
  local fi = macro.filter
  screen.level(10); screen.move(2, 28); screen.text("FILTER")
  screen.level(2); screen.rect(36, 22, 62, 6); screen.fill()
  screen.level(10); screen.rect(36, 22, math.floor(fi * 62), 6); screen.fill()
  local cv = 20 * math.pow(18000 / 20, fi)
  screen.level(5); screen.move(102, 28)
  screen.text(cv >= 1000 and string.format("%.1fk", cv / 1000) or string.format("%d", math.floor(cv)))

  -- chaos bar
  local ch = macro.chaos
  screen.level(10); screen.move(2, 37); screen.text("CHAOS")
  screen.level(2); screen.rect(36, 31, 62, 6); screen.fill()
  screen.level(7); screen.rect(36, 31, math.floor(ch * 62), 6); screen.fill()
  screen.level(5); screen.move(102, 37)
  screen.text(string.format("%.0f%%", ch * 100))

  screen.level(1); screen.move(0, 40); screen.line(128, 40); screen.stroke()

  -- mini sequencer
  local len = params:get("seq_length")
  local sw = math.max(2, math.floor(124 / len))
  local md = math.max(#seq.scale_notes, 1)
  for i = 1, len do
    local x = 2 + (i - 1) * sw
    local step = seq.data[i]
    if step.active then
      local h = util.clamp(math.floor((step.degree / md) * 16), 1, 16)
      screen.level(i == seq.pos and 15 or 4)
      screen.rect(x, 57 - h, sw - 1, h); screen.fill()
    end
    if i == seq.pos and seq.playing then
      screen.level(15); screen.rect(x, 58, sw - 1, 1); screen.fill()
    end
  end

  -- bottom info
  screen.level(1); screen.move(0, 60); screen.line(128, 60); screen.stroke()
  if robot.active then
    screen.level(8); screen.move(2, 64); screen.text(Bandmate.MINDSET_NAMES[bandmate.mindset])
    local pulse = math.floor(math.abs(math.sin(anim_frame * 0.12)) * 6) + 4
    screen.level(pulse); screen.circle(64, 62, 2); screen.fill()
    screen.level(4); screen.move(70, 64); screen.text(bandmate.form_phase)
    screen.level(3)
    screen.move(128 - screen.text_extents(robot_profile.PERSONALITIES[robot.personality]), 64)
    screen.text(robot_profile.PERSONALITIES[robot.personality])
  else
    screen.level(3); screen.move(2, 64); screen.text("K2+K3 to summon robot")
  end
end

-- PAGE 2: SEQ — full sequencer view
local function draw_seq()
  screen.level(seq.playing and 12 or 4); screen.move(40, 7)
  screen.text(seq.playing and "PLAY" or "stop")

  local len = params:get("seq_length")
  local sw = math.max(3, math.floor(124 / len))
  local md = math.max(#seq.scale_notes, 1)

  for i = 1, len do
    local x = 2 + (i - 1) * sw
    local step = seq.data[i]
    if step.active then
      local h = util.clamp(math.floor((step.degree / md) * 32), 2, 32)
      screen.level(i == seq.pos and 15 or 6)
      screen.rect(x, 46 - h, sw - 1, h); screen.fill()
    else
      screen.level(1); screen.rect(x, 44, sw - 1, 2); screen.fill()
    end
    if i == seq.pos and seq.playing then
      screen.level(15); screen.rect(x, 48, sw - 1, 2); screen.fill()
    end
  end

  -- info line 1: direction, length, division
  screen.level(8); screen.move(2, 56); screen.text(DIR_NAMES[seq.dir])
  screen.level(6); screen.move(18, 56); screen.text("len " .. len)
  screen.move(48, 56); screen.text(DIV_NAMES[params:get("seq_division")])
  -- active step count
  local active_count = 0
  for i = 1, len do if seq.data[i].active then active_count = active_count + 1 end end
  screen.move(80, 56); screen.text(active_count .. "/" .. len .. " on")

  -- info line 2: root, scale
  screen.level(5); screen.move(2, 64)
  screen.text(musicutil.note_num_to_name(params:get("seq_root"), true))
  screen.move(22, 64)
  local sn = musicutil.SCALES[params:get("seq_scale")].name
  screen.text(#sn > 14 and string.sub(sn, 1, 13) .. "." or sn)
  -- hint
  screen.level(3); screen.move(88, 64); screen.text("K3=dir")
end

-- PAGE 3: MATRIX — modulation routing
local function draw_matrix()
  local col_start = 28
  local col_w = 19
  for d = 1, 5 do
    screen.level(d == mat_cursor[2] and 12 or 4)
    screen.move(col_start + (d - 1) * col_w, 18)
    screen.text(MOD_DST[d])
  end
  for s = 1, 4 do
    local y = 27 + (s - 1) * 10
    screen.level(s == mat_cursor[1] and 10 or 3)
    screen.move(2, y); screen.text(MOD_SRC[s])
    -- activity dot
    local act = s <= 3 and math.abs(lfo.val[s]) or math.abs(sh_val)
    screen.level(math.floor(act * 6) + 1); screen.pixel(24, y - 3); screen.fill()
    for d = 1, 5 do
      local v = matrix[s][d]
      local x = col_start + (d - 1) * col_w + 4
      local cur = s == mat_cursor[1] and d == mat_cursor[2]
      screen.level(cur and 15 or (v ~= 0 and math.floor(math.abs(v) * 8) + 3 or 1))
      if v > 0.01 then screen.rect(x, y - 5, 6, 6); screen.fill()
      elseif v < -0.01 then screen.rect(x, y - 5, 6, 6); screen.stroke()
      else screen.pixel(x + 2, y - 2); screen.fill() end
    end
  end
  -- bottom info: routing value + LFO details
  screen.level(7); screen.move(2, 58)
  screen.text(MOD_SRC[mat_cursor[1]] .. ">" .. MOD_DST_FULL[mat_cursor[2]])
  screen.level(12); screen.move(86, 58)
  screen.text(string.format("%+.2f", matrix[mat_cursor[1]][mat_cursor[2]]))

  -- show LFO rate/shape for selected source (or chaos coeff for S&H)
  screen.level(5); screen.move(2, 64)
  if mat_cursor[1] <= 3 then
    local i = mat_cursor[1]
    screen.text(string.format("%s %.2fhz  K3=shape  shf+E3=rate",
      SHAPE_NAMES[lfo.shape[i]], lfo.rate[i]))
  else
    screen.text(string.format("chaos x=%.2f  shf+E3=drift", chaos.coeff_x))
  end
end

-- PAGE 4: ROBOT — full autonomous status
local function draw_robot()
  if not robot.active then
    screen.level(6); screen.move(20, 30); screen.text("robot is sleeping")
    screen.level(3); screen.move(16, 42); screen.text("K2+K3 to summon")
    return
  end

  -- mindset
  screen.level(12); screen.move(2, 18)
  screen.text("mindset: " .. Bandmate.MINDSET_NAMES[bandmate.mindset])

  -- personality
  screen.level(8); screen.move(2, 27)
  screen.text("personality: " .. robot_profile.PERSONALITIES[robot.personality])

  -- explorer phase + intensity bar
  screen.level(10); screen.move(2, 36)
  screen.text("phase: " .. Explorer.PHASE_NAMES[explorer.phase])
  screen.level(2); screen.rect(70, 30, 56, 5); screen.fill()
  screen.level(12); screen.rect(70, 30, math.floor(explorer.intensity * 56), 5); screen.fill()

  -- breathing
  screen.level(8); screen.move(2, 45)
  screen.text("breath: " .. bandmate.breath_phase)
  screen.level(2); screen.rect(70, 39, 56, 5); screen.fill()
  local br_col = bandmate.breath_phase == "silence" and 2 or (bandmate.breath_phase == "build" and 10 or 7)
  screen.level(br_col); screen.rect(70, 39, math.floor(bandmate.energy * 56), 5); screen.fill()

  -- form
  screen.level(6); screen.move(2, 54)
  screen.text("form: " .. bandmate.form_phase)

  -- chaos coefficients
  screen.level(4); screen.move(70, 54)
  screen.text(string.format("chaos %.2f", chaos.coeff_x))

  -- last mutation
  screen.level(3); screen.move(2, 64)
  screen.text(explorer.last_mutation ~= "" and ("last: " .. explorer.last_mutation) or "")

  -- conductor beat counter
  screen.level(3); screen.move(90, 64)
  screen.text("bar " .. math.floor(robot.conductor_beat / 4))
end

function redraw()
  screen.clear()
  draw_header()
  if page == 1 then draw_play()
  elseif page == 2 then draw_seq()
  elseif page == 3 then draw_matrix()
  elseif page == 4 then draw_robot()
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
