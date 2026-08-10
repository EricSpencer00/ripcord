# Ripcord — offline mastering for macOS

Design record, 2026-08-10.

## Goal

Drop an audio file on a Mac app, get back a mastered WAV. No account, no upload, no network
access at all. One control. The app should be honest about what it did.

## Shape

Swift 6 / SwiftUI, universal arm64 + x86_64, macOS 14+, no third-party dependencies. SwiftPM
package plus a `make app` script that assembles and ad-hoc signs `Ripcord.app`.

Sandboxed with `com.apple.security.app-sandbox` and `files.user-selected.read-write`, and
deliberately *without* any network entitlement, so "works offline" is enforced by the OS rather
than asserted. CI fails if a network entitlement ever appears.

### Modules

| Module | Job | Depends on |
|---|---|---|
| `IO/AudioIO` | decode wav/mp3/m4a/aiff/flac, write 24-bit WAV | AVFoundation |
| `Analysis/` | BS.1770-4 loudness, true peak, octave spectrum, correlation | Accelerate |
| `Chain/ChainDesigner` | pure `Analysis -> MasterSettings` | nothing |
| `Chain/Masterer` | render settings over buffers, land on the loudness target | Analysis + DSP |
| `DSP/` | biquads, LR4 crossover, compressor, true-peak limiter, mid/side | Accelerate |
| `Ripcord/` | drop → wipe → report → A/B → save | SwiftUI |

`ChainDesigner` being a pure function is the load-bearing seam: every mastering decision is
testable without rendering audio or starting an engine.

### Departure from the original plan

The first sketch built the processing chain out of Apple's system AudioUnits, and a probe
confirmed `AUNBandEQ`, `AUMultibandCompressor`, `AUPeakLimiter` and offline manual rendering all
work. Writing the DSP in-house instead was chosen because it makes the whole pipeline a
deterministic pure function over sample buffers — unit-testable with no engine lifecycle, and
usable from a CLI harness, which is how the chain got checked against real files before any UI
existed. AVFoundation is now used only for decode and encode.

## Decisions

**Loudness target.** Gentle / Standard / Loud = −14 / −11 / −9 LUFS, ceilings −1.0 / −1.0 / −0.8
dBTP. The target is hit by measuring the rendered output and re-running the makeup gain, up to
four passes, rather than by predicting it. Lands within ~0.1 LU.

**Tone.** Measured octave-band energy is compared against a target curve stated as energy per
octave (so pink noise reads flat). Deviations are applied at 0.45–0.70 of measured error
depending on intensity, clamped per band. Because octave-spaced bells overlap heavily, the
gains are solved iteratively against the analytically evaluated cascade response rather than
set directly.

**Dynamics.** Four bands split by an LR4 tree with allpass compensation, so bands sum flat.
Ratio is derived from crest factor: below 8 dB of crest the material is already crushed and the
ratio drops to 1.25:1 on its own.

**Stereo.** Width from measured correlation; the side channel is high-passed at 110 Hz when the
low end is smeared, so bass stays mono-compatible.

**Idempotence.** A file already near target with a tonal balance close to the curve is flagged
`alreadyMastered` and gets halved corrections. Repeated passes must ask for strictly less
correction each time — there is a test for exactly this.

**Silence.** Returned untouched and reported as such. Normalizing silence would mean amplifying
a noise floor by 100 dB.

## Measurement correctness

Every decision hangs off the measurement, so both meters are pinned to external references.

*Loudness* is cross-checked against ffmpeg's `ebur128`: −27.09 vs −27.1 on a 1 kHz tone, −16.19
vs −16.2 and −13.80 vs −13.8 on real tracks. The K-weighting shelf must be built from the
standard's own topology with a bilinear `tan` prewarp — feeding its stated f0/Q/gain to an RBJ
shelf gives a filter 0.22 dB low at 1 kHz, which shifted a tone by a quarter of a LU. The
derived coefficients match Table 1 to ~1e-16 and stay correct at other sample rates.

*True peak* uses 8x oversampling with a 128-tap Kaiser-windowed sinc. The standard's 4x minimum,
with a 48-tap Blackman window, read 0.115 dB low against a 16x reference — under-reading is the
direction that lets a master exceed its own ceiling. Each polyphase branch runs as a `vDSP_conv`,
which made the more accurate version no slower than the one it replaced.

## The ceiling guarantee

The limiter's ceiling is structural, not a clipper. `desired[i]` is the gain putting sample `i`
on the ceiling; take a sliding minimum over `|j-i| <= R`, then smooth with a kernel of support
`<= R`. Every averaged term is a minimum over a window containing `i`, hence `<= desired[i]`, so
the average is too. The release stage only lowers gain further. Processing is offline, so the
curve is non-causal and no output delay is introduced.

## Testing

45 tests, no binary fixtures — all signals are generated from a seeded LCG. The ones that
matter: the ceiling invariant under 18 dB of overdrive and against deliberate inter-sample peaks;
the crossover summing flat *at* the crossover frequencies; the EQ solver delivering its requested
per-band gains; convergence across repeated passes; and loudness targeting at 44.1/48/96 kHz.

## Cut

Stems, genre presets, batch queue, plugin build, waveform editor. One control, one job.

## Known limitation

One target curve for all material. A folk recording and a trap beat get the same curve at
different strengths. Genre-aware targets are the obvious next step.
