#!/usr/bin/env python3
"""Reject log calls that look like they may include transcript content.

This is a conservative static guard. It does not prove privacy, but it
catches the easy mistakes: interpolating or concatenating transcript
text, correction sources/replacements, or whole correction arrays into
`log(...)`. Counts and boolean state are allowed.

The whole argument expression of each `log(...)` call is scanned —
string-literal prose is stripped first so only code (interpolations,
concatenation operands, direct arguments, `String(format:)` arguments)
is checked for forbidden identifiers.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PATHS = [ROOT / "swift" / "Sources" / "Parakey" / "main.swift"]

LOG_CALL_RE = re.compile(r"(?<![A-Za-z0-9_.])log\s*\(")

FORBIDDEN_IDENTIFIER_RE = re.compile(
    r"""
    \b(
        text
      | transcript
      | rawTranscript
      | trimmed
      | cleaned
      | corrected
      | stripped
      | correction
      | corrections
      | replacement
      | source
      | sourceField
      | replacementField
      | body
      | history
      | s
    )\b
    """,
    re.VERBOSE,
)

# A member-access chain ending in a metadata-only suffix is safe even when
# it starts from a forbidden identifier (e.g. `cleaned.count`,
# `cleaned.utf8.count`, `mode.rawValue`). Matches are masked out before the
# forbidden-identifier scan, so each occurrence is judged individually.
SAFE_MEMBER_ACCESS_RE = re.compile(
    r"""
    \b[A-Za-z_][A-Za-z0-9_]*
    (?: \s* [?!]? \. \s* [A-Za-z_][A-Za-z0-9_]* )*
    \s* [?!]? \. \s*
    (
        count
      | isEmpty
      | appliedCount
      | removedCount
      | rawValue
    )
    \b
    """,
    re.VERBOSE,
)


class Finding(Exception):
    pass


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def extract_log_calls(text: str) -> list[tuple[int, str]]:
    calls: list[tuple[int, str]] = []
    search_from = 0
    while True:
        match = LOG_CALL_RE.search(text, search_from)
        if match is None:
            return calls
        start = match.start()
        i = match.end()
        depth = 1
        in_string = False
        escaped = False
        while i < len(text):
            ch = text[i]
            if in_string:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_string = False
            else:
                if ch == '"':
                    in_string = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        calls.append((start, text[start : i + 1]))
                        search_from = i + 1
                        break
            i += 1
        else:
            raise Finding(f"unterminated log call near line {line_number_for_offset(text, start)}")


def log_call_arguments(call: str) -> str:
    return call[call.index("(") + 1 : -1]


def code_only(expr: str) -> str:
    """Strip string-literal prose from a Swift expression, keeping code.

    Literal text is replaced with whitespace so identifiers in prose
    (e.g. log("history cleared")) are not scanned, while code embedded
    in interpolations (e.g. "\\(cleaned)") is kept and scanned, at any
    nesting depth.
    """
    out: list[str] = []
    # Stack of [kind, paren_depth] contexts; the base code context never pops.
    stack: list[list] = [["code", 0]]
    escaped = False
    i = 0
    while i < len(expr):
        ch = expr[i]
        if stack[-1][0] == "string":
            if escaped:
                escaped = False
            elif ch == "\\":
                if expr.startswith("\\(", i):
                    stack.append(["code", 1])
                    out.append(" (")
                    i += 2
                    continue
                escaped = True
            elif ch == '"':
                stack.pop()
                out.append(" ")
            i += 1
            continue
        if ch == '"':
            stack.append(["string", 0])
            out.append(" ")
        elif ch == "(":
            stack[-1][1] += 1
            out.append(ch)
        elif ch == ")":
            stack[-1][1] -= 1
            out.append(ch)
            if stack[-1][1] == 0 and len(stack) > 1:
                stack.pop()  # end of an interpolation; back inside the literal
                out.append(" ")
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def forbidden_identifiers(code: str) -> list[str]:
    masked = SAFE_MEMBER_ACCESS_RE.sub(" ", code)
    return sorted({match.group(1) for match in FORBIDDEN_IDENTIFIER_RE.finditer(masked)})


def scan_text(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    for offset, call in extract_log_calls(text):
        line = line_number_for_offset(text, offset)
        identifiers = forbidden_identifiers(code_only(log_call_arguments(call)))
        if identifiers:
            findings.append(
                f"{path}:{line}: suspicious log argument references {', '.join(identifiers)}"
            )
    return findings


def scan_paths(paths: list[Path]) -> list[str]:
    findings: list[str] = []
    for path in paths:
        findings.extend(scan_text(path, path.read_text(encoding="utf-8")))
    return findings


def run_self_test() -> None:
    clean = """
    log("release: \\(String(format: "%.2f", dur)) s -> \\(cleaned.count) chars")
    log("corrections: \\(settings.transcriptCorrections.count) configured")
    log("history copied to clipboard (\\(s.count) chars)")
    log("recent transcript history trimmed by \\(removed) entr\\(removed == 1 ? "y" : "ies")")
    log("trigger mode -> " + mode.rawValue)
    log("request body empty: \\(payload.isEmpty)")
    """
    dirty = """
    log("transcript: \\(cleaned)")
    log("correction: \\(correction.replacement)")
    log("inserted: \\(String(format: "%@", cleaned))")
    log("inserting: " + cleaned)
    log(transcript)
    log("request body: \\(body)")
    log("history: \\(history.joined(separator: ", "))")
    """
    non_log_calls = """
    catalog("transcript: \\(cleaned)")
    logger.log("transcript: \\(cleaned)")
    """
    with tempfile.TemporaryDirectory() as tmp:
        clean_path = Path(tmp) / "clean.swift"
        dirty_path = Path(tmp) / "dirty.swift"
        non_log_path = Path(tmp) / "non-log.swift"
        clean_path.write_text(clean, encoding="utf-8")
        dirty_path.write_text(dirty, encoding="utf-8")
        non_log_path.write_text(non_log_calls, encoding="utf-8")
        findings = scan_paths([clean_path])
        if findings:
            raise SystemExit(f"self-test rejected clean log calls: {findings}")
        if scan_paths([non_log_path]):
            raise SystemExit("self-test treated non-log calls as log calls")
        findings = scan_paths([dirty_path])
        if len(findings) != 7:
            raise SystemExit(f"self-test expected 7 dirty findings, got {len(findings)}: {findings}")
        for needle, label in [
            (":4:", "String(format:) argument bypass"),
            (":5:", "string concatenation bypass"),
            (":6:", "direct argument bypass"),
            (":7:", "forbidden identifier 'body'"),
            (":8:", "forbidden identifier 'history'"),
        ]:
            if not any(needle in finding for finding in findings):
                raise SystemExit(f"self-test did not catch {label}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        print("log privacy self-test passed")
        return 0

    paths = args.paths or DEFAULT_PATHS
    findings = scan_paths(paths)
    if findings:
        print("log privacy check failed:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print("log privacy check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
