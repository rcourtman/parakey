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
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "swift" / "Sources" / "Parakey" / "main.swift"

DEFAULT_REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
# The pinned revision is NOT duplicated here: main.swift's
# parakeetV3RepositoryCommit is the single source of truth, parsed at
# runtime when --revision is not passed (see revision_from_source).
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
SAFE_MODEL_PATH = re.compile(r"^[A-Za-z0-9._/-]+$")
SAFE_REPO = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SAFE_REVISION = re.compile(r"^[A-Za-z0-9._/-]+$")
SWIFT_REPO_RE = re.compile(r'(static let parakeetV3Repository = ")([^"]+)(")')
SWIFT_REVISION_RE = re.compile(r'(static let parakeetV3RepositoryCommit = ")([^"]+)(")')


class ManifestError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirect)

LINK_HEADER_RE = re.compile(r"<([^<>]+)>([^<]*)")
LINK_REL_NEXT_RE = re.compile(r'rel\s*=\s*"?next"?')
MAX_TREE_PAGES = 100


def next_page_url(link_header: str | None) -> str | None:
    if not link_header:
        return None
    for match in LINK_HEADER_RE.finditer(link_header):
        if LINK_REL_NEXT_RE.search(match.group(2)):
            return match.group(1)
    return None


def fetch_tree_page(url: str) -> tuple[object, str | None]:
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
        next_url = next_page_url(response.headers.get("Link"))
    return payload, next_url


def quoted_repo(repo: str) -> str:
    return urllib.parse.quote(repo, safe="/")


def quoted_path(path: str) -> str:
    return urllib.parse.quote(path, safe="/")


def validate_slash_path(value: str, label: str, pattern: re.Pattern[str]) -> None:
    if not value or value.startswith("/") or not pattern.fullmatch(value):
        raise ManifestError(f"unsafe {label}: {value!r}")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ManifestError(f"unsafe {label}: {value!r}")


def validate_repo(repo: str) -> None:
    if not SAFE_REPO.fullmatch(repo):
        raise ManifestError(f"unsafe Hugging Face repo id: {repo!r}")
    owner, name = repo.split("/", 1)
    if owner in {"", ".", ".."} or name in {"", ".", ".."}:
        raise ManifestError(f"unsafe Hugging Face repo id: {repo!r}")


def validate_revision(revision: str) -> None:
    validate_slash_path(revision, "revision", SAFE_REVISION)


def validate_model_path(path: str) -> None:
    validate_slash_path(path, "model path", SAFE_MODEL_PATH)


def validate_sha256(digest: str, path: str) -> None:
    if not HEX64.fullmatch(digest):
        raise ManifestError(f"invalid SHA-256 for {path}: {digest!r}")


def tree_url(repo: str, revision: str) -> str:
    return f"https://huggingface.co/api/models/{quoted_repo(repo)}/tree/{revision}?recursive=true"


def resolve_url(repo: str, revision: str, path: str) -> str:
    return f"https://huggingface.co/{quoted_repo(repo)}/resolve/{revision}/{quoted_path(path)}"


def tree_entries(repo: str, revision: str, fetch_page) -> list[object]:
    entries: list[object] = []
    url = tree_url(repo, revision)
    for _ in range(MAX_TREE_PAGES):
        page, next_url = fetch_page(url)
        if not isinstance(page, list):
            raise ManifestError("unexpected Hugging Face tree response")
        entries.extend(page)
        if next_url is None:
            return entries
        if not next_url.startswith("https://huggingface.co/"):
            raise ManifestError(f"unsafe Hugging Face tree pagination URL: {next_url!r}")
        url = next_url
    raise ManifestError(f"Hugging Face tree listing exceeded {MAX_TREE_PAGES} pages")


