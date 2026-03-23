// Engine_Seance
// ghost synthesis — mellotron + minimoog + modular
//
// tape voices: polyphonic mellotron-inspired (strings/flutes/choir)
// moog voice: monophonic 3-osc + ladder filter
// shared reverb bus

Engine_Seance : CroneEngine {
    var <tapeVoices;
    var <moogSynth;
    var <verbSynth;
    var <verbBus;
    var <tapeGroup, <moogGroup, <fxGroup;

    // tape state
    var <tapeWarble = 0.3;
    var <tapeTone = 2000;
    var <tapeVoiceType = 0;
    var <tapeAttack = 0.08;
    var <tapeRelease = 1.2;
    var <tapeLevel = 0.6;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        tapeVoices = Dictionary.new;

        verbBus = Bus.audio(context.server, 2);

        tapeGroup = Group.new(context.xg);
        moogGroup = Group.after(tapeGroup);
        fxGroup = Group.after(moogGroup);

        // ── TAPE (Mellotron) ──────────────────────────────────
        // three detuned voices with wow/flutter, three timbral modes
        // strings: saw-heavy ensemble
        // flutes: triangle/sine breathiness
        // choir: formant resonance
        SynthDef(\seance_tape, {
            arg out=0, verb_out=0, freq=440, amp=0.5, gate=1,
                warble=0.3, tone=2000, voice_type=0,
                attack=0.08, release=1.2, level=0.6;
            var sig, env, wow, flutter;
            var f1, f2, f3, s1, s2, s3;

            // tape transport imperfections
            wow = SinOsc.kr(
                0.4 + LFNoise1.kr(0.1).range(-0.1, 0.1),
                0,
                warble * 2
            );
            flutter = LFNoise2.kr(6, warble * 0.8);

            // three tape heads, slightly misaligned
            f1 = freq * (1 + ((wow + flutter) * 0.003));
            f2 = freq * (1.002 + ((wow + flutter) * 0.004));
            f3 = freq * (0.998 + ((wow + flutter) * 0.002));

            // strings: saw ensemble
            s1 = VarSaw.ar(
                [f1, f2, f3], 0,
                LFNoise1.kr(0.3).range(0.3, 0.7)
            ).sum / 3;

            // flutes: breathy triangle
            s2 = (LFTri.ar([f1, f2, f3]).sum / 3 * 0.6)
                + (SinOsc.ar(freq * 2, 0, 0.15));

            // choir: formant resonances
            s3 = Formant.ar(
                f1,
                LFNoise1.kr(0.2).range(600, 2400),
                LFNoise1.kr(0.15).range(200, 800),
                0.3
            ) + (LFTri.ar(f2) * 0.3);

            // crossfade between timbres
            sig = SelectX.ar(voice_type.lag(0.3), [s1, s2, s3]);

            // tape hiss
            sig = sig + (PinkNoise.ar(0.008 * warble));

            // tape frequency rolloff
            sig = RLPF.ar(sig, tone.clip(60, 16000), 0.6);

            // gentle saturation (tape compression)
            sig = (sig * 1.3).tanh;

            // envelope
            env = EnvGen.kr(
                Env.asr(attack, 1, release, [2, -4]),
                gate,
                doneAction: Done.freeSelf
            );

            sig = sig * env * amp * level;
            sig = Splay.ar(
                [sig, DelayL.ar(sig, 0.02, 0.004)],
                0.6
            );
            Out.ar(out, sig);
            Out.ar(verb_out, sig * 0.3);
        }).add;

        // ── MOOG (MiniMoog) ──────────────────────────────────
        // 3 oscillators: saw + pulse(PWM) + sub saw
        // MoogFF ladder filter, portamento, filter envelope
        SynthDef(\seance_moog, {
            arg out=0, verb_out=0, freq=220, amp=0.5, gate=0,
                cutoff=1200, res=0.3, porta=0.05,
                pw=0.5, osc1=1.0, osc2=0.5, osc3=0.3,
                f_env_amt=2000,
                f_attack=0.01, f_decay=0.3, f_sustain=0.5, f_release=0.3,
                a_attack=0.005, a_decay=0.1, a_sustain=0.9, a_release=0.2,
                level=0.6;
            var sig, filtEnv, ampEnv, f;
            var o1, o2, o3, totalOsc;

            // portamento
            f = Lag.kr(freq, porta);

            // three oscillators
            o1 = Saw.ar(f) * osc1;
            o2 = Pulse.ar(f * 1.005, pw) * osc2;
            o3 = Saw.ar(f * 0.4995) * osc3; // sub octave, slight detune

            totalOsc = (osc1 + osc2 + osc3).max(0.1);
            sig = (o1 + o2 + o3) / totalOsc;

            // pre-filter drive
            sig = (sig * 1.5).tanh;

            // filter envelope
            filtEnv = EnvGen.kr(
                Env.adsr(f_attack, f_decay, f_sustain, f_release),
                gate
            );

            // moog ladder filter
            sig = MoogFF.ar(
                sig,
                (cutoff + (filtEnv * f_env_amt)).clip(20, 18000),
                res.clip(0, 3.8)
            );

            // amplitude envelope
            ampEnv = EnvGen.kr(
                Env.adsr(a_attack, a_decay, a_sustain, a_release),
                gate
            );

            sig = sig * ampEnv * amp * level;
            Out.ar(out, sig ! 2);
            Out.ar(verb_out, sig ! 2 * 0.15);
        }).add;

        // ── REVERB ───────────────────────────────────────────
        SynthDef(\seance_verb, {
            arg in_bus=0, out=0, mix=0.3, room=0.7, damp=0.5;
            var dry, wet;
            dry = In.ar(in_bus, 2);
            wet = FreeVerb2.ar(dry[0], dry[1], mix, room, damp);
            Out.ar(out, wet);
        }).add;

        context.server.sync;

        // ── INSTANTIATE ──────────────────────────────────────

        verbSynth = Synth(\seance_verb, [
            \in_bus, verbBus,
            \out, context.out_b,
            \mix, 0.3,
            \room, 0.7,
            \damp, 0.5,
        ], fxGroup);

        moogSynth = Synth(\seance_moog, [
            \out, context.out_b,
            \verb_out, verbBus,
            \gate, 0,
            \cutoff, 1200,
            \res, 0.3,
            \porta, 0.05,
            \level, 0.6,
        ], moogGroup);

        // ── COMMANDS ─────────────────────────────────────────

        // -- tape --
        this.addCommand("tape_on", "iff", { arg msg;
            var id = msg[1].asInteger;
            var freq = msg[2];
            var vel = msg[3];
            if(tapeVoices[id].notNil, {
                tapeVoices[id].set(\gate, 0);
            });
            tapeVoices[id] = Synth(\seance_tape, [
                \out, context.out_b,
                \verb_out, verbBus,
                \freq, freq,
                \amp, vel / 127,
                \gate, 1,
                \warble, tapeWarble,
                \tone, tapeTone,
                \voice_type, tapeVoiceType,
                \attack, tapeAttack,
                \release, tapeRelease,
                \level, tapeLevel,
            ], tapeGroup);
        });

        this.addCommand("tape_off", "i", { arg msg;
            var id = msg[1].asInteger;
            if(tapeVoices[id].notNil, {
                tapeVoices[id].set(\gate, 0);
                tapeVoices.removeAt(id);
            });
        });

        this.addCommand("tape_warble", "f", { arg msg;
            tapeWarble = msg[1];
            tapeVoices.do({ |v| v.set(\warble, tapeWarble) });
        });

        this.addCommand("tape_tone", "f", { arg msg;
            tapeTone = msg[1];
            tapeVoices.do({ |v| v.set(\tone, tapeTone) });
        });

        this.addCommand("tape_voice_type", "f", { arg msg;
            tapeVoiceType = msg[1];
            tapeVoices.do({ |v| v.set(\voice_type, tapeVoiceType) });
        });

        this.addCommand("tape_attack", "f", { arg msg;
            tapeAttack = msg[1];
        });

        this.addCommand("tape_release", "f", { arg msg;
            tapeRelease = msg[1];
        });

        this.addCommand("tape_level", "f", { arg msg;
            tapeLevel = msg[1];
            tapeVoices.do({ |v| v.set(\level, tapeLevel) });
        });

        this.addCommand("tape_all_off", "", { arg msg;
            tapeVoices.do({ |v| v.set(\gate, 0) });
            tapeVoices.clear;
        });

        // -- moog --
        this.addCommand("moog_hz", "f", { arg msg;
            moogSynth.set(\freq, msg[1]);
        });

        this.addCommand("moog_gate", "i", { arg msg;
            moogSynth.set(\gate, msg[1]);
        });

        this.addCommand("moog_vel", "f", { arg msg;
            moogSynth.set(\amp, msg[1] / 127);
        });

        this.addCommand("moog_cutoff", "f", { arg msg;
            moogSynth.set(\cutoff, msg[1]);
        });

        this.addCommand("moog_res", "f", { arg msg;
            moogSynth.set(\res, msg[1]);
        });

        this.addCommand("moog_porta", "f", { arg msg;
            moogSynth.set(\porta, msg[1]);
        });

        this.addCommand("moog_pw", "f", { arg msg;
            moogSynth.set(\pw, msg[1]);
        });

        this.addCommand("moog_osc_mix", "fff", { arg msg;
            moogSynth.set(\osc1, msg[1], \osc2, msg[2], \osc3, msg[3]);
        });

        this.addCommand("moog_level", "f", { arg msg;
            moogSynth.set(\level, msg[1]);
        });

        this.addCommand("moog_f_env", "f", { arg msg;
            moogSynth.set(\f_env_amt, msg[1]);
        });

        // -- reverb --
        this.addCommand("verb_mix", "f", { arg msg;
            verbSynth.set(\mix, msg[1]);
        });

        this.addCommand("verb_room", "f", { arg msg;
            verbSynth.set(\room, msg[1]);
        });

        this.addCommand("verb_damp", "f", { arg msg;
            verbSynth.set(\damp, msg[1]);
        });
    }

    free {
        tapeVoices.do({ |v| v.free });
        moogSynth.free;
        verbSynth.free;
        verbBus.free;
        tapeGroup.free;
        moogGroup.free;
        fxGroup.free;
    }
}
