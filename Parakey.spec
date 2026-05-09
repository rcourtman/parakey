# PyInstaller spec for Parakey.
#
# Build:    .venv/bin/pyinstaller --noconfirm Parakey.spec
# Result:   dist/Parakey.app  (self-contained — Python + every dep
#           lives inside the bundle, so the running executable is
#           Parakey, not Homebrew Python)
#
# After building, sign with Developer ID and notarise via
# scripts/release.sh (added separately).

# noqa: F821 — Analysis, EXE, etc. are injected by PyInstaller.

from PyInstaller.utils.hooks import collect_all

block_cipher = None

# mlx and parakeet_mlx have dynamic Python imports + native library
# loading + Metal shader archives. collect_all() gathers the lot
# (datas, binaries, hiddenimports) so we don't have to enumerate each
# submodule manually.
mlx_datas, mlx_binaries, mlx_hidden = collect_all("mlx")
pmlx_datas, pmlx_binaries, pmlx_hidden = collect_all("parakeet_mlx")

a = Analysis(
    ["parakey.py"],
    pathex=[],
    binaries=mlx_binaries + pmlx_binaries,
    datas=[
        ("icon/Parakey.icns", "icon"),
        ("icon/parakey-menubar.png", "icon"),
        ("icon/parakey-menubar@2x.png", "icon"),
    ] + mlx_datas + pmlx_datas,
    hiddenimports=[
        # Audio I/O
        "sounddevice",
        "soundfile",
        # Hotkey + macOS bindings
        "pynput",
        "pynput.keyboard",
        "Quartz",
        "AppKit",
        "Foundation",
        "Cocoa",
        "objc",
        # Used by the onboarding wizard to trigger TCC permission
        # registration before opening the Privacy panes.
        "AVFoundation",
        "ApplicationServices",
        # Menu bar UI
        "rumps",
    ] + mlx_hidden + pmlx_hidden,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Tk pulls in its own UI runtime; we don't use it.
        "tkinter",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Parakey",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch="arm64",
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name="Parakey",
)

app = BUNDLE(
    coll,
    name="Parakey.app",
    icon="icon/Parakey.icns",
    bundle_identifier="com.local.parakey",
    info_plist={
        "CFBundleName": "Parakey",
        "CFBundleDisplayName": "Parakey",
        "CFBundleShortVersionString": "0.1",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription":
            "Parakey records audio while you hold the dictation hotkey, "
            "then transcribes it locally on your Mac.",
        "NSAppleEventsUsageDescription":
            "Parakey uses System Events to paste transcribed text at your cursor.",
    },
)
