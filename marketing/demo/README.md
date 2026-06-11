# Parakey demo video

Synthetic Mac interaction demo for sharing the Parakey workflow without
screen-recording the real app. The animation is described declaratively
in `index.html` (a single deterministic timeline driven by
`window.renderAt(t)`); `render.mjs` walks that timeline frame-by-frame
through headless Chrome and hands the PNG sequence to ffmpeg.

Output: `dist/parakey-demo.mp4` (also `.webm`, `.gif`).

## Render

Prerequisites: macOS, Node 20+, Google Chrome installed at
`/Applications/Google Chrome.app`, and ffmpeg at `/opt/homebrew/bin/ffmpeg`.

```
cd marketing/demo
npm install
node render.mjs
```

The script:

1. Launches headless Chrome (no separate Chromium download — uses the
   system Chrome via `puppeteer-core`).
2. Opens `index.html` and waits for `window.demoReady`.
3. For each of the 420 frames (30 fps × 14 s), calls
   `window.renderAt(t)` to set deterministic state and screenshots the
   1920×1080 viewport into `frames/`.
4. Encodes the frame sequence to
   - `dist/parakey-demo.mp4`  (H.264, yuv420p, CRF 18, +faststart)
   - `dist/parakey-demo.webm` (VP9, CRF 32)
   - `dist/parakey-demo.gif`  (1080 px wide, 20 fps, palette-quantised)

Total wall-time on an M-series Mac: ≈ 1 minute.

## Timeline

The demo is built around one rule: **the viewer's eye stays in a
single vertical column** — editor in the middle, one HUD chip directly
below it, caption underneath at the end. No popovers in the corner, no
side terminal, no keyboard widget to hunt for. Sequential, not
parallel.

The chip carries everything the previous version scattered:

- The **Option keycap** (left of the chip) — depresses + glows green
  while the hotkey is held.
- The **waveform** (centre) — animates while listening, freezes the
  instant the key releases.
- The **status + counter** (right) — reads `Hold Right Option` before
  the press, then `Listening 2.3s` (live counter) during recording,
  then `✓ pasted in 94 ms` after the key releases.

The lightweight claim lives in the caption subtitle at the end — not
in a fake CLI banner. All three numbers (download / RAM / end-to-end
latency) sit on one line in brand green, so the proof shows up where
captions belong instead of pretending to be terminal output.

| t (s)       | what happens                                                                  |
|------------:|-------------------------------------------------------------------------------|
| 0.0 – 0.5   | Idle establishing shot. Editor with blinking cursor.                          |
| 0.5 – 0.8   | HUD chip slides up + fades in below the editor. Reads `Hold Right Option`.    |
| 1.0         | KEY DOWN. ⌥ keycap depresses + glows green. Label becomes `Listening`.        |
| 1.0 – 6.0   | Live audio meter. Counter ticks `0.0s → 5.0s` in the chip.                    |
| 6.0         | KEY UP. Waveform freezes.                                                     |
| 6.094       | PASTE — 94 ms after release. Text snaps into editor. Chip flips to a green `✓ pasted in 94 ms`. |
| 6.1 – 8.0   | Result holds. Editor full, chip showing the speed claim.                      |
| 8.0 – 8.6   | Chip fades out.                                                               |
| 9.7 – 10.4  | Caption fades in: `Local on-device dictation. No cloud transcription.` plus the subtitle `2.2 MB download · ~80 MB RAM idle · ~94 ms end-to-end`. |
| 10.4 – 14.0 | Hold final frame.                                                              |

The 94 ms gap, the live counter, and the timing of the text reveal are
all derived from the same `t` values, so what the viewer reads on the
chip matches what they just saw happen, to the millisecond.

## Editing

All visuals are HTML/CSS/SVG in `index.html`. The render is fully
deterministic — `renderAt(t)` computes every animated value from `t`,
so two runs produce byte-identical frames. To iterate quickly, open
`index.html` in a regular browser and call `renderAt(seconds)` in the
console.

## Output paths

- `marketing/demo/dist/parakey-demo.mp4` — for Reddit and most social
- `marketing/demo/dist/parakey-demo.webm` — for `<video>` embeds
- `marketing/demo/dist/parakey-demo.gif`  — for places that disallow video

The docs site embeds copies as `docs/demo-video.{mp4,webm}` plus
`docs/demo-poster.jpg` for the mobile breakpoint — re-copy them after
re-rendering.
