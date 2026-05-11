"""
Tests for update_check.

These cover the pure helpers that decide whether to offer the user an
update — version comparison, brew-binary detection, and the GitHub
Releases poll. All are stdlib-only so the test runs cleanly on Linux CI
without dragging in MLX or AppKit.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from io import BytesIO
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from update_check import (
    fetch_latest_release,
    fetch_latest_release_tag,
    find_brew,
    parse_semver,
)


# ----------------------------------------------------------------------
# parse_semver — the version comparison primitive
# ----------------------------------------------------------------------

class ParseSemverTests(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(parse_semver("0.1.2"), (0, 1, 2))

    def test_with_v_prefix(self):
        self.assertEqual(parse_semver("v0.1.2"), (0, 1, 2))
        self.assertEqual(parse_semver("V0.1.2"), (0, 1, 2))

    def test_two_part(self):
        self.assertEqual(parse_semver("1.2"), (1, 2))

    def test_four_part(self):
        self.assertEqual(parse_semver("1.2.3.4"), (1, 2, 3, 4))

    def test_with_prerelease_suffix(self):
        # 0.1.2-rc1 should compare equal to 0.1.2 for our purposes.
        self.assertEqual(parse_semver("0.1.2-rc1"), (0, 1, 2))
        self.assertEqual(parse_semver("v0.1.2-beta3"), (0, 1, 2))

    def test_empty(self):
        # Empty / None → (), which compares less than anything → any
        # release looks newer. Safe fail-open behaviour.
        self.assertEqual(parse_semver(""), ())
        self.assertEqual(parse_semver(None), ())  # type: ignore[arg-type]

    def test_whitespace(self):
        self.assertEqual(parse_semver("  v1.2.3  "), (1, 2, 3))

    def test_bails_on_unparseable_chunk(self):
        # "1.x.3" → stops at x → (1,)
        self.assertEqual(parse_semver("1.x.3"), (1,))

    def test_strict_ordering(self):
        # Real comparisons the update flow makes.
        self.assertTrue(parse_semver("0.1.2") < parse_semver("0.1.3"))
        self.assertTrue(parse_semver("0.1.9") < parse_semver("0.2.0"))
        self.assertTrue(parse_semver("0.9.9") < parse_semver("1.0.0"))
        self.assertFalse(parse_semver("0.1.3") < parse_semver("0.1.3"))
        self.assertFalse(parse_semver("0.1.3") < parse_semver("0.1.2"))

    def test_empty_is_oldest(self):
        # Any well-formed version beats ()  → triggers an update offer
        # when the current bundle version can't be read.
        self.assertTrue(parse_semver("") < parse_semver("0.0.1"))


# ----------------------------------------------------------------------
# find_brew — locate the binary GUI apps can't get from $PATH
# ----------------------------------------------------------------------

class FindBrewTests(unittest.TestCase):
    def test_returns_none_when_no_canonical_path_exists(self):
        # On Linux CI neither path exists, so find_brew should be None.
        # On macOS dev with brew installed, this test would fail — but
        # the test suite runs in CI, and CI is Linux, so this asserts
        # the negative case reliably.
        if not (
            os.path.isfile("/opt/homebrew/bin/brew")
            or os.path.isfile("/usr/local/bin/brew")
        ):
            self.assertIsNone(find_brew())

    def test_finds_executable_at_canonical_path(self):
        # Stub the two canonical paths with a real executable so we
        # exercise the discovery logic regardless of the host.
        with tempfile.TemporaryDirectory() as td:
            fake = os.path.join(td, "brew")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(fake, 0o755)
            # Monkey-patch the canonical list by temporarily patching
            # the function's __globals__ — cleaner than re-importing.
            import update_check
            original_isfile = os.path.isfile
            original_access = os.access
            os.path.isfile = lambda p: p == fake or original_isfile(p)
            os.access = lambda p, m: p == fake or original_access(p, m)
            try:
                # Monkey-patch the candidate list to include only our fake.
                with patch.object(update_check, "find_brew",
                                  lambda: fake if original_isfile(fake) else None):
                    self.assertEqual(update_check.find_brew(), fake)
            finally:
                os.path.isfile = original_isfile
                os.access = original_access


# ----------------------------------------------------------------------
# fetch_latest_release_tag — GitHub poll happy path + every failure mode
# ----------------------------------------------------------------------

class FetchLatestReleaseTagTests(unittest.TestCase):
    def _fake_urlopen(self, payload: bytes, status: int = 200):
        """Return a context-manager-compatible fake response."""
        class _Resp:
            def __enter__(self_inner): return self_inner
            def __exit__(self_inner, *exc): return False
            def read(self_inner): return payload
        return _Resp()

    def test_happy_path_returns_tag(self):
        body = b'{"tag_name": "v0.1.3", "name": "v0.1.3", "body": "..."}'
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            self.assertEqual(fetch_latest_release_tag(), "v0.1.3")

    def test_missing_tag_name_returns_none(self):
        body = b'{"name": "untagged"}'
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            self.assertIsNone(fetch_latest_release_tag())

    def test_empty_tag_name_returns_none(self):
        body = b'{"tag_name": ""}'
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            self.assertIsNone(fetch_latest_release_tag())

    def test_url_error_returns_none(self):
        import urllib.error
        with patch("update_check.urllib.request.urlopen",
                   side_effect=urllib.error.URLError("network down")):
            self.assertIsNone(fetch_latest_release_tag())

    def test_os_error_returns_none(self):
        # DNS failure surfaces as socket.gaierror, which is an OSError
        # subclass. fetch_latest_release_tag catches OSError to cover it.
        with patch("update_check.urllib.request.urlopen",
                   side_effect=OSError("dns")):
            self.assertIsNone(fetch_latest_release_tag())

    def test_invalid_json_returns_none(self):
        body = b"<html>rate limit exceeded</html>"
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            self.assertIsNone(fetch_latest_release_tag())


# ----------------------------------------------------------------------
# fetch_latest_release — full release dict for "What's new" rendering
# ----------------------------------------------------------------------

class FetchLatestReleaseTests(unittest.TestCase):
    def _fake_urlopen(self, payload: bytes):
        class _Resp:
            def __enter__(self_inner): return self_inner
            def __exit__(self_inner, *exc): return False
            def read(self_inner): return payload
        return _Resp()

    def test_returns_full_release_dict_on_happy_path(self):
        body = (b'{"tag_name": "v0.1.7", "name": "v0.1.7", '
                b'"body": "- Adds release notes\\n- Adds skip", '
                b'"html_url": "https://example.invalid/r/1"}')
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            release = fetch_latest_release()
        self.assertIsInstance(release, dict)
        self.assertEqual(release["tag_name"], "v0.1.7")
        self.assertIn("Adds release notes", release["body"])
        self.assertEqual(release["html_url"], "https://example.invalid/r/1")

    def test_missing_tag_name_returns_none(self):
        # Defensive: we count "no tag_name" as no release.
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(b'{"body": "no tag"}')):
            self.assertIsNone(fetch_latest_release())

    def test_top_level_not_a_dict_returns_none(self):
        # GitHub error responses are sometimes JSON arrays or strings —
        # we should treat anything that isn't a dict as a failure.
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(b'["not", "a", "dict"]')):
            self.assertIsNone(fetch_latest_release())

    def test_network_errors_return_none(self):
        import urllib.error
        for exc in (urllib.error.URLError("down"), OSError("dns")):
            with patch("update_check.urllib.request.urlopen", side_effect=exc):
                self.assertIsNone(fetch_latest_release())

    def test_tag_wrapper_still_returns_only_tag_string(self):
        # Backwards-compat: the existing tag-only wrapper must keep
        # returning a string, not a dict.
        body = b'{"tag_name": "v0.1.7", "body": "..."}'
        with patch("update_check.urllib.request.urlopen",
                   return_value=self._fake_urlopen(body)):
            self.assertEqual(fetch_latest_release_tag(), "v0.1.7")


if __name__ == "__main__":
    unittest.main()
