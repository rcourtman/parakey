#!/usr/bin/env node
// Render the Parakey demo: drive marketing/demo/index.html through
// puppeteer-core (pointed at the system Chrome — no separate Chromium
// download), screenshot every frame deterministically, then encode the
// frame sequence to MP4 / WebM / GIF with ffmpeg.

import puppeteer from 'puppeteer-core';
import { spawnSync } from 'node:child_process';
import { mkdirSync, rmSync, existsSync, statSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FFMPEG = '/opt/homebrew/bin/ffmpeg';

const WIDTH       = 1920;
const HEIGHT      = 1080;
const FPS         = 30;
const DURATION_S  = 14;
const TOTAL       = FPS * DURATION_S;     // 420 frames

const FRAMES_DIR  = path.join(__dirname, 'frames');
const DIST_DIR    = path.join(__dirname, 'dist');
const HTML_PATH   = path.join(__dirname, 'index.html');

function log(...args) {
  process.stdout.write('[render] ' + args.join(' ') + '\n');
}

function run(cmd, args) {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.status !== 0) throw new Error(`${cmd} exited with ${r.status}`);
}

async function captureFrames() {
  if (existsSync(FRAMES_DIR)) rmSync(FRAMES_DIR, { recursive: true, force: true });
  mkdirSync(FRAMES_DIR, { recursive: true });
  mkdirSync(DIST_DIR, { recursive: true });

  log(`launching Chrome (${CHROME})`);
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: 'shell',
    args: [
      '--hide-scrollbars',
      '--force-device-scale-factor=1',
      '--font-render-hinting=none',
      '--disable-font-subpixel-positioning',
      `--window-size=${WIDTH},${HEIGHT}`,
    ],
    defaultViewport: { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 },
  });

  const page = await browser.newPage();
  await page.setViewport({ width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 });
  await page.goto('file://' + HTML_PATH, { waitUntil: 'load' });
  await page.waitForFunction('window.demoReady === true', { timeout: 5000 });
  // Give web fonts and SVGs a tick to settle before frame 0.
  await new Promise(r => setTimeout(r, 100));

  log(`rendering ${TOTAL} frames @ ${FPS}fps (${WIDTH}x${HEIGHT}, ${DURATION_S}s)`);
  const started = Date.now();
  for (let i = 0; i < TOTAL; i++) {
    const t = i / FPS;
    await page.evaluate(t => window.renderAt(t), t);
    const name = 'frame-' + String(i).padStart(4, '0') + '.png';
    await page.screenshot({
      path: path.join(FRAMES_DIR, name),
      type: 'png',
      clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT },
      omitBackground: false,
    });
    if (i % 60 === 0 || i === TOTAL - 1) {
      const pct = ((i + 1) / TOTAL * 100).toFixed(0);
      log(`  frame ${i + 1}/${TOTAL} (${pct}%)`);
    }
  }
  const elapsed = ((Date.now() - started) / 1000).toFixed(1);
  log(`frames done in ${elapsed}s`);
  await browser.close();
}

function encodeMp4() {
  const out = path.join(DIST_DIR, 'parakey-demo.mp4');
  log(`encoding MP4 → ${out}`);
  run(FFMPEG, [
    '-y',
    '-framerate', String(FPS),
    '-i', path.join(FRAMES_DIR, 'frame-%04d.png'),
    '-c:v', 'libx264',
    '-pix_fmt', 'yuv420p',
    '-preset', 'slow',
    '-crf', '18',
    '-profile:v', 'high',
    '-movflags', '+faststart',
    '-an',
    out,
  ]);
  return out;
}

function encodeWebm() {
  const out = path.join(DIST_DIR, 'parakey-demo.webm');
  log(`encoding WebM → ${out}`);
  run(FFMPEG, [
    '-y',
    '-framerate', String(FPS),
    '-i', path.join(FRAMES_DIR, 'frame-%04d.png'),
    '-c:v', 'libvpx-vp9',
    '-b:v', '0',
    '-crf', '32',
    '-pix_fmt', 'yuv420p',
    '-row-mt', '1',
    '-an',
    out,
  ]);
  return out;
}

function encodeGif() {
  // Two-pass palette method, downscaled to 1080px wide and 20fps so the
  // GIF stays a sensible size while remaining readable in a Reddit feed.
  const palette = path.join(FRAMES_DIR, 'palette.png');
  const out     = path.join(DIST_DIR, 'parakey-demo.gif');
  log(`encoding GIF → ${out}`);
  run(FFMPEG, [
    '-y',
    '-framerate', String(FPS),
    '-i', path.join(FRAMES_DIR, 'frame-%04d.png'),
    '-vf', 'fps=20,scale=1080:-1:flags=lanczos,palettegen=max_colors=128:stats_mode=full',
    palette,
  ]);
  run(FFMPEG, [
    '-y',
    '-framerate', String(FPS),
    '-i', path.join(FRAMES_DIR, 'frame-%04d.png'),
    '-i', palette,
    '-lavfi', 'fps=20,scale=1080:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a',
    out,
  ]);
  return out;
}

function humanSize(p) {
  const b = statSync(p).size;
  if (b > 1024 * 1024) return (b / 1024 / 1024).toFixed(2) + ' MB';
  return (b / 1024).toFixed(0) + ' KB';
}

(async () => {
  await captureFrames();
  const mp4  = encodeMp4();
  const webm = encodeWebm();
  let gif    = null;
  try { gif = encodeGif(); } catch (e) { log('gif encoding skipped:', e.message); }

  log('outputs:');
  log(`  MP4 : ${mp4}  (${humanSize(mp4)})`);
  log(`  WebM: ${webm}  (${humanSize(webm)})`);
  if (gif) log(`  GIF : ${gif}  (${humanSize(gif)})`);

  // Print a manifest of frames so callers can sanity-check.
  const frameCount = readdirSync(FRAMES_DIR).filter(n => n.startsWith('frame-')).length;
  log(`captured frames: ${frameCount}`);
})().catch(err => {
  console.error('[render] failed:', err);
  process.exit(1);
});
