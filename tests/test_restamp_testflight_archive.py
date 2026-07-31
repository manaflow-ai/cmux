import importlib.util
import io
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ios" / "scripts" / "restamp-testflight-archive.py"
SPEC = importlib.util.spec_from_file_location("restamp_testflight_archive", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def make_archive(tmp_path: Path, name: str = "cmux-dev.xcarchive") -> tuple[Path, Path]:
    archive = tmp_path / name
    app = archive / "Products" / "Applications" / "cmux.app"
    app.mkdir(parents=True)
    app_info = {
        "CFBundleIdentifier": "dev.cmux.app.dev",
        "CFBundleDisplayName": "cmux DEV",
        "CFBundleExecutable": "cmux",
        "CFBundleShortVersionString": "1.0.4",
        "CFBundleVersion": "10",
    }
    archive_info = {
        "ApplicationProperties": {
            "ApplicationPath": "Applications/cmux.app",
            "CFBundleIdentifier": "dev.cmux.app.dev",
            "CFBundleShortVersionString": "1.0.4",
            "CFBundleVersion": "10",
        }
    }
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump(app_info, handle, fmt=plistlib.FMT_BINARY)
    with (archive / "Info.plist").open("wb") as handle:
        plistlib.dump(archive_info, handle)
    (app / "cmux").write_bytes(b"unsigned-binary")
    (app / "cmux").chmod(0o755)
    (app / "Info.plist").chmod(0o644)
    (archive / "Info.plist").chmod(0o644)
    return archive, app


def restamp(archive: Path, build_number: str = "20260719010101") -> None:
    MODULE.restamp(archive, "dev.cmux.app.dev", "cmux DEV", "1.0.4", build_number)


class RestampTestFlightArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_restamps_app_and_archive_plists(self) -> None:
        archive, app = make_archive(self.tmp_path)

        restamp(archive)

        with (app / "Info.plist").open("rb") as handle:
            app_info = plistlib.load(handle)
        with (archive / "Info.plist").open("rb") as handle:
            archive_info = plistlib.load(handle)
        self.assertEqual(app_info["CFBundleVersion"], "20260719010101")
        self.assertEqual(archive_info["ApplicationProperties"]["CFBundleVersion"], "20260719010101")
        self.assertTrue((app / "Info.plist").read_bytes().startswith(b"bplist00"))
        self.assertEqual((app / "Info.plist").stat().st_mode & 0o777, 0o644)
        self.assertEqual((archive / "Info.plist").stat().st_mode & 0o777, 0o644)

    def test_validate_only_accepts_identity_without_mutating_build_number(self) -> None:
        archive, app = make_archive(self.tmp_path)

        MODULE.validate(archive, "dev.cmux.app.dev", "cmux DEV", "1.0.4")

        with (app / "Info.plist").open("rb") as handle:
            app_info = plistlib.load(handle)
        self.assertEqual(app_info["CFBundleVersion"], "10")

    def test_extracts_tar_safely_and_preserves_executable_mode(self) -> None:
        source_archive, _ = make_archive(self.tmp_path / "source", "cmux-pr-demo.xcarchive")
        tar_path = self.tmp_path / "archive.tar"
        subprocess.run(
            ["tar", "-C", str(source_archive.parent), "-cf", str(tar_path), source_archive.name],
            check=True,
        )
        extracted = self.tmp_path / "output" / "cmux-pr-demo.xcarchive"

        MODULE.extract_archive_tar(tar_path, extracted)
        MODULE.validate(extracted, "dev.cmux.app.dev", "cmux DEV", "1.0.4")

        executable = extracted / "Products" / "Applications" / "cmux.app" / "cmux"
        self.assertEqual(executable.stat().st_mode & 0o777, 0o755)

    def test_rejects_unsafe_tar_entries(self) -> None:
        for name, entry_type in (("../outside", tarfile.REGTYPE), ("cmux-pr-demo.xcarchive/link", tarfile.SYMTYPE)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                tar_path = root / "archive.tar"
                with tarfile.open(tar_path, "w") as handle:
                    root_info = tarfile.TarInfo("cmux-pr-demo.xcarchive")
                    root_info.type = tarfile.DIRTYPE
                    handle.addfile(root_info)
                    info = tarfile.TarInfo(name)
                    info.type = entry_type
                    if entry_type == tarfile.REGTYPE:
                        info.size = 1
                        handle.addfile(info, io.BytesIO(b"x"))
                    else:
                        info.linkname = "/tmp/outside"
                        handle.addfile(info)
                with self.assertRaisesRegex(MODULE.ArchiveValidationError, "unsafe path|unsupported entry"):
                    MODULE.extract_archive_tar(tar_path, root / "output" / "cmux-pr-demo.xcarchive")

    def test_rejects_identity_mismatch_without_mutation(self) -> None:
        archive, app = make_archive(self.tmp_path)
        with (app / "Info.plist").open("rb") as handle:
            app_info = plistlib.load(handle)
        app_info["CFBundleIdentifier"] = "com.example.attacker"
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(app_info, handle)

        with self.assertRaisesRegex(MODULE.ArchiveValidationError, "bundle identifier"):
            restamp(archive)

        with (archive / "Info.plist").open("rb") as handle:
            archive_info = plistlib.load(handle)
        self.assertEqual(archive_info["ApplicationProperties"]["CFBundleVersion"], "10")

    def test_rejects_archive_with_lost_executable_permission(self) -> None:
        archive, app = make_archive(self.tmp_path)
        (app / "cmux").chmod(0o644)

        with self.assertRaisesRegex(MODULE.ArchiveValidationError, "executable regular file"):
            restamp(archive)

    def test_rejects_symbolic_links(self) -> None:
        archive, app = make_archive(self.tmp_path)
        (app / "escape").symlink_to(self.tmp_path / "outside")

        with self.assertRaisesRegex(MODULE.ArchiveValidationError, "symbolic link"):
            restamp(archive)

    def test_rejects_nested_payload_directories(self) -> None:
        for nested in ("PlugIns", "Watch", "AppClips"):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as temporary:
                archive, app = make_archive(Path(temporary))
                (app / nested).mkdir()
                with self.assertRaisesRegex(MODULE.ArchiveValidationError, "nested payload"):
                    restamp(archive)

    def test_rejects_mismatched_initial_build_metadata(self) -> None:
        archive, _ = make_archive(self.tmp_path)
        with (archive / "Info.plist").open("rb") as handle:
            archive_info = plistlib.load(handle)
        archive_info["ApplicationProperties"]["CFBundleVersion"] = "11"
        with (archive / "Info.plist").open("wb") as handle:
            plistlib.dump(archive_info, handle)

        with self.assertRaisesRegex(MODULE.ArchiveValidationError, "same positive numeric"):
            restamp(archive)

    def test_rejects_non_numeric_or_zero_build_numbers(self) -> None:
        archive, _ = make_archive(self.tmp_path)

        for build_number in ("0", "1.2", "abc", "1" * 19):
            with self.subTest(build_number=build_number):
                with self.assertRaisesRegex(MODULE.ArchiveValidationError, "positive integer"):
                    restamp(archive, build_number)


if __name__ == "__main__":
    unittest.main()
