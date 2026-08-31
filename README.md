# Ripcord

Drop a track on it, get a mastered WAV back. Everything happens on your Mac — there's no account, no upload, and no network code in the app at all.

<img width="898" height="527" alt="Screenshot 2026-08-10 at 9 01 19 PM" src="https://github.com/user-attachments/assets/d8c4883d-21f6-4f0f-834d-554fc30a5145" />

There's a [landing page](https://ericspencer00.github.io/ripcord/) with a before/after clip you can A/B.

## Install

Grab the `.dmg` from [Releases](https://github.com/EricSpencer00/ripcord/releases). It's signed with a Developer ID and notarized, so it opens with a double click. Or build it:

```bash
make app && open build/Ripcord.app
```

It's a universal binary, macOS 14+, no dependencies — the whole thing is Swift and Accelerate. The `.app` is about 2 MB. A build you make yourself is signed ad-hoc, so its first launch needs a right-click → Open.

To cut a release image yourself, set a signing identity and notary credentials:

```bash
export SIGN="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=ripcord        # or APPLE_ID, TEAM_ID and APPLE_PASSWORD
make dmg
```

Without `SIGN`, `make dmg` still builds an image, but it's ad-hoc signed and Gatekeeper refuses it.

There's a CLI too:

```bash
make cli
.build/release/ripcord-cli track.wav --intensity loud
.build/release/ripcord-cli track.wav --analyze     # just measure, write nothing
.build/release/ripcord-cli track.wav --delivery apple
```

## Delivery checks

Pick a delivery target and the finished master gets checked against a published set of technical
requirements, with the limit, the measurement and the verdict printed as rows. Every figure is
measured on the rendered audio.

The Apple target follows the *Apple Digital Masters* technology brief (April 2021): a 24-bit source
kept at its native sample rate with no conversion, and at least 1 dB of headroom. It also encodes
the master to 256 kbps AAC, decodes it back, and counts any samples that come back over full scale
— the overs that a PCM meter cannot see. If the encode clips, the ceiling comes down and the level
pass runs again.

Two things it does not do. It does not set a loudness target, because Apple does not publish one.
And it prints no badge: passing these checks is not the same as being admitted to Apple's
programme, which only Apple can do.

The CLI exits non-zero when a check is not met, so a release script can gate on it.

Immersive formats are out of scope. Dolby Atmos is authored as objects with positional metadata and
delivered as an ADM BWF; a stereo tool has no basis for producing one, and Ripcord does not try.

The clip on the landing page is synthesized by `Tools/makedemo.swift` and mastered by the CLI, so
the site carries no third-party audio. `make demo` regenerates both files, and `make og` renders
the link preview card a posted link shows.

MIT.
