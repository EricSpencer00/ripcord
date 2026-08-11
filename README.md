# Ripcord

Drop a track on it, get a mastered WAV back. Everything happens on your Mac — there's no account, no upload, and no network code in the app at all.

<img width="898" height="527" alt="Screenshot 2026-08-10 at 9 01 19 PM" src="https://github.com/user-attachments/assets/d8c4883d-21f6-4f0f-834d-554fc30a5145" />

## Install

Grab the `.app` from [Releases](https://github.com/EricSpencer00/ripcord/releases), or build it:

```bash
make app && open build/Ripcord.app
```

It's a universal binary, macOS 14+, no dependencies — the whole thing is Swift and Accelerate. The `.app` is about 2 MB. Since it's signed ad-hoc rather than notarized, the first launch needs a right-click → Open.

There's a CLI too:

```bash
make cli
.build/release/ripcord-cli track.wav --intensity loud
.build/release/ripcord-cli track.wav --analyze     # just measure, write nothing
```
MIT.
