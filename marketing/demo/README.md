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

The demo is built around making three claims concrete in plain sight:

- **Fast** — Terminal log shows `▲ Right Option @ 09:41:05.600` then
  `✓ pasted @ 09:41:05.694 (94 ms)`. The viewer can read the
  millisecond delta themselves; the gap on screen matches the real
  product's p50 benchmark.
- **Lightweight** — Terminal startup banner reads
  `parakey 0.2.1 · 2.2 MB · ~80 MB RAM`. Both numbers (download size
  and idle RAM) are in the same green as `(94 ms)`, so the eye learns
  to scan green = the claim.
- **Real keypress** — A stylised slice of the MacBook bottom row fades
  in just before the press; the rightmost Option key visibly depresses
  and glows green while held, so "Right Option" stops being a label
  and becomes a thing the viewer sees being held down.

| t (s)       | what happens                                                                  |
|------------:|-------------------------------------------------------------------------------|
| 0.0 – 0.4   | Idle. Editor blinks. Terminal shows prompt + banner + `listening…`             |
| 0.4 – 0.7   | Keyboard widget fades in at bottom centre                                      |
| 0.8         | KEY DOWN. Right Option key depresses + glows. Popover slides down. Terminal logs `▼ Right Option @ 09:41:00.800` |
| 1.1 – 5.6   | Recording. "● Listening" + "⌥ Right Option held" + live audio meter           |
| 5.6         | KEY UP. Right Option releases. Terminal logs `▲ Right Option @ 09:41:05.600`. Meter freezes, then quiets |
| 5.694       | PASTE — 94 ms after release. Text snaps into editor. Terminal logs `✓ pasted @ 09:41:05.694 (94 ms)` |
| 5.7 – 6.15  | Popover fades out, menubar icon returns to idle                               |
| 6.0 – 6.5   | Keyboard widget fades out                                                     |
| 6.5 – 9.7   | Settled. Editor + Terminal both fully readable                                |
| 9.7 – 10.3  | End caption fades in ("Local on-device dictation. No cloud transcription.")    |
| 10.3 – 14.0 | Hold final frame                                                              |

The displayed timestamps are derived from the same `t` values that
drive the on-screen animation, so what the viewer sees in the editor
matches what the terminal log claims, to the millisecond.

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