def listed_model_files(
    repo: str,
    revision: str,
    bundles: list[str],
    extra_files: list[str],
    fetch_page=fetch_tree_page,
) -> list[str]:
    tree = tree_entries(repo, revision, fetch_page)

    bundle_prefixes = tuple(f"{bundle}/" for bundle in bundles)
    wanted = []
    for item in tree:
        if not isinstance(item, dict) or item.get("type") != "file":
            continue
        path = item.get("path")
        if not isinstance(path, str):
            continue
        if path.startswith(bundle_prefixes) or path in extra_files:
            validate_model_path(path)
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
    digest = linked_etag(repo, revision, path) or downloaded_sha256(repo, revision, path)
    validate_sha256(digest, path)
    return digest


def render_manifest(paths: list[str], digests: dict[str, str]) -> str:
    lines = []
    for path in paths:
        validate_model_path(path)
        validate_sha256(digests[path], path)
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


def revision_from_source(path: Path) -> str:
    source = path.read_text(encoding="utf-8")
    revision = swift_constant(source, SWIFT_REVISION_RE, "repository commit")
    validate_revision(revision)
    return revision


def replace_swift_constant(source: str, pattern: re.Pattern[str], label: str, value: str) -> str:
    def replacement(match: re.Match[str]) -> str:
        return f"{match.group(1)}{value}{match.group(3)}"

    replaced, count = pattern.subn(replacement, source, count=1)
    if count != 1:
        raise ManifestError(f"could not update Swift {label} constant in {SOURCE}")
    return replaced


def update_source(source: str, manifest: str, repo: str, revision: str) -> str:
    validate_repo(repo)
    validate_revision(revision)
    source = replace_generated_block(source, manifest)
    source = replace_swift_constant(source, SWIFT_REPO_RE, "repository", repo)
    source = replace_swift_constant(source, SWIFT_REVISION_RE, "repository commit", revision)
    return source


def source_matches(source: str, manifest: str, repo: str, revision: str) -> bool:
    validate_repo(repo)
    validate_revision(revision)
    return (
        current_generated_block(source) == manifest
        and swift_constant(source, SWIFT_REPO_RE, "repository") == repo
        and swift_constant(source, SWIFT_REVISION_RE, "repository commit") == revision
    )


def build_manifest(args: argparse.Namespace) -> str:
    validate_repo(args.repo)
    validate_revision(args.revision)
    paths = listed_model_files(args.repo, args.revision, DEFAULT_BUNDLES, DEFAULT_EXTRA_FILES)
    if not paths:
        raise ManifestError("no model files found")

    digests: dict[str, str] = {}
    for path in paths:
        print(f"hashing {path}", file=sys.stderr)
        digests[path] = digest_for_path(args.repo, args.revision, path)
    return render_manifest(paths, digests)


def assert_raises(func, message: str) -> None:
    try:
        func()
    except ManifestError:
        return
    raise ManifestError(message)


