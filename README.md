# Ripcord

Drop a track on it, get a mastered WAV back. Everything happens on your Mac — there's no account, no upload, and no network code in the app at all.

I wanted the thing the online mastering services do, without the part where I hand my unreleased song to a website and wait for a queue. Most of the tracks I was throwing at it came out of Suno, which tends to land quiet, bass-heavy and a bit dull on top, so there was real work for it to do.

## What it does to your track

It measures the file first — integrated loudness to ITU-R BS.1770-4, true peak, loudness range, crest factor, stereo correlation, and octave-band energy. Then it decides what to do based on those numbers rather than applying a preset:

- A high-pass somewhere between 25 and 34 Hz, depending on whether there's real sub content down there or just rumble.
- Broad tone correction toward a target curve, applied at 60% of the measured error and clamped to ±4 dB per band, so it nudges rather than remodels.
- Up to three narrow cuts for resonances that stick out more than 3 dB above the local spectral trend. Never more than 3 dB each.
- Four-band compression whose ratio comes off the crest factor — if the track is already crushed it backs off to 1.25:1 on its own instead of squashing it further.
- Mid/side width from the measured correlation, with the side channel high-passed so the bass stays mono.
- A look-ahead true-peak limiter to hit the loudness target.

There's one control: Gentle, Standard or Loud (−14, −11 or −9 LUFS). That's it. It hits the target by measuring its own output and re-running, not by guessing, so it lands within about 0.1 LU.

When it's done you get an A/B player. B is the master, A is the original, and there's a "match level" toggle that's on by default — comparing a −16 LUFS original against a −11 LUFS master isn't a comparison, it's a volume test, and the louder one always wins.

## Install

Grab the `.app` from [Releases](https://github.com/EricSpencer00/ripcord/releases), or build it:

```bash
make app && open build/Ripcord.app
```

It's a universal binary, macOS 14+, no dependencies — the whole thing is Swift and Accelerate. The `.app` is about 2 MB. Since it's signed ad-hoc rather than notarized, the first launch needs a right-click → Open.

There's a CLI too, which is what I actually used to check the DSP against real files:

```bash
make cli
.build/release/ripcord-cli track.wav --intensity loud
.build/release/ripcord-cli track.wav --analyze     # just measure, write nothing
```

## Does the measurement actually work

This was the part I cared about getting right, because every decision in the chain hangs off it. I checked the meter against ffmpeg's `ebur128`, which is an independent implementation of the same standard:

| | ffmpeg | Ripcord |
|---|---|---|
| 1 kHz sine | −27.1 LUFS | −27.09 |
| Suno track | −16.2 LUFS | −16.19 |
| A Yeat rip | −13.8 LUFS | −13.80 |

It did not agree at first. A pure 1 kHz tone read 0.25 LU low while music was fine, which turned out to be the K-weighting shelf: BS.1770 gives you an f0, Q and gain for it, and if you feed those to the standard RBJ shelf formula — which is the obvious thing to do — you get a filter that's 0.22 dB low at 1 kHz. The standard's shelf is a different topology with a bilinear `tan` prewarp. Deriving it that way reproduces the reference coefficients in Table 1 to about 1e-16, and the tone snapped into line.

True peak had a similar story. The standard says oversample at least 4x; I did that with a 48-tap Blackman-windowed sinc and read 0.115 dB *low* against a 16x reference, which is the dangerous direction — under-reading a peak is how you ship a master that clips someone's converter. 8x with a 128-tap Kaiser window gets within 0.01 dB, and running each polyphase branch through vDSP made it slightly faster than the less accurate version it replaced.

A 2:17 track takes about 4 seconds end to end.

## The limiter

The ceiling isn't enforced by a clipper at the end, it's a property of how the gain curve is built. For each sample there's a gain that would put it exactly on the ceiling; take a sliding minimum of that over ±R samples, then smooth it with a kernel whose support is also ≤ R. Every value being averaged is a minimum over a window that contains the sample in question, so every value is ≤ what that sample needs, so the average is too. The release stage only ever pulls the gain down further. Nothing can exceed the ceiling, and there's a test that drives music-like signal 18 dB into limiting and checks it.

## Layout

`Sources/RipcordKit` is the whole engine and doesn't import SwiftUI. `Analysis/` measures, `Chain/ChainDesigner.swift` is a pure function from a measurement to a settings struct — no audio, no engine, which is what makes the decisions testable on their own — and `Chain/Masterer.swift` renders it. `Sources/Ripcord` is the app, `Sources/ripcord-cli` is the harness.

`make test` runs 45 tests. The ones I'd actually look at are the ceiling invariant, the crossover test that checks all four bands sum back flat at the crossover frequencies (they don't, without allpass compensation), and the one that re-masters the output four times over to check the corrections shrink instead of running away.

## Known rough edges

The target curve is one curve. It's a reasonable middle-of-the-road one, but a folk recording and a trap beat don't want the same thing, and right now they get the same thing at different strengths. Genre-aware targets would be the obvious next move.

It's also not notarized, so Gatekeeper will complain the first time.

MIT.
