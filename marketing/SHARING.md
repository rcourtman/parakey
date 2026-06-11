# Sharing kit

The distribution stance for Parakey: **one Show HN post, written as
engineering notes, posted once — then answer-driven replies only.**
No recurring promotion, no broadcast posts. The information "a good
free tool exists" should travel in postures that aren't marketing:
a note where engineers look up notes, and answers where people are
already asking.

Every number below comes from `docs/site-metadata.json` and the
benchmarks page — run `python3 scripts/sync-docs.py --check` before
posting so claims match the current release.

## Assets

| Asset | Where | Use |
|---|---|---|
| Demo video (MP4) | `marketing/demo/dist/parakey-demo.mp4` | most platforms |
| Demo video (WebM) | `marketing/demo/dist/parakey-demo.webm` | web `<video>` embeds |
| Demo GIF | `marketing/demo/dist/parakey-demo.gif` | platforms without video upload |
| Animated workflow SVG | `icon/demo.svg` (embedded in README + site) | GitHub-native surfaces |
| Social card (1280×640) | `icon/social-preview.png` | link previews |

Links:

- Repo: <https://github.com/rcourtman/parakey>
- Site: <https://rcourtman.github.io/parakey/>
- Benchmarks: <https://rcourtman.github.io/parakey/benchmarks.html>
- Install: `brew install --cask rcourtman/parakey/parakey`

## Claims and where they're backed

- **~100 ms from key release to pasted text** — benchmarks page, methodology included
- **2.5 MB signed, notarised download** — release asset size; one-time ~600 MB local model
- **~80 MB RAM while idle, 0% CPU between dictations** — site stats
- **100% local** — no cloud transcription, no telemetry, no account; privacy page documents the full three-call network surface
- **Free, MIT, native Swift menu-bar app**
- State the requirements up front (Apple Silicon, macOS 14+, Homebrew) — it costs a sentence and buys trust.

## Show HN (post once)

> **Show HN: Parakey – Local push-to-talk dictation for Apple Silicon (~100 ms)**

Parakey is a macOS menu-bar app: hold Right Option, speak, release,
and the transcript pastes at the cursor about 100 ms later.

I built it because I wanted dictation that feels like a keyboard
shortcut rather than a mode you enter and leave.

How it works: audio is captured in memory and decoded once on key
release with NVIDIA's Parakeet TDT v3, through FluidAudio/CoreML on
the Apple Neural Engine, then pasted at the cursor. The single-pass
decode — rather than streaming — is where the latency comes from.
Benchmarks and methodology:
https://rcourtman.github.io/parakey/benchmarks.html

Numbers: ~100 ms key-release-to-paste; 2.5 MB notarised app plus a
one-time ~600 MB model download; ~80 MB RAM idle; 0% CPU between
dictations. Transcription makes no network calls, and the full
network surface (model download, optional update check) is
documented on the privacy page.

Limitations: Apple Silicon and macOS 14+ only; install is
Homebrew-only; 18 Latin/Cyrillic-script languages via Parakeet v3;
no streaming mode.

MIT licensed. Install: `brew install --cask rcourtman/parakey/parakey`

**Posting notes.** Post from a personal account (pseudonymous is
fine; being the author is required for Show HN). Weekday mornings US
Eastern get the most eyes. Stay in the thread for the first few
hours and answer technical questions plainly. Expectation-setting:
most Show HNs get a handful of points and sink — that's a fine
outcome; the note persists, gets indexed, and keeps answering
searches for years.

## Answer material (ongoing, demand-driven)

For threads asking "is there a local dictation app for Mac?" or
similar. Reply, disclose, stop. Pick the variant that matches the
question:

General:

> I maintain a free MIT-licensed one: Parakey
> (https://github.com/rcourtman/parakey). Hold a key, speak, release —
> pastes at the cursor in ~100 ms, fully on-device (Parakeet v3 on the
> Apple Neural Engine). Apple Silicon + macOS 14+ only.

Local-AI angle (r/LocalLLaMA and similar):

> If you want local ASR as a daily input method: Parakey runs Parakeet
> TDT v3 on the ANE via CoreML — no API keys, ~100 ms from key release
> to pasted text. Benchmarks + methodology:
> https://rcourtman.github.io/parakey/benchmarks.html. I'm the
> maintainer; MIT licensed.

Privacy angle:

> Parakey transcribes entirely on-device and documents its full
> network surface (model download + optional update check, nothing
> else): https://rcourtman.github.io/parakey/privacy.html. I maintain
> it; it's free and MIT.

Comparison ("how is this different from Superwhisper / Wispr Flow /
VoiceInk?"):

> Mostly scope. Parakey only does push-to-talk dictation — verbatim,
> on-device, free — where those are fuller workspaces with AI
> formatting and more. Side-by-side facts (price, where audio is
> processed, measured latency, footprint) are here, with every
> competitor claim sourced and dated:
> https://rcourtman.github.io/parakey/compare/. I maintain Parakey,
> so read it with that in mind.

## One-liner boilerplate

For directories and "what is this" replies:

> Parakey is a free, MIT-licensed menu-bar app for Apple Silicon Macs:
> hold a key, speak, release, and the transcript pastes at the cursor
> in about 100 ms — fully on-device, no cloud, no telemetry.

## House rules

- One account, your own (pseudonymous is fine). Always disclose
  "I maintain it" / "I built this".
- Answer questions that were actually asked; don't seed them.
- The compare section answers "why not Superwhisper / Wispr Flow /
  VoiceInk / Apple Dictation / MacWhisper" — link the table or the
  per-tool page instead of arguing in threads.
- Expect "why Homebrew only?" and "Intel support?" — both are honest
  scope decisions: notarised cask keeps install + updates simple, and
  the latency story depends on the ANE.
- No second launch post. If the Show HN sinks, let it sink.
