-- seance
-- summoning analog ghosts
--
-- E1: page  E2: scroll  E3: adjust
-- K2: play/stop  K2 long: cycle mindset
-- K3 tap: regen  K3 hold: freeze robot
-- K2+K3: toggle robot
--
-- PAGES: PLAY / SEQ / MATRIX / ROBOT
-- MIDI in: mellotron | MIDI out: seq + CC

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

local PLAY_PARAMS = {"SPIRIT", "FILTER", "CHAOS", "VERB", "PORTA", "FILT ENV", "GATE"}
local SEQ_PARAMS = {"step", "pitch", "velocity", "gate", "length", "direction", "division", "root", "scale"}
local ROBOT_PARAMS = {"mindset", "personality"}
local MAT_ITEM_COUNT = 7 + 4 * 5

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local explorer = Explorer.new()
local bandmate = Bandmate.new()
local chaos = Chaos.new()

local robot = {active = false, personality = 1, conductor_beat = 0}
local frozen = false  -- K3 hold freezes robot

-- ui
local page = 1
local shift = false
local k2_held = false
local k3_held = false
local k2_time = 0
local k3_time = 0
local flash_text = nil
local flash_timer = 0
local anim_frame = 0

-- per-page selection
local sel = {1, 1, 1, 1}

-- macros (0-1)
local macro = {spirit = 0.4, filter = 0.3, chaos = 0.2}

-- snapshot
local snapshot = nil  -- saved state table

-- tape
local tape_voices = {}
local tape_next_id = 1

-- moog
local moog_note_on = false
local gate_clock_id = nil  -- for gate length timing

