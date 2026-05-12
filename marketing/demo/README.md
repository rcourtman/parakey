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

| t (s)      | what happens                                                  |
|-----------:|---------------------------------------------------------------|
| 0.0 – 1.2  | Idle: TextEdit window, blinking cursor, menubar at rest       |
| 1.2 – 1.6  | Parakey menubar icon activates; popover slides down           |
| 1.6 – 6.6  | "Listening" with audio meter (5 s of recording)               |
| 6.6 – 7.0  | "Transcribing"; meter collapses to a quiet pulse              |
| 7.0 – 7.22 | Pasted text snaps into the document at the cursor             |
| 7.5 – 7.95 | Popover fades out, menubar icon returns to idle               |
| 10.4 – 11  | End caption fades in ("Local on-device dictation…")           |
| 11  – 14   | Hold final frame                                              |

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
