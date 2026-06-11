# Sharing kit

Ready-to-paste launch copy. Every number below comes from
`docs/site-metadata.json` and the benchmarks page — run
`python3 scripts/sync-docs.py --check` before posting so claims match
the current release.

## Assets

| Asset | Where | Use |
|---|---|---|
| Demo video (MP4) | `marketing/demo/dist/parakey-demo.mp4` | Reddit and most platforms |
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

## Show HN

> **Show HN: Parakey – Local push-to-talk dictation for Apple Silicon (~100 ms)**

I built Parakey because I wanted dictation that feels like a keyboard
shortcut: hold Right Option, talk, let go, and the words are at the
cursor about 100 ms later.

Everything runs on-device. Audio is captured in memory, transcribed
with NVIDIA's Parakeet TDT v3 through FluidAudio/CoreML on the Apple
Neural Engine, and pasted at the cursor — no cloud, no telemetry, no
account. The app is a 2.5 MB notarised zip (the speech model is a
one-time ~600 MB download), idles at ~80 MB RAM and 0% CPU, and is
deliberately small: one SwiftPM target, AppKit menu-bar UI, MIT
licensed.

Honest limitations: Apple Silicon and macOS 14+ only, install is via
Homebrew cask, and transcription happens on key release rather than
streaming — that single-pass decode is also why the latency is what
it is. Language support is 18 Latin/Cyrillic-script languages via
Parakeet v3.

Install: `brew install --cask rcourtman/parakey/parakey`

Happy to answer questions about the latency path or the
FluidAudio/ANE stack.

## Reddit (r/macapps, r/MacOS, r/LocalLLaMA)

> **Parakey — free, open-source push-to-talk dictation for Apple Silicon. Hold a key, speak, release; text appears at the cursor in ~100 ms.**

Attach `parakey-demo.mp4`, then:

I got tired of dictation tools that are slow, cloud-backed, or
subscription-ware, so I built a small native one and open-sourced it
(MIT).

- Hold Right Option (configurable), speak, release — the transcript
  pastes wherever your cursor is, in any app
- ~100 ms from key release to pasted text, benchmarked on the site
- 100% on-device: Parakeet TDT v3 on the Apple Neural Engine via
  CoreML — no cloud, no telemetry, no account
- 2.5 MB app, ~80 MB RAM idle, 0% CPU between dictations
- Free and open source; install via Homebrew cask

Needs Apple Silicon and macOS 14+. First launch downloads the ~600 MB
speech model once.

`brew install --cask rcourtman/parakey/parakey`

Repo: <https://github.com/rcourtman/parakey>

For r/LocalLLaMA, lead with the on-device angle instead: local ASR
with Parakeet TDT v3 on the ANE, no API keys, latency numbers and
methodology in the benchmarks page.

## X / Mastodon / Bluesky

Attach `parakey-demo.mp4`:

> Hold a key, speak, release — your words land at the cursor ~100 ms
> later.
>
> Parakey: free, open-source push-to-talk dictation for Apple Silicon.
> 100% on-device (Parakeet v3 on the Neural Engine). 2.5 MB app, no
> cloud, no subscription.
>
> https://github.com/rcourtman/parakey

## One-liner boilerplate

For directories, Discord servers, and "what is this" replies:

> Parakey is a free, MIT-licensed menu-bar app for Apple Silicon Macs:
> hold a key, speak, release, and the transcript pastes at the cursor
> in about 100 ms — fully on-device, no cloud, no telemetry.

## Posting notes

- Lead with the video. The product is the demo; the copy is a caption.
- Post as yourself and say you're the maintainer. One account, no
  astroturfing.
- When someone asks "how do I install it", the canonical assistant
  prompt lives at
  <https://rcourtman.github.io/parakey/install/agents.md> — paste-able
  into any shell-capable coding assistant.
- The compare pages answer "why not Apple Dictation / MacWhisper /
  WhisperKit" — link them instead of arguing in threads.
- Expect "why Homebrew only?" and "Intel support?" — both are honest
  scope decisions: notarised cask keeps install + updates simple, and
  the latency story depends on the ANE.
