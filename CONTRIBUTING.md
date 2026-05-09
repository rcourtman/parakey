# Contributing

Thanks for considering a contribution to Parakey. The project is a small
single-file Python script plus a thin macOS app bundle, and the goal is
to keep it that way.

## Reporting bugs

Open an issue with:

- macOS version (`sw_vers`)
- Mac model (M1/M2/M3/M4 etc.)
- The output of `pgrep -fl parakey.py` and the last 30 lines of
  `~/parakey/parakey.log`
- Whether the tink and pop sounds play at the expected moments
- Whether all three privacy permissions (Microphone, Accessibility,
  Input Monitoring) are granted to **Parakey.app** specifically (not
  `Terminal` or anything else)

## Suggesting features

Open an issue. Roughly in scope: hotkey behaviour, transcription
quality / latency, menu bar UX, install/upgrade ergonomics. Roughly
out of scope:

- Cloud transcription backends — the project is local-only by design.
- Cross-platform (Windows / Linux) — the integration is heavily macOS-
  specific (NSPasteboard, NSAppleScript, Quartz event taps, MLX).
- Heavy GUIs / preferences windows — the menu bar is the UI.

## Development setup

```sh
git clone https://github.com/rcourtman/parakey.git
cd parakey
./install.sh
```

After editing `parakey.py`:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.parakey
tail -f parakey.log
```

After editing anything inside `templates/` or the bundle, re-run
`./install.sh` to pick up the change and re-sign.

## Pull requests

- Keep the diff focused on one change.
- No new dependencies unless they replace something heavier or unlock a
  meaningful feature.
- Match the existing style: terse, type-hinted, comments only when the
  *why* is non-obvious.
- Run `python -m py_compile parakey.py bench.py install.sh` and
  `bash -n install.sh`. (CI runs these too.)
- If you change anything performance-sensitive, include before/after
  numbers from `bench.py`.

## Code structure

- `parakey.py` — the menu bar app. One file, one class. State is kept
  on the `Parakey(rumps.App)` instance.
- `bench.py` — profiling script. Compares the path-based pipeline
  against the direct numpy → mlx pipeline.
- `install.sh` — idempotent installer that builds the app bundle from
  `templates/`, generates the LaunchAgent plist, and signs.
- `templates/` — portable `Parakey.app` skeleton and LaunchAgent plist
  template. The launcher uses `$HOME` so it works on any Mac. The plist
  uses `__HOME__` substituted at install time.
