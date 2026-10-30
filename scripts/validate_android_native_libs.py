#!/usr/bin/env python3
"""Validate Flutter native-library presence in Android APK/AAB ZIP artifacts."""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path


SUPPORTED_ABIS = frozenset(
    {"arm64-v8a", "armeabi-v7a", "x86_64", "x86", "armeabi", "riscv64"}
)
LIBRARY_PATH = re.compile(r"^(?:(.*)/)?lib/([^/]+)/([^/]+\.so)$")
FLUTTER_LIBRARY = "libflutter.so"
APP_LIBRARY = "libapp.so"


class ValidationError(ValueError):
    """Raised when an APK/AAB lacks a usable Flutter native-library payload."""


def validate_archive(
    path: str | Path, *, release: bool = False
) -> dict[str, frozenset[str]]:
    """Return base-module library names by ABI, or reject an invalid artifact."""
    artifact = Path(path)
    if not artifact.is_file():
        raise ValidationError(f"artifact does not exist: {artifact}")

    try:
        with zipfile.ZipFile(artifact) as archive:
            bad_entry = archive.testzip()
            if bad_entry is not None:
                raise ValidationError(f"corrupt ZIP entry: {bad_entry}")

            # APK entries live under lib/<abi>; AAB base-module entries live
            # under base/lib/<abi>. Other AAB feature modules are not enough to
            # satisfy Flutter's startup loader in the base application.
            base_libraries: dict[str, set[str]] = {}
            for name in archive.namelist():
                match = LIBRARY_PATH.fullmatch(name)
                if match is None:
                    continue
                module, abi, library = match.groups()
                if abi not in SUPPORTED_ABIS:
                    continue
                if module not in (None, "", "base"):
                    continue
                base_libraries.setdefault(abi, set()).add(library)
    except zipfile.BadZipFile as exc:
        raise ValidationError("artifact is not a readable ZIP archive") from exc
    except OSError as exc:
        raise ValidationError("artifact could not be read") from exc

    if not base_libraries:
        raise ValidationError("no supported native-library ABI found in APK/AAB base")

    errors = []
    for abi, libraries in sorted(base_libraries.items()):
        required = {FLUTTER_LIBRARY}
        if release:
            required.add(APP_LIBRARY)
        missing = required - libraries
        if missing:
            errors.append(f"{abi}: missing {', '.join(sorted(missing))}")
    if errors:
        raise ValidationError("invalid Flutter native-library payload: " + "; ".join(errors))

    return {abi: frozenset(libraries) for abi, libraries in sorted(base_libraries.items())}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--release",
        action="store_true",
        help="also require libapp.so for every packaged ABI (release artifacts)",
    )
    parser.add_argument("artifact", help="APK or AAB to inspect")
    args = parser.parse_args(argv)
    try:
        libraries = validate_archive(args.artifact, release=args.release)
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    summary = ", ".join(
        f"{abi} ({', '.join(sorted(names))})" for abi, names in libraries.items()
    )
    print(f"Flutter native libraries present in base module: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
