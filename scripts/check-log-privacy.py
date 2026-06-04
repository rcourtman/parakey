#!/usr/bin/env python3
"""Reject log calls that look like they may include transcript content.

This is a conservative static guard. It does not prove privacy, but it
catches the easy mistakes: interpolating transcript text, correction
sources/replacements, or whole correction arrays into `log(...)`.
Counts and boolean state are allowed.
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
      | s
    )\b
    """,
    re.VERBOSE,
)

SAFE_SUFFIX_RE = re.compile(
    r"""
    \.
    (
        count
      | isEmpty
      | appliedCount
      | removedCount
      | utf8\.count
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


def interpolation_expressions(call: str) -> list[str]:
    expressions: list[str] = []
    i = 0
    while True:
        start = call.find("\\(", i)
        if start == -1:
            return expressions
        j = start + 2
        depth = 1
        while j < len(call):
            ch = call[j]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    expressions.append(call[start + 2 : j].strip())
                    i = j + 1
                    break
            j += 1
        else:
            return expressions


def expression_is_safe(expr: str) -> bool:
    stripped = re.sub(r"\s+", "", expr)
    if SAFE_SUFFIX_RE.search(stripped):
        return True
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.rawValue", stripped):
        return True
    if "String(format:" in expr:
        return True
    return False


def scan_text(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    for offset, call in extract_log_calls(text):
        line = line_number_for_offset(text, offset)
        for expr in interpolation_expressions(call):
            if expression_is_safe(expr):
                continue
            if FORBIDDEN_IDENTIFIER_RE.search(expr):
                findings.append(f"{path}:{line}: suspicious log interpolation: \\({expr})")
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
    """
    dirty = """
    log("transcript: \\(cleaned)")
    log("correction: \\(correction.replacement)")
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
        if scan_paths([clean_path]):
            raise SystemExit("self-test rejected clean log calls")
        if scan_paths([non_log_path]):
            raise SystemExit("self-test treated non-log calls as log calls")
        findings = scan_paths([dirty_path])
        if len(findings) != 2:
            raise SystemExit(f"self-test expected 2 dirty findings, got {len(findings)}")


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
