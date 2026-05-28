#!/usr/bin/env python3
"""Regenerate Parakey's pinned speech-model SHA-256 manifest.

The v3 Parakeet CoreML repository contains a mix of LFS-backed files
and small Git blobs. Hugging Face exposes SHA-256 directly for the LFS
objects via X-Linked-ETag; small Git blobs expose only Git object IDs,
so this script downloads those small files and hashes the bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "swift" / "Sources" / "Parakey" / "main.swift"

DEFAULT_REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
DEFAULT_REVISION = "aed02740059203c4a87495924f685de3722ae9ce"
DEFAULT_BUNDLES = [
    "Decoder.mlmodelc",
    "Encoder.mlmodelc",
    "JointDecisionv3.mlmodelc",
    "Preprocessor.mlmodelc",
]
DEFAULT_EXTRA_FILES = ["parakeet_vocab.json"]

BEGIN_MARKER = "// BEGIN GENERATED PARAKEET_V3_MODEL_MANIFEST"
END_MARKER = "// END GENERATED PARAKEET_V3_MODEL_MANIFEST"
HEX64 = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)
SWIFT_REPO_RE = re.compile(r'(static let parakeetV3Repository = ")([^"]+)(")')
SWIFT_REVISION_RE = re.compile(r'(static let parakeetV3RepositoryCommit = ")([^"]+)(")')


class ManifestError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirect)


def urlopen_json(url: str) -> object:
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def quoted_repo(repo: str) -> str:
    return urllib.parse.quote(repo, safe="/")


def quoted_path(path: str) -> str:
    return urllib.parse.quote(path, safe="/")


def tree_url(repo: str, revision: str) -> str:
    return f"https://huggingface.co/api/models/{quoted_repo(repo)}/tree/{revision}?recursive=true"


def resolve_url(repo: str, revision: str, path: str) -> str:
    return f"https://huggingface.co/{quoted_repo(repo)}/resolve/{revision}/{quoted_path(path)}"


def listed_model_files(repo: str, revision: str, bundles: list[str], extra_files: list[str]) -> list[str]:
    tree = urlopen_json(tree_url(repo, revision))
    if not isinstance(tree, list):
        raise ManifestError("unexpected Hugging Face tree response")

    bundle_prefixes = tuple(f"{bundle}/" for bundle in bundles)
    wanted = []
    for item in tree:
        if not isinstance(item, dict) or item.get("type") != "file":
            continue
        path = item.get("path")
        if not isinstance(path, str):
            continue
        if path.startswith(bundle_prefixes) or path in extra_files:
            wanted.append(path)

    bundle_order = {name: index for index, name in enumerate(bundles)}

    def sort_key(path: str) -> tuple[int, str]:
        bundle = path.split("/", 1)[0]
        return (bundle_order.get(bundle, len(bundle_order)), path)

    return sorted(wanted, key=sort_key)


def linked_etag(repo: str, revision: str, path: str) -> str | None:
    request = urllib.request.Request(resolve_url(repo, revision, path), method="HEAD")
    try:
        with NO_REDIRECT_OPENER.open(request, timeout=30) as response:
            etag = response.headers.get("X-Linked-ETag")
    except urllib.error.HTTPError as error:
        if error.code not in {301, 302, 303, 307, 308}:
            raise
        etag = error.headers.get("X-Linked-ETag")

    if not etag:
        return None
    etag = etag.strip().strip('"')
    return etag.lower() if HEX64.fullmatch(etag) else None


def downloaded_sha256(repo: str, revision: str, path: str) -> str:
    h = hashlib.sha256()
    with urllib.request.urlopen(resolve_url(repo, revision, path), timeout=120) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def digest_for_path(repo: str, revision: str, path: str) -> str:
    return linked_etag(repo, revision, path) or downloaded_sha256(repo, revision, path)


def render_manifest(paths: list[str], digests: dict[str, str]) -> str:
    lines = []
    for path in paths:
        lines.append(
            f'        ModelFileDigest(relativePath: "{path}", sha256: "{digests[path]}"),'
        )
    return "\n".join(lines)


def replace_generated_block(source: str, manifest: str) -> str:
    begin = source.find(BEGIN_MARKER)
    end = source.find(END_MARKER)
    if begin == -1 or end == -1 or end < begin:
        raise ManifestError(f"could not find generated manifest markers in {SOURCE}")

    line_start = source.rfind("\n", 0, begin) + 1
    marker_indent = source[line_start:begin]
    replacement = (
        f"{BEGIN_MARKER}\n"
        f"{manifest}\n"
        f"{marker_indent}{END_MARKER}"
    )
    return source[:begin] + replacement + source[end + len(END_MARKER):]


def current_generated_block(source: str) -> str:
    begin = source.find(BEGIN_MARKER)
    end = source.find(END_MARKER)
    if begin == -1 or end == -1 or end < begin:
        raise ManifestError(f"could not find generated manifest markers in {SOURCE}")
    block = source[begin + len(BEGIN_MARKER):end]
    if block.startswith("\n"):
        block = block[1:]
    return block.rstrip()


def swift_constant(source: str, pattern: re.Pattern[str], label: str) -> str:
    match = pattern.search(source)
    if not match:
        raise ManifestError(f"could not find Swift {label} constant in {SOURCE}")
    return match.group(2)


def replace_swift_constant(source: str, pattern: re.Pattern[str], label: str, value: str) -> str:
    def replacement(match: re.Match[str]) -> str:
        return f"{match.group(1)}{value}{match.group(3)}"

    replaced, count = pattern.subn(replacement, source, count=1)
    if count != 1:
        raise ManifestError(f"could not update Swift {label} constant in {SOURCE}")
    return replaced


def update_source(source: str, manifest: str, repo: str, revision: str) -> str:
    source = replace_generated_block(source, manifest)
    source = replace_swift_constant(source, SWIFT_REPO_RE, "repository", repo)
    source = replace_swift_constant(source, SWIFT_REVISION_RE, "repository commit", revision)
    return source


def source_matches(source: str, manifest: str, repo: str, revision: str) -> bool:
    return (
        current_generated_block(source) == manifest
        and swift_constant(source, SWIFT_REPO_RE, "repository") == repo
        and swift_constant(source, SWIFT_REVISION_RE, "repository commit") == revision
    )


def build_manifest(args: argparse.Namespace) -> str:
    paths = listed_model_files(args.repo, args.revision, DEFAULT_BUNDLES, DEFAULT_EXTRA_FILES)
    if not paths:
        raise ManifestError("no model files found")

    digests: dict[str, str] = {}
    for path in paths:
        print(f"hashing {path}", file=sys.stderr)
        digests[path] = digest_for_path(args.repo, args.revision, path)
    return render_manifest(paths, digests)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--revision", default=DEFAULT_REVISION)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--write", action="store_true", help="rewrite the generated manifest block in main.swift")
    parser.add_argument("--check", action="store_true", help="fail if main.swift is not already up to date")
    args = parser.parse_args()

    if args.write and args.check:
        raise ManifestError("--write and --check are mutually exclusive")

    manifest = build_manifest(args)

    if args.write:
        source = args.source.read_text(encoding="utf-8")
        args.source.write_text(update_source(source, manifest, args.repo, args.revision), encoding="utf-8")
        return 0

    if args.check:
        source = args.source.read_text(encoding="utf-8")
        if not source_matches(source, manifest, args.repo, args.revision):
            print("model manifest is stale; run scripts/update-model-manifest.py --write", file=sys.stderr)
            return 1
        return 0

    print(manifest)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
