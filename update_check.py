"""
update_check.py — pure helpers for the in-app update notifier.

Anything that touches AppKit / NSBundle / the running app stays in
parakey.py (``is_brew_install``, ``current_bundle_version``). Everything
in this module is plain-stdlib Python so it imports cleanly on Linux
CI runners and is unit-testable without mocking out MLX.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request


# Public release endpoint. Anonymous GET — no auth header, no
# identifier, no user-agent fingerprint beyond Python's default. The
# release JSON is small (~5 KB).
GITHUB_LATEST_RELEASE_URL = (
    "https://api.github.com/repos/rcourtman/parakey/releases/latest"
)
# Fallback page for non-brew installs or brew failures.
GITHUB_RELEASES_PAGE = "https://github.com/rcourtman/parakey/releases/latest"

UPDATE_CHECK_FIRST_DELAY_SECONDS = 30          # let the app finish loading first
UPDATE_CHECK_INTERVAL_SECONDS = 6 * 3600       # 6 hours between checks
UPDATE_CHECK_HTTP_TIMEOUT_SECONDS = 10         # don't hang on flaky networks


def parse_semver(s: str) -> tuple[int, ...]:
    """``'0.1.2'`` or ``'v0.1.2'`` → ``(0, 1, 2)``.

    Tolerant by design:
      * Strips a single ``v`` or ``V`` prefix (so the GitHub tag format
        compares cleanly against ``CFBundleShortVersionString``).
      * Stops at the first non-digit *within* a chunk, which means
        prerelease suffixes like ``0.1.2-rc1`` parse to ``(0, 1, 2)``.
      * Bails on an unparseable chunk, returning what it has so far.
      * Returns ``()`` for empty / None-like inputs. Comparisons against
        ``()`` are always "older than anything", which is the safe
        default for "we couldn't read our own version, so any release
        looks newer."
    """
    if not s:
        return ()
    s = s.strip().lstrip("vV")
    out: list[int] = []
    for chunk in s.split("."):
        digits = ""
        for ch in chunk:
            if ch.isdigit():
                digits += ch
            else:
                break
        if not digits:
            break
        out.append(int(digits))
    return tuple(out)


def find_brew() -> "str | None":
    """Locate the Homebrew binary on disk.

    macOS GUI apps inherit no shell PATH at launch, so we can't rely on
    ``brew`` being in ``$PATH``. The two canonical install locations
    are checked in order — Apple Silicon's ``/opt/homebrew/bin/brew``
    first because that's the only place we can be running anyway
    (Parakey is Apple-Silicon-only).
    """
    for path in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def fetch_latest_release_tag(
    url: str = GITHUB_LATEST_RELEASE_URL,
    timeout: float = UPDATE_CHECK_HTTP_TIMEOUT_SECONDS,
) -> "str | None":
    """Single GET against the GitHub Releases ``/latest`` endpoint.

    Returns the tag (``'v0.1.3'``) on success, ``None`` on any failure —
    network errors, JSON parse failures, missing ``tag_name``, anything.
    The caller is expected to silently retry on the next interval; no
    error UI is appropriate for what's effectively a heartbeat.
    """
    try:
        req = urllib.request.Request(
            url, headers={"Accept": "application/vnd.github+json"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        tag = data.get("tag_name")
        return str(tag) if tag else None
    except (urllib.error.URLError, OSError, ValueError):
        return None
