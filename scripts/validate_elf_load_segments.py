#!/usr/bin/env python3
"""Fail closed unless llvm-readelf reports valid 16 KB LOAD alignment."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


class ValidationError(ValueError):
    """Raised when an ELF has unreadable or incompatible LOAD segments."""


def validate_elf(readelf: str | Path, library: str | Path) -> tuple[int, ...]:
    """Return LOAD alignments after checking command status and ELF output."""
    try:
        result = subprocess.run(
            [str(readelf), "-lW", str(library)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise ValidationError("could not execute llvm-readelf") from exc

    if result.returncode != 0:
        raise ValidationError(
            f"llvm-readelf failed for {library} (exit {result.returncode})"
        )

    alignments = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or fields[0] != "LOAD":
            continue
        if len(fields) < 2:
            raise ValidationError(f"malformed LOAD segment in {library}")
        try:
            alignment = int(fields[-1], 0)
        except ValueError as exc:
            raise ValidationError(f"malformed LOAD alignment in {library}") from exc
        alignments.append(alignment)

    if not alignments:
        raise ValidationError(f"llvm-readelf reported no LOAD segments for {library}")
    if any(alignment < 0x4000 for alignment in alignments):
        raise ValidationError(f"native library lacks 16 KB LOAD alignment: {library}")
    return tuple(alignments)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("readelf", help="path to llvm-readelf")
    parser.add_argument("libraries", nargs="+", help="ELF shared libraries")
    args = parser.parse_args(argv)
    try:
        for library in args.libraries:
            validate_elf(args.readelf, library)
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"Validated 16 KB LOAD alignment in {len(args.libraries)} native libraries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
