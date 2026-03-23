-- seance
-- summoning analog ghosts
--
-- four spirits haunting this rack:
--   TAPE  — mellotron tape deck ensemble
--   MOOG  — minimoog 3-osc mono beast
--   SEQ   — doepfer/arp 1601 sequencer
--   MATRIX — arp 2500 modulation routing
--
-- ENC1: page select
-- ENC2/3: page params (see below)
-- KEY2: play/stop sequencer
-- KEY3: shift modifier
--
-- TAPE page:  E2=warble  E3=tone
-- MOOG page:  E2=cutoff  E3=resonance
-- SEQ page:   E2=step pitch  E3=length
--   (shift)   E2=root note   E3=scale
-- MATRIX page: E2=navigate  E3=amount
--   (shift+E2=change source row)
--
-- MIDI in: plays tape (mellotron) voices
-- MIDI out: sequencer note output
-- grid: seq steps + matrix routing

engine.name = "Seance"

local musicutil = require "musicutil"
local lattice_lib = require "lattice"

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local PAGES = {"TAPE", "MOOG", "SEQ", "MATRIX"}
local SEQ_MAX = 16
local DIVISIONS = {1, 1/2, 1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1", "1/2", "1/4", "1/8", "1/16", "1/32"}
local DIR_NAMES = {">>", "<<", "<>", "??"}
local VOICE_NAMES = {"strings", "flutes", "choir"}
local SHAPE_NAMES = {"sin", "tri", "sqr", "ramp"}

local MOD_SRC = {"LFO1", "LFO2", "LFO3", "S&H"}
local MOD_DST = {"warbl", "cut", "res", "pw", "xpos"}
local MOD_DST_FULL = {"warble", "cutoff", "resonance", "pulse width", "transpose"}
local NUM_SRC = #MOD_SRC
local NUM_DST = #MOD_DST

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local page = 1
local shift = false

-- tape (mellotron) voice tracking
local tape_voices = {} -- note -> voice_id
local tape_next_id = 1

-- moog mono state
local moog_note_on = false

-- sequencer (doepfer / arp 1601)
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
local mat_cursor = {1, 1} -- {src, dst}

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

-- hardware
local g = grid.connect()
local midi_out_device
local midi_in_device
local my_lattice
local seq_sprocket
local mod_sprocket

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
  if shape == 1 then     -- sine
    return math.sin(p * 2 * math.pi)
  elseif shape == 2 then -- triangle
    return p < 0.5 and (p * 4 - 1) or (3 - p * 4)
  elseif shape == 3 then -- square
    return p < 0.5 and 1 or -1
  else                   -- ramp
    return p * 2 - 1
  end
end

local function mod_sum(dst_idx)
  local total = 0
  for s = 1, NUM_SRC do
    local val = s <= 3 and lfo.val[s] or sh_val
    total = total + (matrix[s][dst_idx] * val)
  end
  return total
end

----------------------------------------------------------------
-- ENGINE INTERFACE
----------------------------------------------------------------

local function update_modulation()
  -- tape modulation
  local w = params:get("tape_warble") + mod_sum(1) * 0.5
  local t = params:get("tape_tone") + mod_sum(2) * 4000
  engine.tape_warble(util.clamp(w, 0, 1))
  engine.tape_tone(util.clamp(t, 60, 16000))

  -- moog modulation
  local c = params:get("moog_cutoff") + mod_sum(2) * 6000
  local r = params:get("moog_res") + mod_sum(3) * 1.5
  local p = params:get("moog_pw") + mod_sum(4) * 0.4
  engine.moog_cutoff(util.clamp(c, 20, 18000))
  engine.moog_res(util.clamp(r, 0, 3.5))
  engine.moog_pw(util.clamp(p, 0.05, 0.95))
end

----------------------------------------------------------------
-- TAPE (MELLOTRON)
----------------------------------------------------------------

local function tape_note_on(note, vel)
  local id = tape_next_id
  tape_next_id = tape_next_id + 1
  if tape_next_id > 10000 then tape_next_id = 1 end
  tape_voices[note] = id
  local freq = musicutil.note_num_to_freq(note)
  engine.tape_on(id, freq, vel)
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
  local freq = musicutil.note_num_to_freq(note)
  engine.moog_hz(freq)
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
-- SEQUENCER (DOEPFER / ARP 1601)
----------------------------------------------------------------

local function seq_advance()
  local len = params:get("seq_length")

  if seq.dir == 1 then -- forward
    seq.pos = seq.pos % len + 1
  elseif seq.dir == 2 then -- reverse
    seq.pos = seq.pos - 1
    if seq.pos < 1 then seq.pos = len end
  elseif seq.dir == 3 then -- pendulum
    if seq.pend_fwd then
      seq.pos = seq.pos + 1
      if seq.pos >= len then seq.pend_fwd = false end
    else
      seq.pos = seq.pos - 1
      if seq.pos <= 1 then seq.pend_fwd = true end
    end
    seq.pos = util.clamp(seq.pos, 1, len)
  else -- random
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
    -- transpose modulation from matrix
    local xpose = math.floor(mod_sum(5) * 12 + 0.5)
    local degree = util.clamp(step.degree + xpose, 1, #seq.scale_notes)
    local note = note_in_scale(degree)
    local vel = step.vel

    moog_play(note, vel)

    -- midi out
    if midi_out_device then
      midi_out_device:note_on(note, vel, params:get("midi_out_ch"))
    end

    -- sample & hold trigger every 4 steps
    if seq.pos % 4 == 1 then
      sh_val = math.random() * 2 - 1
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
  params:add_group("tape_grp", "TAPE (Mellotron)", 6)

  params:add_control("tape_warble", "warble",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("tape_warble", function(v) engine.tape_warble(v) end)

  params:add_control("tape_tone", "tone",
    controlspec.new(100, 12000, 'exp', 1, 2000, "hz"))
  params:set_action("tape_tone", function(v) engine.tape_tone(v) end)

  params:add_option("tape_voice", "voice", VOICE_NAMES, 1)
  params:set_action("tape_voice", function(v) engine.tape_voice_type(v - 1) end)

  params:add_control("tape_attack", "attack",
    controlspec.new(0.005, 2, 'exp', 0, 0.08, "s"))
  params:set_action("tape_attack", function(v) engine.tape_attack(v) end)

  params:add_control("tape_release", "release",
    controlspec.new(0.05, 8, 'exp', 0, 1.2, "s"))
  params:set_action("tape_release", function(v) engine.tape_release(v) end)

  params:add_control("tape_level", "level",
    controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("tape_level", function(v) engine.tape_level(v) end)

  -- MOOG
  params:add_group("moog_grp", "MOOG (MiniMoog)", 9)

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
    engine.moog_osc_mix(
      params:get("moog_osc1"),
      params:get("moog_osc2"),
      params:get("moog_osc3"))
  end)

  params:add_control("moog_osc2", "osc 2 (pulse)",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("moog_osc2", function()
    engine.moog_osc_mix(
      params:get("moog_osc1"),
      params:get("moog_osc2"),
      params:get("moog_osc3"))
  end)

  params:add_control("moog_osc3", "osc 3 (sub)",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("moog_osc3", function()
    engine.moog_osc_mix(
      params:get("moog_osc1"),
      params:get("moog_osc2"),
      params:get("moog_osc3"))
  end)

  params:add_control("moog_f_env", "filter env",
    controlspec.new(0, 8000, 'lin', 1, 2000, "hz"))
  params:set_action("moog_f_env", function(v) engine.moog_f_env(v) end)

  params:add_control("moog_level", "level",
    controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("moog_level", function(v) engine.moog_level(v) end)

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

  -- midi
  midi_out_device = midi.connect(1)
  midi_in_device = midi.connect(1)
  midi_in_device.event = on_midi_event

  -- generate scale
  scale_generate()

  -- init sequencer: random melodic seed
  for i = 1, SEQ_MAX do
    seq.data[i] = {
      degree = math.random(1, math.min(#seq.scale_notes, 14)),
      vel = math.random(80, 120),
      active = math.random() > 0.3,
    }
  end

  -- init matrix: all zeros
  for s = 1, NUM_SRC do
    matrix[s] = {}
    for d = 1, NUM_DST do
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

  my_lattice:start()

  -- screen refresh
  local screen_metro = metro.init()
  screen_metro.event = function()
    anim_frame = anim_frame + 1
    reel_angle = reel_angle + (seq.playing and 0.06 or 0.01)
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
    page = util.clamp(page + d, 1, #PAGES)

  elseif page == 1 then -- TAPE
    if shift then
      if n == 2 then params:delta("tape_voice", d)
      elseif n == 3 then params:delta("tape_level", d) end
    else
      if n == 2 then params:delta("tape_warble", d)
      elseif n == 3 then params:delta("tape_tone", d) end
    end

  elseif page == 2 then -- MOOG
    if shift then
      if n == 2 then params:delta("moog_porta", d)
      elseif n == 3 then params:delta("moog_pw", d) end
    else
      if n == 2 then params:delta("moog_cutoff", d)
      elseif n == 3 then params:delta("moog_res", d) end
    end

  elseif page == 3 then -- SEQ
    if shift then
      if n == 2 then params:delta("seq_root", d)
      elseif n == 3 then params:delta("seq_scale", d) end
    else
      if n == 2 then
        -- edit current step pitch
        local len = params:get("seq_length")
        local s = util.clamp(seq.pos == 0 and 1 or seq.pos, 1, len)
        local max_deg = math.max(#seq.scale_notes, 1)
        seq.data[s].degree = util.clamp(seq.data[s].degree + d, 1, max_deg)
      elseif n == 3 then
        params:delta("seq_length", d)
      end
    end

  elseif page == 4 then -- MATRIX
    if n == 2 then
      if shift then
        mat_cursor[1] = util.clamp(mat_cursor[1] + d, 1, NUM_SRC)
      else
        mat_cursor[2] = util.clamp(mat_cursor[2] + d, 1, NUM_DST)
      end
    elseif n == 3 then
      local s, dst = mat_cursor[1], mat_cursor[2]
      matrix[s][dst] = util.clamp(matrix[s][dst] + d * 0.05, -1, 1)
    end
  end
end

function key(n, z)
  if n == 2 and z == 1 then
    seq.playing = not seq.playing
    if not seq.playing then
      moog_stop()
      if seq.last_note and midi_out_device then
        midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
      end
      seq.last_note = nil
      seq.pos = 0
    end
  elseif n == 3 then
    shift = z == 1
  end
end

----------------------------------------------------------------
-- GRID
----------------------------------------------------------------

function grid_key(x, y, z)
  if z == 0 then return end

  if page == 3 then -- SEQ
    local len = params:get("seq_length")
    if x <= len then
      if y == 1 then
        -- toggle step active
        seq.data[x].active = not seq.data[x].active
      elseif y >= 2 and y <= 8 then
        -- set pitch by row
        seq.data[x].degree = util.clamp((9 - y) * 2, 1, #seq.scale_notes)
        seq.data[x].active = true
      end
    end

  elseif page == 4 then -- MATRIX
    if x <= NUM_DST and y <= NUM_SRC then
      local v = matrix[y][x]
      if v == 0 then matrix[y][x] = 0.5
      elseif v > 0 then matrix[y][x] = -0.5
      else matrix[y][x] = 0 end
    end
  end

  grid_redraw()
end

function grid_redraw()
  if not g.device then return end
  g:all(0)

  local len = params:get("seq_length")

  if page == 3 then
    for x = 1, math.min(16, len) do
      local step = seq.data[x]
      -- playhead
      if x == seq.pos and seq.playing then
        for y = 1, 8 do g:led(x, y, 2) end
      end
      -- active indicator
      if step.active then
        local row = util.clamp(9 - math.ceil(step.degree / 2), 2, 8)
        g:led(x, row, x == seq.pos and 15 or 8)
      end
      -- top row: active toggle
      g:led(x, 1, step.active and 6 or 1)
    end

  elseif page == 4 then
    for s = 1, NUM_SRC do
      for d = 1, NUM_DST do
        local v = math.abs(matrix[s][d])
        local bright = math.floor(v * 12)
        if s == mat_cursor[1] and d == mat_cursor[2] then
          bright = 15
        end
        g:led(d, s, bright)
      end
    end
  end

  g:refresh()
end

----------------------------------------------------------------
-- SCREEN
----------------------------------------------------------------

local function draw_header(title)
  screen.level(15)
  screen.move(2, 8)
  screen.text(title)
  screen.level(2)
  screen.move(128 - screen.text_extents("seance"), 8)
  screen.text("seance")
  -- page dots
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.pixel(56 + (i - 1) * 4, 4)
    screen.fill()
  end
end

local function draw_tape_page()
  draw_header("TAPE")

  -- voice type
  screen.level(8)
  screen.move(30, 8)
  screen.text(VOICE_NAMES[params:get("tape_voice")])

  -- tape reels
  local cx1, cx2 = 32, 96
  local cy = 28
  local r = 12

  for _, cx in ipairs({cx1, cx2}) do
    -- reel outline
    screen.level(3)
    screen.circle(cx, cy, r)
    screen.stroke()
    -- hub
    screen.level(6)
    screen.circle(cx, cy, 3)
    screen.stroke()
    -- spokes
    for i = 0, 2 do
      local a = reel_angle + i * (math.pi * 2 / 3)
      screen.level(4)
      screen.move(cx + math.cos(a) * 3, cy + math.sin(a) * 3)
      screen.line(cx + math.cos(a) * (r - 1), cy + math.sin(a) * (r - 1))
      screen.stroke()
    end
  end

  -- tape path between reels with warble visualization
  local warble = params:get("tape_warble")
  screen.level(8)
  screen.move(cx1 + r + 1, cy - 2)
  for x = cx1 + r + 1, cx2 - r - 1 do
    local wave = math.sin((x + anim_frame * 3) * 0.3) * warble * 5
    screen.line(x, cy - 2 + wave)
  end
  screen.stroke()

  -- params
  screen.level(10)
  screen.move(2, 52)
  screen.text("warble " .. string.format("%.2f", params:get("tape_warble")))
  screen.move(72, 52)
  screen.text("tone " .. math.floor(params:get("tape_tone")))

  screen.level(4)
  screen.move(2, 62)
  screen.text("atk " .. string.format("%.2f", params:get("tape_attack")))
  screen.move(72, 62)
  screen.text("rel " .. string.format("%.1f", params:get("tape_release")))
end

local function draw_moog_page()
  draw_header("MOOG")

  -- oscillator mix bars
  local osc_vals = {
    params:get("moog_osc1"),
    params:get("moog_osc2"),
    params:get("moog_osc3"),
  }
  local osc_labels = {"SAW", "PUL", "SUB"}

  for i = 1, 3 do
    local x = 6 + (i - 1) * 20
    local h = math.floor(osc_vals[i] * 20)

    -- background
    screen.level(2)
    screen.rect(x, 14, 12, 22)
    screen.stroke()

    -- fill
    screen.level(8)
    screen.rect(x, 36 - h, 12, h)
    screen.fill()

    -- label
    screen.level(6)
    screen.move(x + 1, 44)
    screen.text(osc_labels[i])
  end

  -- filter curve
  local cutoff = params:get("moog_cutoff")
  local res = params:get("moog_res")
  local fx = 70
  local fy = 34

  screen.level(8)
  screen.move(fx, fy)
  local cutoff_n = math.log(cutoff / 20) / math.log(18000 / 20)
  for x = 0, 52 do
    local xn = x / 52
    local diff = xn - cutoff_n
    local y = 0
    if diff > 0 then
      y = diff * 30
    end
    -- resonance peak
    if math.abs(diff) < 0.1 then
      y = y - res * 5 * (1 - math.abs(diff) / 0.1)
    end
    screen.line(fx + x, fy + util.clamp(y, -10, 20))
  end
  screen.stroke()

  -- params
  screen.level(10)
  screen.move(2, 56)
  screen.text("cut " .. math.floor(cutoff))
  screen.move(72, 56)
  screen.text("res " .. string.format("%.2f", res))

  screen.level(4)
  screen.move(2, 64)
  screen.text("porta " .. string.format("%.3f", params:get("moog_porta")))
  screen.move(72, 64)
  screen.text("pw " .. string.format("%.2f", params:get("moog_pw")))
end

local function draw_seq_page()
  draw_header("SEQ")

  -- play state
  screen.level(seq.playing and 15 or 4)
  screen.move(30, 8)
  screen.text(seq.playing and "PLAY" or "stop")

  local len = params:get("seq_length")
  local step_w = math.max(2, math.floor(124 / len))
  local max_deg = math.max(#seq.scale_notes, 1)

  -- steps
  for i = 1, len do
    local x = 2 + (i - 1) * step_w
    local step = seq.data[i]

    if step.active then
      local h = math.floor((step.degree / max_deg) * 30)
      h = util.clamp(h, 2, 30)
      screen.level(i == seq.pos and 15 or 5)
      screen.rect(x, 44 - h, step_w - 1, h)
      screen.fill()
    else
      screen.level(1)
      screen.rect(x, 42, step_w - 1, 2)
      screen.fill()
    end

    -- playhead
    if i == seq.pos and seq.playing then
      screen.level(15)
      screen.rect(x, 46, step_w - 1, 2)
      screen.fill()
    end
  end

  -- info line
  screen.level(6)
  screen.move(2, 56)
  screen.text(DIR_NAMES[seq.dir])
  screen.move(18, 56)
  screen.text("len " .. len)
  screen.move(52, 56)
  screen.text(DIV_NAMES[params:get("seq_division")])

  screen.level(4)
  screen.move(2, 64)
  local root_name = musicutil.note_num_to_name(params:get("seq_root"), true)
  screen.text(root_name)
  screen.move(28, 64)
  local scale_name = musicutil.SCALES[params:get("seq_scale")].name
  -- truncate long scale names
  if #scale_name > 16 then scale_name = string.sub(scale_name, 1, 15) .. "." end
  screen.text(scale_name)
end

local function draw_matrix_page()
  draw_header("MATRIX")

  -- column headers
  local col_start = 28
  local col_w = 19
  for d = 1, NUM_DST do
    screen.level(d == mat_cursor[2] and 12 or 4)
    screen.move(col_start + (d - 1) * col_w, 18)
    screen.text(MOD_DST[d])
  end

  -- rows
  for s = 1, NUM_SRC do
    local y = 28 + (s - 1) * 9

    -- source label
    screen.level(s == mat_cursor[1] and 10 or 3)
    screen.move(2, y)
    screen.text(MOD_SRC[s])

    -- lfo activity indicator
    local activity = s <= 3 and math.abs(lfo.val[s]) or math.abs(sh_val)
    screen.level(math.floor(activity * 6) + 1)
    screen.pixel(24, y - 3)
    screen.fill()

    -- matrix cells
    for d = 1, NUM_DST do
      local v = matrix[s][d]
      local x = col_start + (d - 1) * col_w + 4

      local is_cursor = s == mat_cursor[1] and d == mat_cursor[2]

      if is_cursor then
        screen.level(15)
      elseif v ~= 0 then
        screen.level(math.floor(math.abs(v) * 8) + 3)
      else
        screen.level(1)
      end

      if v > 0.01 then
        screen.rect(x, y - 5, 6, 6)
        screen.fill()
      elseif v < -0.01 then
        screen.rect(x, y - 5, 6, 6)
        screen.stroke()
      else
        screen.pixel(x + 2, y - 2)
        screen.fill()
      end
    end
  end

  -- current cell info
  screen.level(8)
  screen.move(2, 64)
  screen.text(MOD_SRC[mat_cursor[1]] .. " > " .. MOD_DST_FULL[mat_cursor[2]])
  screen.level(12)
  screen.move(108, 64)
  local cv = matrix[mat_cursor[1]][mat_cursor[2]]
  screen.text(string.format("%+.2f", cv))
end

function redraw()
  screen.clear()

  if page == 1 then draw_tape_page()
  elseif page == 2 then draw_moog_page()
  elseif page == 3 then draw_seq_page()
  elseif page == 4 then draw_matrix_page()
  end

  screen.update()
  grid_redraw()
end

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------

function cleanup()
  -- stop lattice
  if my_lattice then my_lattice:destroy() end

  -- release tape voices
  engine.tape_all_off()

  -- release moog
  moog_stop()

  -- midi cleanup
  if midi_out_device and seq.last_note then
    midi_out_device:note_off(seq.last_note, 0, params:get("midi_out_ch"))
  end
end
