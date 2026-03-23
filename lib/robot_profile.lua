-- robot_profile.lua
-- robot mod configuration for seance
-- defines what the conductor can touch, how much, and when
--
-- the robot is a conductor, not a randomizer.
-- it rides parameters like a DJ rides a filter.

local profile = {}

-- personality modes
profile.PERSONALITIES = {"chill", "aggressive", "chaotic"}

-- taming strength per personality (how hard conductor pulls back)
profile.TAME_STRENGTH = {0.25, 0.08, 0.02}

-- params the robot NEVER touches
profile.never_touch = {
  "midi_out_ch",
  "midi_in_ch",
  "clock_source",
}

-- param definitions:
--   group: timbral / rhythmic / melodic / spatial / structural
--   weight: 0-1, probability of modulation per conductor tick (0.95 = ride constantly)
--   sensitivity: 0-1, magnitude of change per tick
--   direction: "up", "down", "both"
--   range_lo, range_hi: bounds (nil = use param's own range)
--   description: what this does musically

profile.params = {
  -- === MACROS (the big levers) ===
  macro_spirit = {
    group = "timbral",
    weight = 0.90,
    sensitivity = 0.6,
    direction = "both",
    range_lo = 0.05,
    range_hi = 0.95,
    description = "tape/moog blend — ride this like a crossfader",
  },
  macro_filter = {
    group = "timbral",
    weight = 0.95,
    sensitivity = 0.7,
    direction = "both",
    range_lo = 0.05,
    range_hi = 0.95,
    description = "the money knob — filter sweep is the soul of this script",
  },
  macro_chaos = {
    group = "structural",
    weight = 0.40,
    sensitivity = 0.3,
    direction = "both",
    range_lo = 0.0,
    range_hi = 0.85,
    description = "mutation density — careful, high values destroy patterns",
  },

  -- === TAPE (Mellotron) ===
  tape_warble = {
    group = "timbral",
    weight = 0.50,
    sensitivity = 0.3,
    direction = "both",
    range_lo = 0.05,
    range_hi = 0.8,
    description = "tape transport imperfection depth",
  },
  tape_attack = {
    group = "timbral",
    weight = 0.20,
    sensitivity = 0.2,
    direction = "both",
    description = "tape voice attack time",
  },
  tape_release = {
    group = "timbral",
    weight = 0.25,
    sensitivity = 0.25,
    direction = "both",
    description = "tape voice release — longer = more ghostly",
  },

  -- === MOOG (MiniMoog) ===
  moog_pw = {
    group = "timbral",
    weight = 0.45,
    sensitivity = 0.35,
    direction = "both",
    range_lo = 0.1,
    range_hi = 0.9,
    description = "pulse width — subtle but powerful timbre shift",
  },
  moog_osc1 = {
    group = "timbral",
    weight = 0.30,
    sensitivity = 0.25,
    direction = "both",
    description = "saw oscillator level",
  },
  moog_osc2 = {
    group = "timbral",
    weight = 0.30,
    sensitivity = 0.25,
    direction = "both",
    description = "pulse oscillator level",
  },
  moog_osc3 = {
    group = "timbral",
    weight = 0.30,
    sensitivity = 0.25,
    direction = "both",
    description = "sub oscillator level",
  },
  moog_porta = {
    group = "melodic",
    weight = 0.20,
    sensitivity = 0.15,
    direction = "both",
    range_lo = 0.0,
    range_hi = 0.6,
    description = "portamento glide time",
  },

  -- === SEQUENCER ===
  seq_direction = {
    group = "rhythmic",
    weight = 0.15,
    sensitivity = 1.0,
    direction = "both",
    description = "sequence playback direction",
  },
  seq_length = {
    group = "structural",
    weight = 0.10,
    sensitivity = 0.3,
    direction = "both",
    range_lo = 4,
    range_hi = 16,
    description = "sequence length — changes rhythmic feel",
  },

  -- === REVERB ===
  verb_room = {
    group = "spatial",
    weight = 0.35,
    sensitivity = 0.3,
    direction = "both",
    range_lo = 0.2,
    range_hi = 0.95,
    description = "reverb room size — space as instrument",
  },
  verb_damp = {
    group = "spatial",
    weight = 0.25,
    sensitivity = 0.2,
    direction = "both",
    description = "reverb damping — bright vs dark space",
  },
  verb_mix = {
    group = "spatial",
    weight = 0.30,
    sensitivity = 0.25,
    direction = "both",
    range_lo = 0.1,
    range_hi = 0.7,
    description = "reverb wet/dry — don't drown everything",
  },

  -- === LFOs ===
  lfo_rate_1 = {
    group = "modulation",
    weight = 0.55,
    sensitivity = 0.5,
    direction = "both",
    description = "LFO 1 rate — ride this",
  },
  lfo_rate_2 = {
    group = "modulation",
    weight = 0.55,
    sensitivity = 0.5,
    direction = "both",
    description = "LFO 2 rate — ride this",
  },
  lfo_rate_3 = {
    group = "modulation",
    weight = 0.55,
    sensitivity = 0.5,
    direction = "both",
    description = "LFO 3 rate — ride this",
  },
  lfo_shape_1 = {
    group = "modulation",
    weight = 0.20,
    sensitivity = 1.0,
    direction = "both",
    description = "LFO 1 waveform",
  },
  lfo_shape_2 = {
    group = "modulation",
    weight = 0.20,
    sensitivity = 1.0,
    direction = "both",
    description = "LFO 2 waveform",
  },
  lfo_shape_3 = {
    group = "modulation",
    weight = 0.20,
    sensitivity = 1.0,
    direction = "both",
    description = "LFO 3 waveform",
  },

  -- === MATRIX ROUTING (the ARP 2500 heart) ===
  -- these are the patch cables — the conductor rewires constantly
  matrix_1_1 = { group = "matrix", weight = 0.60, sensitivity = 0.5, direction = "both", description = "LFO1>warble" },
  matrix_1_2 = { group = "matrix", weight = 0.70, sensitivity = 0.6, direction = "both", description = "LFO1>cutoff" },
  matrix_1_3 = { group = "matrix", weight = 0.45, sensitivity = 0.4, direction = "both", description = "LFO1>res" },
  matrix_1_4 = { group = "matrix", weight = 0.50, sensitivity = 0.5, direction = "both", description = "LFO1>pw" },
  matrix_1_5 = { group = "matrix", weight = 0.35, sensitivity = 0.4, direction = "both", description = "LFO1>transpose" },
  matrix_2_1 = { group = "matrix", weight = 0.55, sensitivity = 0.5, direction = "both", description = "LFO2>warble" },
  matrix_2_2 = { group = "matrix", weight = 0.65, sensitivity = 0.6, direction = "both", description = "LFO2>cutoff" },
  matrix_2_3 = { group = "matrix", weight = 0.50, sensitivity = 0.5, direction = "both", description = "LFO2>res" },
  matrix_2_4 = { group = "matrix", weight = 0.55, sensitivity = 0.5, direction = "both", description = "LFO2>pw" },
  matrix_2_5 = { group = "matrix", weight = 0.30, sensitivity = 0.3, direction = "both", description = "LFO2>transpose" },
  matrix_3_1 = { group = "matrix", weight = 0.50, sensitivity = 0.5, direction = "both", description = "LFO3>warble" },
  matrix_3_2 = { group = "matrix", weight = 0.60, sensitivity = 0.5, direction = "both", description = "LFO3>cutoff" },
  matrix_3_3 = { group = "matrix", weight = 0.45, sensitivity = 0.4, direction = "both", description = "LFO3>res" },
  matrix_3_4 = { group = "matrix", weight = 0.50, sensitivity = 0.5, direction = "both", description = "LFO3>pw" },
  matrix_3_5 = { group = "matrix", weight = 0.25, sensitivity = 0.3, direction = "both", description = "LFO3>transpose" },
  matrix_4_1 = { group = "matrix", weight = 0.40, sensitivity = 0.4, direction = "both", description = "S&H>warble" },
  matrix_4_2 = { group = "matrix", weight = 0.55, sensitivity = 0.5, direction = "both", description = "S&H>cutoff" },
  matrix_4_3 = { group = "matrix", weight = 0.35, sensitivity = 0.3, direction = "both", description = "S&H>res" },
  matrix_4_4 = { group = "matrix", weight = 0.40, sensitivity = 0.4, direction = "both", description = "S&H>pw" },
  matrix_4_5 = { group = "matrix", weight = 0.30, sensitivity = 0.4, direction = "both", description = "S&H>transpose" },

  -- === CHAOS POLYNOMIAL ===
  chaos_coeff = {
    group = "modulation",
    weight = 0.30,
    sensitivity = 0.3,
    direction = "both",
    description = "chaos polynomial coefficient drift",
  },
}

-- phase-specific behavior hints for the conductor
profile.phase_hints = {
  SUMMON = {
    -- quiet, expectant — sparse routing, slow LFOs
    prefer_low = {"macro_chaos", "verb_mix", "lfo_rate_1", "lfo_rate_2", "lfo_rate_3"},
    prefer_high = {"matrix_1_1"}, -- subtle warble modulation only
    suppress = {"seq_direction", "matrix_1_5", "matrix_2_5", "matrix_3_5", "matrix_4_5"},
  },
  HAUNT = {
    -- ghostly — deep modulation, warble and filter routing active
    prefer_low = {"macro_chaos"},
    prefer_high = {"tape_warble", "verb_room", "tape_release",
      "matrix_1_1", "matrix_2_2", "matrix_3_1", "lfo_rate_1"},
    suppress = {},
  },
  POSSESS = {
    -- full intensity — everything routed, fast LFOs, chaos high
    prefer_low = {},
    prefer_high = {"macro_filter", "macro_chaos", "moog_pw",
      "matrix_1_2", "matrix_2_2", "matrix_3_3", "matrix_4_2",
      "lfo_rate_1", "lfo_rate_2", "lfo_rate_3", "chaos_coeff"},
    suppress = {},
  },
  RELEASE = {
    -- decaying — clear matrix routes, slow down, reverb up
    prefer_low = {"macro_chaos", "macro_filter",
      "matrix_1_2", "matrix_2_2", "matrix_3_3", "matrix_4_2",
      "lfo_rate_1", "lfo_rate_2", "lfo_rate_3"},
    prefer_high = {"verb_room", "verb_mix", "tape_release", "matrix_1_1"},
    suppress = {"seq_direction", "seq_length"},
  },
}

return profile
