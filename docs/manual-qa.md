# Manual QA Checklist

Run this before publishing a release.

## Signed App Smoke

```sh
cd swift
./dev-run.sh
```

- Confirm `/tmp/Parakey-dev.app` launches and the menu-bar item appears.
- Open **Support -> Setup Checklist...** and confirm model, permissions,
  audio input, and hotkey rows render.
- Confirm **Support -> Copy Diagnostics** copies a report with no
  transcript text or text-correction contents.
- Confirm **Support -> Save Diagnostics...** writes the same privacy-safe
  report.

## Hotkeys

- In **Settings -> Hotkey**, choose **Right Option** and dictate once.
- Record an F-key such as F7 with **Record Hotkey...**, then dictate once.
- Record a right-side modifier such as **Right Control**, then dictate once.
- Try recording a normal letter key and confirm it is rejected.
- Use **Reset Hotkey to Default** and confirm the menu returns to
  **Right Option**.
- Cancel the hotkey recorder and confirm the existing hotkey still works.

## Dictation

- Test hold mode: hold the hotkey, speak, release, and confirm text pastes
  at the cursor.
- Test toggle mode: press once to start, press again to stop.
- Press Escape during an active recording and confirm it cancels without
  pasting.
- Confirm the recording waveform appears when enabled.
- Confirm **Mute system audio while recording** still unmutes after release
  and cancel.

## Permissions And TCC

- On a clean or reset machine, launch Parakey and use **Setup Checklist...**
  to request Microphone, Accessibility, and Input Monitoring.
- Confirm each granted permission removes or updates its setup row after the
  app is reopened if macOS requires it.
- Confirm the app handles a missing permission by staying not-ready instead
  of recording.

## Updates

- Use **Support -> Check for Updates...** on a current build and confirm it
  reports no pending update.
- If testing from a brew install with an older release available, confirm
  the update item starts the Homebrew helper and writes an update log.

## Benchmark Helpers

```sh
cd experiments/swift-bench
./run-real-dictation-regression.sh --self-test
./bench-power.sh --self-test
sudo -v
./bench-power.sh --file test-audio/short-clean.wav --backend v3 --trials 1 --out-dir /tmp/parakey-power-results
```

The real `bench-power.sh` run requires interactive sudo because
`powermetrics` requires it.
