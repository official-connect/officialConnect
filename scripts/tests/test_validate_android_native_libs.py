import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_android_native_libs import ValidationError, validate_archive


class NativeLibraryArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.artifact = Path(self.temp_dir.name) / "fixture.zip"

    def write_zip(self, entries):
        with zipfile.ZipFile(self.artifact, "w") as archive:
            for name, payload in entries:
                archive.writestr(name, payload)

    def test_accepts_apk_with_flutter_libraries_for_each_packaged_abi(self):
        self.write_zip(
            [
                (f"lib/{abi}/{library}", b"synthetic ELF payload")
                for abi in ("arm64-v8a", "armeabi-v7a")
                for library in ("libapp.so", "libflutter.so")
            ]
        )

        found = validate_archive(self.artifact, release=True)

        self.assertEqual(set(found), {"arm64-v8a", "armeabi-v7a"})
        for libraries in found.values():
            self.assertIn("libflutter.so", libraries)

    def test_accepts_aab_base_module_and_ignores_other_modules(self):
        self.write_zip(
            [
                ("base/lib/arm64-v8a/libapp.so", b"app"),
                ("base/lib/arm64-v8a/libflutter.so", b"flutter"),
                ("feature/lib/x86_64/feature.so", b"feature"),
            ]
        )

        self.assertEqual(
            set(validate_archive(self.artifact, release=True)), {"arm64-v8a"}
        )

    def test_rejects_missing_flutter_per_abi(self):
        self.write_zip(
            [
                (f"base/lib/{abi}/libapp.so", b"app")
                for abi in ("arm64-v8a", "armeabi-v7a")
            ]
        )

        with self.assertRaisesRegex(ValidationError, "arm64-v8a.*libflutter.so"):
            validate_archive(self.artifact)

    def test_feature_module_library_does_not_satisfy_missing_base_flutter(self):
        self.write_zip(
            [
                ("base/lib/arm64-v8a/libapp.so", b"app"),
                ("feature/lib/arm64-v8a/libflutter.so", b"flutter"),
            ]
        )

        with self.assertRaisesRegex(ValidationError, "libflutter.so"):
            validate_archive(self.artifact)

    def test_rejects_native_payload_with_no_flutter_library(self):
        self.write_zip([("lib/arm64-v8a/libplugin.so", b"plugin")])

        with self.assertRaisesRegex(ValidationError, "libflutter.so"):
            validate_archive(self.artifact)

    def test_release_requires_libapp_for_every_packaged_abi(self):
        self.write_zip(
            [
                (f"base/lib/{abi}/{library}", b"library")
                for abi in ("arm64-v8a", "armeabi-v7a")
                for library in ("libflutter.so",)
            ]
        )

        # Debug/native-payload inspection only requires Flutter's loader.
        self.assertEqual(set(validate_archive(self.artifact)), {"arm64-v8a", "armeabi-v7a"})
        with self.assertRaises(ValidationError) as context:
            validate_archive(self.artifact, release=True)
        self.assertIn("arm64-v8a: missing libapp.so", str(context.exception))
        self.assertIn("armeabi-v7a: missing libapp.so", str(context.exception))

    def test_rejects_unreadable_artifact(self):
        self.artifact.write_bytes(b"not a zip")

        with self.assertRaisesRegex(ValidationError, "readable ZIP"):
            validate_archive(self.artifact)


if __name__ == "__main__":
    unittest.main()
