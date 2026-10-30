"""Focused tests for safe release tag and commit validation."""

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validate_release_tag


class ReleaseTagValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: sample\nversion: 1.2.3+4\n", encoding="utf-8")
        self._git("init", "-q")
        self._git("config", "user.email", "release-validator@example.invalid")
        self._git("config", "user.name", "Release Validator Test")
        (self.root / "tracked.txt").write_text("commit one\n", encoding="utf-8")
        self._git("add", "tracked.txt")
        self._git("commit", "-q", "-m", "first")
        self.commit = self._git("rev-parse", "HEAD")
        self._git("tag", "v1.2.3+4")

    def tearDown(self):
        self.temp.cleanup()

    def _git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, check=True,
                                capture_output=True, text=True)
        return result.stdout.strip()

    def test_valid_tag_matches_pubspec_and_exact_head(self):
        self.assertEqual(
            validate_release_tag.validate_release_tag(
                "v1.2.3+4", self.pubspec, self.commit,
                repository=self.root),
            "1.2.3+4",
        )

    def test_malicious_tag_is_rejected_before_git_resolution(self):
        with self.assertRaisesRegex(validate_release_tag.ValidationError, "form"):
            validate_release_tag.validate_release_tag(
                'v1.2.3+4";touch /tmp/tag-injection;#', self.pubspec, self.commit,
                repository=self.root)

    def test_version_mismatch_is_rejected(self):
        with self.assertRaisesRegex(validate_release_tag.ValidationError,
                                    "does not match pubspec"):
            validate_release_tag.validate_release_tag(
                "v1.2.3+5", self.pubspec, self.commit,
                repository=self.root)

    def test_tag_pointing_to_another_commit_is_rejected(self):
        (self.root / "tracked.txt").write_text("commit two\n", encoding="utf-8")
        self._git("commit", "-qam", "second")
        wrong_commit = self._git("rev-parse", "HEAD")
        with self.assertRaisesRegex(validate_release_tag.ValidationError,
                                    "tag does not point"):
            validate_release_tag.validate_release_tag(
                "v1.2.3+4", self.pubspec, wrong_commit,
                repository=self.root)

    def test_checked_out_commit_must_equal_intended_commit(self):
        self._git("tag", "v1.2.3+4", "--force")
        with self.assertRaisesRegex(validate_release_tag.ValidationError,
                                    "checked-out commit"):
            validate_release_tag.validate_release_tag(
                "v1.2.3+4", self.pubspec, "a" * 40,
                repository=self.root)

    def test_dry_run_needs_no_tag_commit_or_secrets(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = validate_release_tag.main([
                "--dry-run", "--pubspec", str(self.pubspec)])
        self.assertEqual(result, 0)
        self.assertIn("no tag, commit, or secrets required", output.getvalue())

    def test_dry_run_rejects_mixed_tag_checks(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            result = validate_release_tag.main([
                "--dry-run", "--tag", "v1.2.3+4", "--pubspec", str(self.pubspec)])
        self.assertEqual(result, 1)
        self.assertIn("cannot be combined", output.getvalue())


if __name__ == "__main__":
    unittest.main()
