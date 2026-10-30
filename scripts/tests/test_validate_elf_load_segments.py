import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_elf_load_segments import ValidationError, validate_elf


class ElfLoadSegmentTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        root = Path(self.temp_dir.name)
        self.fake_elf = root / "synthetic.so"
        self.fake_elf.write_bytes(b"synthetic ELF fixture")
        self.readelf = root / "llvm-readelf"

    def set_readelf(self, output, exit_status=0):
        self.readelf.write_text(
            "#!/bin/sh\n"
            f"cat <<'READelf_OUTPUT'\n{output}\nREADelf_OUTPUT\n"
            f"exit {exit_status}\n"
        )
        self.readelf.chmod(0o755)

    def test_accepts_reported_load_alignment_at_or_above_16_kb(self):
        self.set_readelf(
            "LOAD 0x0 0x0 0x0 0x1000 0x1000 R E 0x4000\n"
            "LOAD 0x1000 0x1000 0x1000 0x1000 0x1000 RW 0x10000"
        )

        self.assertEqual(validate_elf(self.readelf, self.fake_elf), (0x4000, 0x10000))

    def test_rejects_successful_readelf_with_no_load_segments(self):
        self.set_readelf("There are no program headers.")

        with self.assertRaisesRegex(ValidationError, "no LOAD segments"):
            validate_elf(self.readelf, self.fake_elf)

    def test_rejects_failed_readelf_even_if_stdout_looks_valid(self):
        self.set_readelf("LOAD 0x0 0x0 0x0 0x1000 0x1000 R E 0x4000", 2)

        with self.assertRaisesRegex(ValidationError, "failed.*exit 2"):
            validate_elf(self.readelf, self.fake_elf)

    def test_rejects_malformed_load_alignment(self):
        self.set_readelf("LOAD 0x0 0x0 0x0 0x1000 0x1000 R E malformed")

        with self.assertRaisesRegex(ValidationError, "malformed LOAD alignment"):
            validate_elf(self.readelf, self.fake_elf)

    def test_rejects_load_segment_line_without_alignment(self):
        self.set_readelf("LOAD")

        with self.assertRaisesRegex(ValidationError, "malformed LOAD segment"):
            validate_elf(self.readelf, self.fake_elf)

    def test_rejects_alignment_below_16_kb(self):
        self.set_readelf("LOAD 0x0 0x0 0x0 0x1000 0x1000 R E 0x1000")

        with self.assertRaisesRegex(ValidationError, "lacks 16 KB"):
            validate_elf(self.readelf, self.fake_elf)


if __name__ == "__main__":
    unittest.main()