-- sequencer
local seq = {
  data = {},
  pos = 0,
  playing = false,
  dir = 1,
  pend_fwd = true,
  last_note = nil,
  scale_notes = {},
  edit_step = 1,  -- which step the encoder edits
  gate_length = 0.5,  -- global gate 0-1 (fraction of step)
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
    t = t + (matrix[s][dst] * (s <= 3 and lfo.val[s] or sh_val))
  end
  return t + chaos:get_bipolar(math.min(dst, 4)) * 0.12
end

local function lerp(a, b, t) return a + (b - a) * t end
local function set_flash(text) flash_text = text; flash_timer = 14 end

local function seq_regenerate()
  scale_generate()
  for i = 1, SEQ_MAX do
    seq.data[i] = {
      degree = math.random(1, math.min(#seq.scale_notes, 14)),
      vel = math.random(70, 127),
      gate = 0.4 + math.random() * 0.4, -- 0.4-0.8
      active = math.random() > 0.25,
    }
  end
  set_flash("REGEN")
end

local function mat_item_info(idx)
  if idx <= 6 then
    local i = math.ceil(idx / 2)
    if idx % 2 == 1 then return "lfo_rate", "LFO"..i.." rate", string.format("%.2f hz", lfo.rate[i])
    else return "lfo_shape", "LFO"..i.." shape", SHAPE_NAMES[lfo.shape[i]] end
  elseif idx == 7 then return "chaos", "S&H chaos", string.format("x=%.2f", chaos.coeff_x)
  else
    local cell = idx - 7
    local src = math.ceil(cell / 5)
    local dst = ((cell - 1) % 5) + 1
    return "route", MOD_SRC[src]..">"..MOD_DST[dst], string.format("%+.2f", matrix[src][dst])
  end
end

----------------------------------------------------------------
-- SNAPSHOT
----------------------------------------------------------------

local function snapshot_save()
  snapshot = {
    spirit = macro.spirit, filter = macro.filter, chaos = macro.chaos,
    warble = params:get("tape_warble"), tone = params:get("tape_tone"),
    cutoff = params:get("moog_cutoff"), res = params:get("moog_res"),
    pw = params:get("moog_pw"), porta = params:get("moog_porta"),
    verb_room = params:get("verb_room"), verb_damp = params:get("verb_damp"),
  }
  set_flash("SAVED")
end

local function snapshot_recall()
  if not snapshot then set_flash("no snap"); return end
  macro.spirit = snapshot.spirit; macro.filter = snapshot.filter; macro.chaos = snapshot.chaos
  params:set("tape_warble", snapshot.warble)
  params:set("tape_tone", snapshot.tone)
  params:set("moog_cutoff", snapshot.cutoff)
  params:set("moog_res", snapshot.res)
  params:set("moog_pw", snapshot.pw)
  params:set("moog_porta", snapshot.porta)
  params:set("verb_room", snapshot.verb_room)
  params:set("verb_damp", snapshot.verb_damp)
  apply_all_macros()
  set_flash("RECALL")
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

local function apply_all_macros() apply_spirit(); apply_filter(); apply_chaos_macro() end

----------------------------------------------------------------
-- CHANGE APPLICATION
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
      else params:delta(ch.param, ch.delta) end
    elseif ch.type == "seq_toggle" then
      local len = params:get("seq_length")
      for _ = 1, (ch.count or 1) do
        local s = math.random(1, len); seq.data[s].active = not seq.data[s].active
      end
    elseif ch.type == "seq_pitch" then
      local len = params:get("seq_length")
      for _ = 1, (ch.count or 1) do
        local s = math.random(1, len)
        seq.data[s].degree = util.clamp(seq.data[s].degree + math.random(-(ch.range or 2), (ch.range or 2)), 1, #seq.scale_notes)
      end
    elseif ch.type == "seq_direction" then seq.dir = math.random(1, 4); params:set("seq_direction", seq.dir)
    elseif ch.type == "seq_length" then params:set("seq_length", util.clamp(params:get("seq_length") + (ch.delta or 0), 4, SEQ_MAX))
    elseif ch.type == "seq_scale" then params:set("seq_scale", math.random(1, #musicutil.SCALES)); scale_generate()
    elseif ch.type == "seq_root" then params:set("seq_root", util.clamp(params:get("seq_root") + (ch.delta or 0), 24, 72)); scale_generate()
    elseif ch.type == "matrix_set" then if ch.src and ch.dst then matrix[ch.src][ch.dst] = ch.val or 0 end
    elseif ch.type == "lfo_rate" then
      if ch.which then lfo.rate[ch.which] = util.clamp(lfo.rate[ch.which] + (ch.delta or 0), 0.01, 15); params:set("lfo_rate_"..ch.which, lfo.rate[ch.which]) end
    elseif ch.type == "lfo_shape" then if ch.which then lfo.shape[ch.which] = ch.val or 1; params:set("lfo_shape_"..ch.which, lfo.shape[ch.which]) end
    elseif ch.type == "chaos_drift" then chaos:drift(ch.amount or 0.1)
    elseif ch.type == "home_pull" and bandmate:get_home_state() then
      local home = bandmate:get_home_state(); local str = ch.strength or 0.05
      if home.spirit then macro.spirit = lerp(macro.spirit, home.spirit, str); apply_spirit() end
      if home.filter then macro.filter = lerp(macro.filter, home.filter, str); apply_filter() end
    end
  end
end

----------------------------------------------------------------
-- CONDUCTOR
----------------------------------------------------------------

local function conductor_tick()
  if not robot.active or frozen then return end
  robot.conductor_beat = robot.conductor_beat + 1
  if robot.conductor_beat % 4 ~= 0 then return end

  local tame = robot_profile.TAME_STRENGTH[robot.personality] or 0.08
  local phase_name = Explorer.PHASE_NAMES[explorer.phase] or "SUMMON"
  local hints = robot_profile.phase_hints[phase_name] or {}

  for pname, pdef in pairs(robot_profile.params) do
    if math.random() < pdef.weight * (0.5 + bandmate.energy * 0.5) then
      local bias = 0
      if hints.prefer_high then for _, hp in ipairs(hints.prefer_high) do if hp == pname then bias = 0.3 * pdef.sensitivity end end end
      if hints.prefer_low then for _, lp in ipairs(hints.prefer_low) do if lp == pname then bias = -0.3 * pdef.sensitivity end end end
      local suppress = false
      if hints.suppress then for _, sp in ipairs(hints.suppress) do if sp == pname then suppress = true end end end

      if not suppress then
        local delta = (math.random() * 2 - 1) * pdef.sensitivity * 0.1 + bias * 0.1
        if pdef.direction == "up" then delta = math.abs(delta)
        elseif pdef.direction == "down" then delta = -math.abs(delta) end
        delta = delta * ({0.4, 1.0, 1.8})[robot.personality]

        if pname == "macro_spirit" then macro.spirit = util.clamp(macro.spirit + delta, pdef.range_lo or 0, pdef.range_hi or 1); apply_spirit()
        elseif pname == "macro_filter" then macro.filter = util.clamp(macro.filter + delta, pdef.range_lo or 0, pdef.range_hi or 1); apply_filter()
        elseif pname == "macro_chaos" then macro.chaos = util.clamp(macro.chaos + delta, pdef.range_lo or 0, pdef.range_hi or 1); apply_chaos_macro()
        elseif pname == "seq_direction" then if math.random() < 0.15 then seq.dir = math.random(1, 4); params:set("seq_direction", seq.dir) end
        elseif pname == "seq_length" then params:set("seq_length", util.clamp(params:get("seq_length") + math.random(-1, 1), pdef.range_lo or 4, pdef.range_hi or 16))
        else params:delta(pname, delta) end
      end
    end
  end

  if robot.personality < 3 then
    if params:get("moog_res") > 2.8 then params:set("moog_res", lerp(params:get("moog_res"), 2.0, tame)) end
    if macro.chaos > 0.85 then macro.chaos = lerp(macro.chaos, 0.6, tame); apply_chaos_macro() end
  end
  if bandmate.form_phase == "silence" then macro.filter = lerp(macro.filter, 0.15, tame * 2); apply_filter() end
end

----------------------------------------------------------------
-- TAPE / MOOG
----------------------------------------------------------------

local function tape_note_on(note, vel)
  local id = tape_next_id; tape_next_id = (tape_next_id % 10000) + 1
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

----------------------------------------------------------------
-- SEQUENCER
----------------------------------------------------------------

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

  -- note off from previous step
  if seq.last_note then
    moog_stop()
    if midi_out_device then midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch")) end
    seq.last_note = nil
  end
  -- cancel pending gate-off
  if gate_clock_id then clock.cancel(gate_clock_id); gate_clock_id = nil end

  -- swing: even steps delayed
  local swing_amt = params:get("seq_swing")
  if swing_amt > 50 and seq.pos % 2 == 0 then
    local delay = (swing_amt - 50) / 100 * 0.5  -- 0 to 0.25 beats
    clock.run(function() clock.sleep(delay * clock.get_beat_sec()) end)
  end

  seq_advance()

  local step = seq.data[seq.pos]
  if step and step.active then
    local xpose = math.floor(mod_sum(5) * 12 + 0.5)
    local note = note_in_scale(util.clamp(step.degree + xpose, 1, #seq.scale_notes))

    moog_play(note, step.vel)

    -- MIDI out: note + CCs
    if midi_out_device then
      local ch = params:get("midi_out_ch")
      midi_out_device:note_on(note, step.vel, ch)
      -- CC74 = filter cutoff (normalized)
      midi_out_device:cc(74, math.floor(macro.filter * 127), ch)
      -- CC71 = resonance
      midi_out_device:cc(71, math.floor(params:get("moog_res") / 3.5 * 127), ch)
      -- CC1 = mod wheel (spirit blend)
      midi_out_device:cc(1, math.floor(macro.spirit * 127), ch)
    end

    -- gate length: schedule note-off
    local gate = step.gate * seq.gate_length
    gate_clock_id = clock.run(function()
      local div = DIVISIONS[params:get("seq_division")] or 1/16
      clock.sleep(gate * div * 4 * clock.get_beat_sec())
      moog_stop()
      if midi_out_device and seq.last_note then
        midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
      end
    end)

    if seq.pos % 4 == 1 then sh_val = math.random() * 2 - 1 end
  end

  -- chaos step toggle
  if macro.chaos > 0.8 and math.random() < (macro.chaos - 0.8) * 2 then
    seq.data[math.random(1, params:get("seq_length"))].active = not seq.data[math.random(1, params:get("seq_length"))].active
  end

  -- explorer mutations (skip if frozen)
  if not frozen then
    apply_changes(explorer:step(bandmate:get_weights()))
  end
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
  if not frozen then
    explorer:beat(bandmate:get_pace())
    apply_changes(bandmate:beat())
    conductor_tick()
  end
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

  params:add_group("macro_grp", "MACROS", 3)
  params:add_control("macro_spirit", "spirit (tape/moog)", controlspec.new(0, 1, 'lin', 0.01, 0.4))
  params:set_action("macro_spirit", function(v) macro.spirit = v; apply_spirit() end)
  params:add_control("macro_filter", "filter sweep", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("macro_filter", function(v) macro.filter = v; apply_filter() end)
  params:add_control("macro_chaos", "chaos", controlspec.new(0, 1, 'lin', 0.01, 0.2))
  params:set_action("macro_chaos", function(v) macro.chaos = v; apply_chaos_macro() end)

  params:add_group("tape_grp", "TAPE (Mellotron)", 6)
  params:add_option("tape_voice", "voice", {"strings", "flutes", "choir"}, 1)
  params:set_action("tape_voice", function(v) engine.tape_voice_type(v - 1) end)
  params:add_control("tape_warble", "warble", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("tape_warble", function(v) engine.tape_warble(v) end)
  params:add_control("tape_tone", "tone", controlspec.new(100, 12000, 'exp', 1, 2000, "hz"))
  params:set_action("tape_tone", function(v) engine.tape_tone(v) end)
  params:add_control("tape_attack", "attack", controlspec.new(0.005, 2, 'exp', 0, 0.08, "s"))
  params:set_action("tape_attack", function(v) engine.tape_attack(v) end)
  params:add_control("tape_release", "release", controlspec.new(0.05, 8, 'exp', 0, 1.2, "s"))
  params:set_action("tape_release", function(v) engine.tape_release(v) end)
  params:add_control("tape_level", "level", controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("tape_level", function(v) engine.tape_level(v) end)

  params:add_group("moog_grp", "MOOG (MiniMoog)", 9)
  params:add_control("moog_cutoff", "cutoff", controlspec.new(20, 18000, 'exp', 1, 1200, "hz"))
  params:set_action("moog_cutoff", function(v) engine.moog_cutoff(v) end)
  params:add_control("moog_res", "resonance", controlspec.new(0, 3.5, 'lin', 0.01, 0.3))
  params:set_action("moog_res", function(v) engine.moog_res(v) end)
  params:add_control("moog_porta", "portamento", controlspec.new(0, 2, 'lin', 0.001, 0.05, "s"))
  params:set_action("moog_porta", function(v) engine.moog_porta(v) end)
  params:add_control("moog_pw", "pulse width", controlspec.new(0.05, 0.95, 'lin', 0.01, 0.5))
  params:set_action("moog_pw", function(v) engine.moog_pw(v) end)
  params:add_control("moog_f_env", "filter env amt", controlspec.new(0, 8000, 'lin', 1, 2000, "hz"))
  params:set_action("moog_f_env", function(v) engine.moog_f_env(v) end)
  params:add_control("moog_osc1", "osc 1 (saw)", controlspec.new(0, 1, 'lin', 0.01, 1.0))
  params:set_action("moog_osc1", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)
  params:add_control("moog_osc2", "osc 2 (pulse)", controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("moog_osc2", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)
  params:add_control("moog_osc3", "osc 3 (sub)", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("moog_osc3", function() engine.moog_osc_mix(params:get("moog_osc1"), params:get("moog_osc2"), params:get("moog_osc3")) end)
  params:add_control("moog_level", "level", controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("moog_level", function(v) engine.moog_level(v) end)

  params:add_group("seq_grp", "SEQUENCER", 8)
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
  params:add_control("seq_gate", "gate length", controlspec.new(0.1, 1.0, 'lin', 0.01, 0.5))
  params:set_action("seq_gate", function(v) seq.gate_length = v end)
  params:add_number("seq_midi_cc", "send MIDI CC", 0, 1, 1)

  params:add_group("fx_grp", "REVERB", 3)
  params:add_control("verb_mix", "mix", controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("verb_mix", function(v) engine.verb_mix(v) end)
  params:add_control("verb_room", "room", controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("verb_room", function(v) engine.verb_room(v) end)
  params:add_control("verb_damp", "damp", controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("verb_damp", function(v) engine.verb_damp(v) end)

  params:add_group("lfo_grp", "LFO", 6)
  for i = 1, 3 do
    params:add_control("lfo_rate_"..i, "lfo "..i.." rate", controlspec.new(0.01, 20, 'exp', 0.01, lfo.rate[i], "hz"))
    params:set_action("lfo_rate_"..i, function(v) lfo.rate[i] = v end)
    params:add_option("lfo_shape_"..i, "lfo "..i.." shape", SHAPE_NAMES, lfo.shape[i])
    params:set_action("lfo_shape_"..i, function(v) lfo.shape[i] = v end)
  end

  params:add_group("robot_grp", "ROBOT", 3)
  params:add_option("robot_active", "robot", {"off", "on"}, 2)
  params:set_action("robot_active", function(v)
    if v == 2 then
      robot.active = true; bandmate:start(); explorer.active = true
      explorer:enter_phase(1, bandmate:get_pace())
      bandmate:save_home({spirit = macro.spirit, filter = macro.filter})
    else robot.active = false; bandmate:stop(); explorer.active = false end
  end)
  params:add_option("robot_mindset", "mindset", Bandmate.MINDSET_NAMES, 5)
  params:set_action("robot_mindset", function(v) bandmate:set_mindset(v) end)
  params:add_option("robot_personality", "personality", robot_profile.PERSONALITIES, 1)
  params:set_action("robot_personality", function(v) robot.personality = v end)

  params:add_group("midi_grp", "MIDI", 2)
  params:add_number("midi_out_ch", "midi out ch", 1, 16, 1)
  params:add_number("midi_in_ch", "midi in ch", 1, 16, 1)
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
  robot.active = true; bandmate:start(); explorer.active = true
  explorer:enter_phase(1, bandmate:get_pace())
  bandmate:save_home({spirit = macro.spirit, filter = macro.filter})

  local scr = metro.init()
  scr.event = function()
    anim_frame = anim_frame + 1
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
  if n == 1 then page = util.clamp(page + d, 1, #PAGES); return end

  if page == 1 then -- PLAY
    if n == 2 then sel[1] = util.clamp(sel[1] + d, 1, #PLAY_PARAMS)
    elseif n == 3 then
      local s = sel[1]
      if s == 1 then macro.spirit = util.clamp(macro.spirit + d * 0.02, 0, 1); apply_spirit()
      elseif s == 2 then macro.filter = util.clamp(macro.filter + d * 0.015, 0, 1); apply_filter()
      elseif s == 3 then macro.chaos = util.clamp(macro.chaos + d * 0.02, 0, 1); apply_chaos_macro()
      elseif s == 4 then params:delta("verb_room", d)
      elseif s == 5 then params:delta("moog_porta", d)
      elseif s == 6 then params:delta("moog_f_env", d * 50)
      elseif s == 7 then params:delta("seq_gate", d) end
    end

  elseif page == 2 then -- SEQ
    if n == 2 then sel[2] = util.clamp(sel[2] + d, 1, #SEQ_PARAMS)
    elseif n == 3 then
      local s = sel[2]
      local len = params:get("seq_length")
      local es = util.clamp(seq.edit_step, 1, len)
      if s == 1 then seq.edit_step = util.clamp(seq.edit_step + d, 1, len)
      elseif s == 2 then seq.data[es].degree = util.clamp(seq.data[es].degree + d, 1, #seq.scale_notes)
      elseif s == 3 then seq.data[es].vel = util.clamp(seq.data[es].vel + d * 4, 1, 127)
      elseif s == 4 then seq.data[es].gate = util.clamp(seq.data[es].gate + d * 0.05, 0.1, 1.0)
      elseif s == 5 then params:delta("seq_length", d)
      elseif s == 6 then seq.dir = util.clamp(seq.dir + d, 1, 4); params:set("seq_direction", seq.dir)
      elseif s == 7 then params:delta("seq_division", d)
      elseif s == 8 then params:delta("seq_root", d)
      elseif s == 9 then params:delta("seq_scale", d) end
    end

  elseif page == 3 then -- MATRIX
    if n == 2 then sel[3] = util.clamp(sel[3] + d, 1, MAT_ITEM_COUNT)
    elseif n == 3 then
      local idx = sel[3]
      if idx <= 6 then
        local i = math.ceil(idx / 2)
        if idx % 2 == 1 then lfo.rate[i] = util.clamp(lfo.rate[i] + d * 0.1, 0.01, 20); params:set("lfo_rate_"..i, lfo.rate[i])
        else lfo.shape[i] = util.clamp(lfo.shape[i] + d, 1, 4); params:set("lfo_shape_"..i, lfo.shape[i]) end
      elseif idx == 7 then chaos:drift(d * 0.02)
      else
        local cell = idx - 7; local src = math.ceil(cell / 5); local dst = ((cell - 1) % 5) + 1
        matrix[src][dst] = util.clamp(matrix[src][dst] + d * 0.05, -1, 1)
      end
    end

  elseif page == 4 then -- ROBOT
    if n == 2 then sel[4] = util.clamp(sel[4] + d, 1, #ROBOT_PARAMS)
    elseif n == 3 then
      if sel[4] == 1 then
        local m = util.clamp(bandmate.mindset + d, 1, #Bandmate.MINDSET_NAMES)
        bandmate:set_mindset(m); set_flash(Bandmate.MINDSET_NAMES[m])
      elseif sel[4] == 2 then
        robot.personality = util.clamp(robot.personality + d, 1, 3)
        set_flash(robot_profile.PERSONALITIES[robot.personality])
      end
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
          bandmate:start(); explorer.active = true; explorer:enter_phase(1, bandmate:get_pace())
          bandmate:save_home({spirit = macro.spirit, filter = macro.filter}); set_flash("ROBOT ON")
        else bandmate:stop(); explorer.active = false; set_flash("MANUAL") end
      end
    else
      k2_held = false
      if not k3_held then
        if util.time() - k2_time > 0.6 then
          -- long press: cycle mindset
          local m = bandmate.mindset % #Bandmate.MINDSET_NAMES + 1
          bandmate:set_mindset(m); set_flash(Bandmate.MINDSET_NAMES[m])
        else
          seq.playing = not seq.playing
          if not seq.playing then
            moog_stop()
            if seq.last_note and midi_out_device then midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch")) end
            seq.last_note = nil; seq.pos = 0
          end
        end
      end
    end
  elseif n == 3 then
    if z == 1 then
      k3_held = true; k3_time = util.time()
      if k2_held then
        robot.active = not robot.active
        if robot.active then
          bandmate:start(); explorer.active = true; explorer:enter_phase(1, bandmate:get_pace())
          bandmate:save_home({spirit = macro.spirit, filter = macro.filter}); set_flash("ROBOT ON")
        else bandmate:stop(); explorer.active = false; set_flash("MANUAL") end
      else
        -- hold K3 = freeze robot
        frozen = true; set_flash("FROZEN")
      end
    else
      k3_held = false
      local held = util.time() - k3_time
      if not k2_held then
        if held < 0.3 then
          -- short tap
          if page == 4 then
            -- on ROBOT page: save/recall snapshot
            if sel[4] == 1 then snapshot_save() else snapshot_recall() end
          else
            seq_regenerate()
          end
        end
      end
      -- unfreeze
      if frozen then frozen = false; set_flash("THAWED") end
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
    seq.edit_step = x  -- grid selects edit step too
  end
  grid_redraw()
end

function grid_redraw()
  if not g.device then return end
  g:all(0)
  local len = params:get("seq_length")
  for x = 1, math.min(16, len) do
    local step = seq.data[x]
    -- playhead column glow
    if x == seq.pos and seq.playing then for y = 1, 8 do g:led(x, y, 2) end end
    -- pitch dot
    if step.active then
      local row = util.clamp(9 - math.ceil(step.degree / 2), 2, 8)
      g:led(x, row, x == seq.pos and 15 or (x == seq.edit_step and 10 or 7))
    end
    -- top row: active + edit indicator
    local top_bright = step.active and 5 or 1
    if x == seq.edit_step then top_bright = 12 end
    g:led(x, 1, top_bright)
  end
  -- right columns: autonomous layer meters
  if robot.active then
    local int = explorer.intensity
    local eng = bandmate.energy
    for y = 1, 8 do
      g:led(16, 9 - y, y <= math.floor(int * 8) and math.floor(int * 10) + 3 or 1)
      g:led(15, 9 - y, y <= math.floor(eng * 8) and math.floor(eng * 8) + 2 or 0)
    end
    -- phase indicator on col 14
    local phase_bright = ({4, 8, 15, 6})[explorer.phase] or 4
    g:led(14, 1, phase_bright)
    if frozen then g:led(14, 8, 15) end  -- frozen indicator
  end
  g:refresh()
end

----------------------------------------------------------------
-- SCREEN
----------------------------------------------------------------

local function draw_header()
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.rect(52 + (i - 1) * 6, 1, 4, 3)
    screen.fill()
  end
  screen.level(15); screen.move(2, 7); screen.text(PAGES[page])
  if robot.active then
    local pn = Explorer.PHASE_NAMES[explorer.phase]
    if frozen then pn = "FROZEN" end
    screen.level(frozen and 15 or 8)
    screen.move(128 - screen.text_extents(pn), 7); screen.text(pn)
  else
    screen.level(4); screen.move(110, 7); screen.text(seq.playing and "PLAY" or "stop")
  end
  if flash_timer > 0 and flash_text then
    screen.level(15); screen.move(64 - screen.text_extents(flash_text) / 2, 7); screen.text(flash_text)
  end
  screen.level(1); screen.move(0, 9); screen.line(128, 9); screen.stroke()
end

local function draw_play()
  local s = sel[1]
  local vals = {
    macro.spirit, macro.filter, macro.chaos,
    params:get("verb_room"), params:get("moog_porta"),
    params:get("moog_f_env") / 8000, seq.gate_length,
  }
  local labels = {"SPIRIT", "FILTER", "CHAOS", "VERB", "PORTA", "FLT.ENV", "GATE"}
  local rights = {
    macro.spirit < 0.35 and "TAPE" or (macro.spirit > 0.65 and "MOOG" or "blend"),
    (function() local c=20*math.pow(900,macro.filter); return c>=1000 and string.format("%.1fk",c/1000) or string.format("%d",math.floor(c)) end)(),
    string.format("%.0f%%", macro.chaos * 100),
    string.format("%.2f", params:get("verb_room")),
    string.format("%.3f", params:get("moog_porta")),
    string.format("%d", math.floor(params:get("moog_f_env"))),
    string.format("%.0f%%", seq.gate_length * 100),
  }

  for i = 1, #PLAY_PARAMS do
    local y = 10 + (i - 1) * 7
    local is = i == s
    if is then screen.level(15); screen.move(1, y + 5); screen.text(">") end
    screen.level(is and 15 or 5); screen.move(8, y + 5); screen.text(labels[i])
    -- bar
    screen.level(2); screen.rect(44, y + 1, 50, 4); screen.fill()
    screen.level(is and 12 or 5); screen.rect(44, y + 1, math.floor((vals[i] or 0) * 50), 4); screen.fill()
    screen.level(is and 10 or 3); screen.move(98, y + 5); screen.text(rights[i] or "")
  end

  -- bottom: status
  screen.level(1); screen.move(0, 61); screen.line(128, 61); screen.stroke()
  if robot.active then
    screen.level(7); screen.move(2, 64); screen.text(Bandmate.MINDSET_NAMES[bandmate.mindset])
    local pulse = math.floor(math.abs(math.sin(anim_frame * 0.1)) * 5) + 4
    screen.level(frozen and 15 or pulse); screen.circle(62, 62, 2); screen.fill()
    screen.level(4); screen.move(68, 64); screen.text(frozen and "frozen" or bandmate.form_phase)
    screen.level(3); local pname = robot_profile.PERSONALITIES[robot.personality]
    screen.move(128 - screen.text_extents(pname), 64); screen.text(pname)
  else
    screen.level(4); screen.move(2, 64); screen.text(seq.playing and ("step "..seq.pos) or "stopped")
    screen.level(2); screen.move(50, 64); screen.text("K2+K3 robot")
  end
end

local function draw_seq()
  local len = params:get("seq_length")
  local sw = math.max(3, math.floor(120 / len))
  local md = math.max(#seq.scale_notes, 1)
  local es = seq.edit_step

  -- step bars
  for i = 1, len do
    local x = 2 + (i - 1) * sw
    local step = seq.data[i]
    local is_edit = i == es
    local is_play = i == seq.pos and seq.playing

    if step.active then
      local h = util.clamp(math.floor((step.degree / md) * 28), 2, 28)
      -- velocity as brightness
      local bright = math.floor(step.vel / 127 * 8) + 3
      if is_play then bright = 15
      elseif is_edit then bright = 11 end
      screen.level(bright)
      screen.rect(x, 40 - h, sw - 1, h); screen.fill()
      -- gate length indicator (bottom tick)
      local gate_w = math.max(1, math.floor((sw - 1) * step.gate))
      screen.level(is_edit and 12 or 4)
      screen.rect(x, 42, gate_w, 1); screen.fill()
    else
      screen.level(1); screen.pixel(x, 39); screen.fill()
    end

    -- playhead
    if is_play then screen.level(15); screen.rect(x, 43, sw - 1, 1); screen.fill() end
    -- edit cursor
    if is_edit then screen.level(10); screen.rect(x, 44, sw - 1, 1); screen.fill() end
  end

  -- param list
  local s = sel[2]
  local sn = musicutil.SCALES[params:get("seq_scale")].name
  if #sn > 8 then sn = string.sub(sn, 1, 7) .. "." end
  local step = seq.data[util.clamp(es, 1, len)]
  local note_name = #seq.scale_notes > 0 and musicutil.note_num_to_name(note_in_scale(step.degree), true) or "?"
  local vals = {
    string.format("%d", es),
    note_name,
    string.format("%d", step.vel),
    string.format("%.0f%%", step.gate * 100),
    string.format("%d", len),
    DIR_NAMES[seq.dir],
    DIV_NAMES[params:get("seq_division")],
    musicutil.note_num_to_name(params:get("seq_root"), true),
    sn,
  }
  local param_labels = {"stp", "pit", "vel", "gte", "len", "dir", "div", "rt", "scl"}

  -- draw as 3 rows of 3
  for i = 1, #SEQ_PARAMS do
    local col = ((i - 1) % 3)
    local row = math.floor((i - 1) / 3)
    local x = 2 + col * 43
    local y = 50 + row * 7
    local is = i == s
    screen.level(is and 15 or 4)
    screen.move(x, y); screen.text((is and ">" or " ") .. param_labels[i] .. " " .. vals[i])
  end
end

local function draw_matrix()
  local cur = sel[3]
  local visible = 7
  local start = math.max(1, math.min(cur - 3, MAT_ITEM_COUNT - visible + 1))

  for i = 0, visible - 1 do
    local idx = start + i
    if idx > MAT_ITEM_COUNT then break end
    local item_type, label, value = mat_item_info(idx)
    local y = 13 + i * 7
    local is = idx == cur

    if is then screen.level(15); screen.move(1, y + 1); screen.text(">") end
    screen.level(is and 15 or 5); screen.move(8, y + 1); screen.text(label)

    if item_type == "route" then
      local cell = idx - 7; local src = math.ceil(cell / 5); local dst = ((cell - 1) % 5) + 1
      local v = matrix[src][dst]
      local bar_x, bar_w = 74, 32
      local mid = bar_x + bar_w / 2
      screen.level(2); screen.move(mid, y - 1); screen.line(mid, y + 3); screen.stroke()
      if math.abs(v) > 0.01 then
        local fw = math.floor(math.abs(v) * bar_w / 2)
        screen.level(is and 12 or 5)
        if v > 0 then screen.rect(mid, y - 1, fw, 4); screen.fill()
        else screen.rect(mid - fw, y - 1, fw, 4); screen.fill() end
      end
      screen.level(is and 8 or 3); screen.move(110, y + 1); screen.text(value)
    else
      screen.level(is and 10 or 4); screen.move(74, y + 1); screen.text(value)
      if item_type == "lfo_rate" or item_type == "lfo_shape" then
        local which = math.ceil(idx / 2)
        local act = math.abs(lfo.val[which])
        screen.level(math.floor(act * 10) + 2)
        screen.circle(124, y, 2); screen.fill()
      end
    end
  end

  screen.level(3)
  if start > 1 then screen.move(124, 11); screen.text("^") end
  if start + visible - 1 < MAT_ITEM_COUNT then screen.move(124, 63); screen.text("v") end
end

local function draw_robot()
  if not robot.active then
    screen.level(6); screen.move(14, 28); screen.text("the spirits are quiet")
    screen.level(3); screen.move(14, 40); screen.text("K2+K3 to begin the seance")
    if snapshot then
      screen.level(4); screen.move(14, 52); screen.text("snapshot saved")
    end
    return
  end

  local s = sel[4]

  -- mindset (big)
  screen.level(s == 1 and 15 or 10); screen.move(2, 18)
  screen.text((s == 1 and "> " or "  ") .. Bandmate.MINDSET_NAMES[bandmate.mindset])

  -- personality
  screen.level(s == 2 and 15 or 6); screen.move(2, 27)
  screen.text((s == 2 and "> " or "  ") .. robot_profile.PERSONALITIES[robot.personality])

  -- phase + intensity
  screen.level(10); screen.move(2, 37)
  screen.text(Explorer.PHASE_NAMES[explorer.phase])
  screen.level(2); screen.rect(56, 31, 70, 5); screen.fill()
  screen.level(frozen and 3 or 12); screen.rect(56, 31, math.floor(explorer.intensity * 70), 5); screen.fill()

  -- breathing + energy
  screen.level(6); screen.move(2, 46)
  screen.text(bandmate.breath_phase)
  screen.level(2); screen.rect(56, 40, 70, 5); screen.fill()
  local br_col = bandmate.breath_phase == "silence" and 2 or (bandmate.breath_phase == "build" and 10 or 7)
  screen.level(br_col); screen.rect(56, 40, math.floor(bandmate.energy * 70), 5); screen.fill()

  -- form + chaos
  screen.level(5); screen.move(2, 55)
  screen.text("form: " .. bandmate.form_phase)
  screen.move(70, 55); screen.text(string.format("chaos %.2f", chaos.coeff_x))

  -- bottom: mutation + bar + snapshot hint
  screen.level(3); screen.move(2, 64)
  screen.text(explorer.last_mutation ~= "" and explorer.last_mutation or "")
  screen.move(50, 64); screen.text("bar " .. math.floor(robot.conductor_beat / 4))
  if snapshot then screen.level(4); screen.move(90, 64); screen.text("K3=snap") end
end

function redraw()
  screen.clear()
  draw_header()
  if page == 1 then draw_play()
  elseif page == 2 then draw_seq()
  elseif page == 3 then draw_matrix()
  elseif page == 4 then draw_robot() end
  screen.update()
  grid_redraw()
end

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------

function cleanup()
  if my_lattice then my_lattice:destroy() end
  if gate_clock_id then clock.cancel(gate_clock_id) end
  engine.tape_all_off()
  moog_stop()
  if midi_out_device and seq.last_note then
    midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
  end
end