def run_self_test() -> None:
    digest = "a" * 64
    revision = "b" * 40
    manifest = render_manifest(["Toy.mlmodelc/model.mil"], {"Toy.mlmodelc/model.mil": digest})
    source = """enum ModelIntegrity {
    static let parakeetV3Repository = "old/repo"
    static let parakeetV3RepositoryCommit = "oldref"

    private static let parakeetV3Files = [
        // BEGIN GENERATED PARAKEET_V3_MODEL_MANIFEST
        ModelFileDigest(relativePath: "Old.mlmodelc/model.mil", sha256: "0000000000000000000000000000000000000000000000000000000000000000"),
        // END GENERATED PARAKEET_V3_MODEL_MANIFEST
    ]
}
"""
    updated = update_source(source, manifest, DEFAULT_REPO, revision)
    if not source_matches(updated, manifest, DEFAULT_REPO, revision):
        raise ManifestError("self-test source update did not round-trip")
    if current_generated_block(updated) != manifest:
        raise ManifestError("self-test manifest block mismatch")

    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp) / "main.swift"
        fixture.write_text(updated, encoding="utf-8")
        if revision_from_source(fixture) != revision:
            raise ManifestError("self-test did not read pinned revision from Swift source")
        fixture.write_text("enum ModelIntegrity {}\n", encoding="utf-8")
        assert_raises(lambda: revision_from_source(fixture),
                      "self-test accepted Swift source without revision constant")
        fixture.write_text('static let parakeetV3RepositoryCommit = "../main"\n', encoding="utf-8")
        assert_raises(lambda: revision_from_source(fixture),
                      "self-test accepted malformed revision constant")

    page_one = [{"type": "file", "path": "Toy.mlmodelc/model.mil"}]
    page_two = [{"type": "file", "path": "vocab.json"}]
    first_url = tree_url(DEFAULT_REPO, revision)
    second_url = f"https://huggingface.co/api/models/{DEFAULT_REPO}/tree/{revision}?recursive=true&cursor=abc"

    def paged_fetch(url: str) -> tuple[object, str | None]:
        if url == first_url:
            return page_one, second_url
        if url == second_url:
            return page_two, None
        raise ManifestError(f"self-test fetched unexpected URL: {url!r}")

    paths = listed_model_files(DEFAULT_REPO, revision, ["Toy.mlmodelc"], ["vocab.json"], paged_fetch)
    if paths != ["Toy.mlmodelc/model.mil", "vocab.json"]:
        raise ManifestError(f"self-test pagination dropped tree entries: {paths!r}")

    if next_page_url('<https://huggingface.co/page2>; rel="next"') != "https://huggingface.co/page2":
        raise ManifestError("self-test did not parse Link rel=next header")
    if next_page_url('<https://huggingface.co/page0>; rel="prev"') is not None:
        raise ManifestError("self-test treated rel=prev as a next page")
    if next_page_url(None) is not None:
        raise ManifestError("self-test invented a next page for a missing Link header")

    assert_raises(
        lambda: tree_entries(DEFAULT_REPO, revision,
                             lambda url: ([], "https://evil.example/tree")),
        "self-test accepted pagination URL outside huggingface.co",
    )
    assert_raises(
        lambda: tree_entries(DEFAULT_REPO, revision,
                             lambda url: ([], first_url)),
        "self-test accepted unbounded pagination",
    )
    assert_raises(
        lambda: tree_entries(DEFAULT_REPO, revision, lambda url: ({}, None)),
        "self-test accepted non-list tree response",
    )

    assert_raises(lambda: validate_model_path("../model.mil"),
                  "self-test accepted parent traversal in model path")
    assert_raises(lambda: validate_model_path("Toy.mlmodelc//model.mil"),
                  "self-test accepted empty model path segment")
    assert_raises(lambda: validate_model_path("Toy.mlmodelc/./model.mil"),
                  "self-test accepted dot model path segment")
    assert_raises(lambda: validate_model_path('Toy.mlmodelc/"model".mil'),
                  "self-test accepted unsafe model path character")
    assert_raises(lambda: validate_repo("FluidInference"),
                  "self-test accepted repo without owner/name")
    assert_raises(lambda: validate_revision("../main"),
                  "self-test accepted parent traversal in revision")
    assert_raises(lambda: validate_sha256("not-a-digest", "Toy.mlmodelc/model.mil"),
                  "self-test accepted malformed digest")
    assert_raises(lambda: current_generated_block("missing markers"),
                  "self-test accepted source without manifest markers")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument(
        "--revision",
        default=None,
        help="Hugging Face revision; defaults to parakeetV3RepositoryCommit parsed from --source",
    )
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--write", action="store_true", help="rewrite the generated manifest block in main.swift")
    parser.add_argument("--check", action="store_true", help="fail if main.swift is not already up to date")
    parser.add_argument("--self-test", action="store_true", help="run offline updater self-tests")
    args = parser.parse_args()

    selected_modes = sum([args.write, args.check, args.self_test])
    if selected_modes > 1:
        raise ManifestError("--write, --check, and --self-test are mutually exclusive")
    if args.self_test:
        run_self_test()
        return 0

    if args.revision is None:
        args.revision = revision_from_source(args.source)

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
