#!/usr/bin/env python3
"""Validate that a release tag matches pubspec and the intended commit."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


TAG_RE = re.compile(r"v(?P<version>[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\Z")
COMMIT_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


class ValidationError(ValueError):
    """A release tag does not identify the requested version and commit."""


def _pubspec_version(path: Path) -> str:
    versions = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"version:\s*([^\s#]+)\s*(?:#.*)?", line)
        if match:
            versions.append(match.group(1))
    if len(versions) != 1 or not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+", versions[0]):
        raise ValidationError("pubspec.yaml must contain one numeric major.minor.patch+build version")
    return versions[0]


def _git_commit(revision: str, repository: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"],
        check=False, capture_output=True, text=True, cwd=repository,
    )
    if result.returncode:
        raise ValidationError(f"Git cannot resolve {revision} to a commit")
    commit = result.stdout.strip().lower()
    if not COMMIT_RE.fullmatch(commit):
        raise ValidationError(f"Git returned an invalid commit for {revision}")
    return commit


def validate_release_tag(tag: str, pubspec: Path, expected_commit: str,
                         *, fetch_tag: bool = False,
                         repository: Path = Path(".")) -> str:
    """Check strict tag/version syntax and that its target is expected HEAD."""
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise ValidationError("tag must have the form v<major>.<minor>.<patch>+<build>")

    version = _pubspec_version(pubspec)
    if match.group("version") != version:
        raise ValidationError(f"tag version {match.group('version')} does not match pubspec version {version}")

    expected_commit = expected_commit.lower()
    if not COMMIT_RE.fullmatch(expected_commit):
        raise ValidationError("expected commit must be a full 40- or 64-character Git object id")

    if fetch_tag:
        ref = f"refs/tags/{tag}"
        result = subprocess.run(
            ["git", "fetch", "--no-tags", "origin", f"{ref}:{ref}"],
            check=False, capture_output=True, text=True, cwd=repository,
        )
        if result.returncode:
            raise ValidationError(f"could not fetch release tag {tag} from origin")

    head = _git_commit("HEAD", repository)
    if head != expected_commit:
        raise ValidationError("checked-out commit does not match the workflow's intended commit")

    tag_commit = _git_commit(f"refs/tags/{tag}", repository)
    if tag_commit != expected_commit:
        raise ValidationError("release tag does not point to the workflow's intended commit")
    return version


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--tag")
    parser.add_argument("--expected-commit")
    parser.add_argument("--fetch-tag", action="store_true",
                        help="fetch this exact tag from origin before checking its target")
    parser.add_argument("--dry-run", action="store_true",
                        help="confirm dry-run mode without requiring a tag, Git ref, or secrets")
    args = parser.parse_args(argv)

    try:
        if args.dry_run:
            if args.tag is not None or args.expected_commit is not None or args.fetch_tag:
                raise ValidationError("--dry-run cannot be combined with tag or commit checks")
            _pubspec_version(args.pubspec)
            print("Dry run: release tag validation skipped; no tag, commit, or secrets required.")
            return 0
        if not args.tag or not args.expected_commit:
            raise ValidationError("--tag and --expected-commit are required outside dry-run mode")
        version = validate_release_tag(args.tag, args.pubspec, args.expected_commit,
                                       fetch_tag=args.fetch_tag,
                                       repository=Path.cwd())
    except (OSError, ValidationError) as exc:
        print(f"Release tag validation failed: {exc}", file=sys.stderr)
        return 1

    print(f"Validated release tag {args.tag} for version {version} and intended commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
