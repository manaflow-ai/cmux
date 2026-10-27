#!/usr/bin/env python3
"""The cmux NEXT Nightly app's whole-product reuse (scripts/ci/nightly_release_product_reuse.py).

The key and the record namespace are tests/test_nightly_release_product_key.py.

- The products round-trip with their symlinks; an archive that could write outside the products
  directory, or an app without its optional engine, is refused.
- nightly.yml passes every decide output its skipped steps read into the key.
"""

from __future__ import annotations

import io
import re
import sys
import tarfile
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))
import dev_release_product_reuse as reuse  # noqa: E402
import job_input_fingerprint as fingerprint  # noqa: E402
from test_dev_release_product_key import git  # noqa: E402
import nightly_release_product_reuse as nightly  # noqa: E402


def make_app(products: Path, engine: bool = True) -> None:
    app = products / "cmux.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Info.plist").write_text("<plist/>")
    (app / "MacOS/cmux").write_bytes(b"\xcf\xfa\xed\xfe binary")
    (app / "MacOS/cmux").chmod(0o755)
    if engine:
        framework = app / "Frameworks/Chromium Embedded Framework.framework"
        (framework / "Versions/A").mkdir(parents=True)
        (framework / "Versions/A/Chromium Embedded Framework").write_bytes(b"engine")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Chromium Embedded Framework").symlink_to("Versions/Current/Chromium Embedded Framework")
        (app / "Helpers/cmux-remote-browser-host.app/Contents").mkdir(parents=True)
    dsym = products / "cmux.app.dSYM/Contents/Resources/DWARF"
    dsym.mkdir(parents=True)
    (dsym / "cmux").write_bytes(b"dwarf")
    (products / "PackageFrameworks/Foo.framework.dSYM").mkdir(parents=True)
    (products / "Other.swiftmodule").mkdir()


class Products(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_app_and_its_dsyms_round_trip(self):
        make_app(self.dir / "built")
        out = nightly.pack(self.dir / "built", self.dir / "p.tar.gz")
        self.assertTrue(out["archive"], out)
        with tarfile.open(out["archive"]) as archive:
            tops = {name.split("/")[0] for name in archive.getnames()}
        self.assertEqual(tops, {"cmux.app", "cmux.app.dSYM", "PackageFrameworks"})
        target = self.dir / "restored"
        nightly.unpack(Path(out["archive"]), target)
        framework = target / "cmux.app/Contents/Frameworks/Chromium Embedded Framework.framework"
        self.assertTrue((framework / "Versions/Current").is_symlink())
        self.assertEqual((framework / "Chromium Embedded Framework").read_bytes(), b"engine")
        self.assertTrue((target / "cmux.app/Contents/MacOS/cmux").stat().st_mode & 0o100)
        self.assertTrue((target / "cmux.app.dSYM/Contents/Resources/DWARF/cmux").is_file())
        self.assertFalse((target / "Other.swiftmodule").exists())

    def test_hard_linked_files_pack_as_plain_files(self):
        make_app(self.dir / "built")
        binary = self.dir / "built/cmux.app/Contents/MacOS/cmux"
        (binary.parent / "cmux-copy").hardlink_to(binary) if hasattr(Path, "hardlink_to") else \
            __import__("os").link(binary, binary.parent / "cmux-copy")
        out = nightly.pack(self.dir / "built", self.dir / "p.tar.gz")
        with tarfile.open(out["archive"]) as archive:
            self.assertFalse(any(member.islnk() for member in archive.getmembers()))
        nightly.unpack(Path(out["archive"]), self.dir / "restored")
        self.assertEqual((self.dir / "restored/cmux.app/Contents/MacOS/cmux-copy").read_bytes(), binary.read_bytes())

    def test_an_app_without_its_optional_engine_is_never_recorded(self):
        make_app(self.dir / "built", engine=False)
        out = nightly.pack(self.dir / "built", self.dir / "p.tar.gz")
        self.assertEqual(out["archive"], "")
        self.assertIn("Chromium Embedded Framework", out["reason"])

    def evil(self, member: tarfile.TarInfo, data: bytes = b"x") -> Path:
        path = self.dir / "evil.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            info = tarfile.TarInfo("cmux.app/Contents/Info.plist")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
            if member.isfile():
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            else:
                archive.addfile(member)
        return path

    def test_an_archive_that_escapes_the_products_directory_is_refused(self):
        link = tarfile.TarInfo("cmux.app/Contents/escape")
        link.type, link.linkname = tarfile.SYMTYPE, "../../../outside"
        absolute = tarfile.TarInfo("cmux.app/Contents/abs")
        absolute.type, absolute.linkname = tarfile.SYMTYPE, "/etc/passwd"
        hard = tarfile.TarInfo("cmux.app/Contents/hard")
        hard.type, hard.linkname = tarfile.LNKTYPE, "cmux.app/Contents/Info.plist"
        for member in (tarfile.TarInfo("../outside"), tarfile.TarInfo("/tmp/outside"),
                       tarfile.TarInfo("stray.txt"), link, absolute, hard):
            with self.subTest(member=member.name):
                target = self.dir / "restored"
                with self.assertRaises(reuse.Miss):
                    nightly.unpack(self.evil(member), target)
                self.assertFalse(target.exists() and any(target.iterdir()))
                self.assertEqual([p.name for p in self.dir.iterdir() if p.name.startswith(".restored")], [])

    def tar_of(self, *members: tuple) -> Path:
        path = self.dir / "crafted.tar.gz"
        with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("cmux.app/Contents/Info.plist")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
            for name, link, pax in members:
                member = tarfile.TarInfo(name)
                if pax:
                    member.pax_headers = pax
                if link is None:
                    member.size = 1
                    archive.addfile(member, io.BytesIO(b"x"))
                else:
                    member.type, member.linkname = tarfile.SYMTYPE, link
                    archive.addfile(member)
        return path

    def test_a_symlink_chain_or_a_member_under_a_symlink_is_refused(self):
        cases = {
            "chain": [("cmux.app/Contents/a", ".", None), ("cmux.app/Contents/b", "a/../../..", None)],
            "through a link": [("cmux.app/Contents/a", ".", None), ("cmux.app/Contents/a/payload", None, None)],
            "loop": [("cmux.app/Contents/a", "b", None), ("cmux.app/Contents/b", "a", None)],
            # On a case-insensitive volume A is a, so b leads three levels up and B/payload follows it;
            # the checks fold case, so a case-sensitive Linux runner refuses it too.
            "mixed case": [("cmux.app/Contents/a", ".", None), ("cmux.app/Contents/b", "A/../../..", None),
                           ("cmux.app/Contents/B/payload", None, None)],
            "duplicate": [("cmux.app/Contents/x", None, None), ("cmux.app/Contents/x", None, None)],
            "duplicate but for case": [("cmux.app/Contents/x", None, None), ("cmux.app/Contents/X", None, None)],
            # APFS also ignores Unicode normalization: é (one code point) and e + U+0301 are one name.
            "duplicate but for normalization": [("cmux.app/Contents/\u00e9", None, None),
                                                ("cmux.app/Contents/e\u0301", None, None)],
            "loops but for normalization": [("cmux.app/Contents/\u00e9", "e\u0301", None)],
            # Exactly named, a loops (a -> B/../a, and B is no link); folded, B is b and the walk
            # ends inside. Both walks run, so it is refused.
            "loops only by exact name": [("cmux.app/Contents/deep/deeper/f", None, None),
                                         ("cmux.app/Contents/a", "B/../a", None),
                                         ("cmux.app/Contents/b", "deep/deeper", None)],
            "huge pax header": [("cmux.app/Contents/y", None, {"comment": "z" * (nightly.MAX_EXTENSION_HEADER_BYTES + 1)})],
        }
        for index, (label, members) in enumerate(cases.items()):
            with self.subTest(case=label):
                target = self.dir / f"restored-{index}"
                with self.assertRaises(reuse.Miss):
                    nightly.unpack(self.tar_of(*members), target)
                self.assertFalse(target.exists() and any(target.iterdir()))
        # A link inside the app that stays inside it is kept.
        target = self.dir / "fine"
        nightly.unpack(self.tar_of(("cmux.app/Contents/Versions/A", None, None),
                                   ("cmux.app/Contents/Current", "Versions/A", None)), target)
        self.assertTrue((target / "cmux.app/Contents/Current").is_symlink())

    def test_a_symlinked_app_or_an_oversized_archive_is_refused(self):
        path = self.dir / "link.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            link = tarfile.TarInfo("cmux.app")
            link.type, link.linkname = tarfile.SYMTYPE, "cmux.app.dSYM"
            archive.addfile(link)
        with self.assertRaises(reuse.Miss):
            nightly.unpack(path, self.dir / "restored")
        make_app(self.dir / "built")
        out = nightly.pack(self.dir / "built", self.dir / "p.tar.gz")
        for bound, value in (("MAX_MEMBERS", 3), ("MAX_EXPANDED_BYTES", 4)):
            with self.subTest(bound=bound), unittest.mock.patch.object(nightly, bound, value):
                with self.assertRaises(reuse.Miss):
                    nightly.unpack(Path(out["archive"]), self.dir / "restored")
                self.assertFalse((self.dir / "restored").exists() and any((self.dir / "restored").iterdir()))

    def test_unpack_never_writes_over_a_build(self):
        make_app(self.dir / "built")
        out = nightly.pack(self.dir / "built", self.dir / "p.tar.gz")
        with self.assertRaises(reuse.Miss):
            nightly.unpack(Path(out["archive"]), self.dir / "built")


class RunningWorkflow(unittest.TestCase):
    """The key reads nightly.yml from the build commit; the steps run from the workflow commit."""

    def test_a_build_of_an_older_commit_with_another_nightly_yml_never_reuses(self):
        import os
        import shutil
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q")
            (repo / "scripts/ci").mkdir(parents=True)
            shutil.copy(ROOT / "scripts/ci/nightly-release-product.sh", repo / "scripts/ci/")
            (repo / ".github/workflows").mkdir(parents=True)
            (repo / ".github/workflows/nightly.yml").write_text("old\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-q", "-m", "build commit")
            build = git(repo, "rev-parse", "HEAD").strip()
            (repo / ".github/workflows/nightly.yml").write_text("new\n")
            git(repo, "commit", "-q", "-am", "workflow commit")
            workflow = git(repo, "rev-parse", "HEAD").strip()
            git(repo, "checkout", "-q", build)
            env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_WORKFLOW_SHA", "GH_TOKEN", "GITHUB_TOKEN")}
            # Another blob, a commit nobody has, and no workflow commit at all: each is a miss.
            for sha in (workflow, "f" * 40, None):
                with self.subTest(workflow_sha=sha):
                    products = repo / "build-universal/Build/Products/Release"
                    (products / "cmux.app").mkdir(parents=True, exist_ok=True)
                    run_env = {**env, "RUNNER_TEMP": tmp, **({"GITHUB_WORKFLOW_SHA": sha} if sha else {})}
                    out = subprocess.run(["bash", str(repo / "scripts/ci/nightly-release-product.sh"), "lookup"],
                                         capture_output=True, text=True, env=run_env, cwd=repo)
                    self.assertEqual(out.returncode, 0, out.stderr)
                    self.assertIn("key=\n", out.stdout)
                    self.assertIn("hit=false", out.stdout)
                    # A miss never leaves a products directory for xcodebuild to merge into.
                    self.assertFalse(products.exists())


class Workflow(unittest.TestCase):
    def setUp(self):
        text = (ROOT / ".github/workflows/nightly.yml").read_text()
        self.job = text[text.index("\n  build-nightly-app:\n"):text.index("\n  resolve-nightly-cmux-tui-client:\n")]
        self.lookup = self.job[self.job.index("id: nightly-product\n"):self.job.index("      - name: Compute Xcode compilation cache key")]

    def steps(self) -> list[str]:
        return re.split(r"\n(?=      - name: )", self.job)

    def test_every_decide_flag_reaches_the_key(self):
        for name in fingerprint.NIGHTLY_PRODUCT_FLAGS:
            with self.subTest(flag=name):
                self.assertIn(f"NIGHTLY_PRODUCT_{name.upper()}: ${{{{ needs.decide.outputs.{name} }}}}", self.lookup)

    def test_skipped_steps_read_no_unkeyed_decide_output(self):
        condition = self.lookup.splitlines()[1]
        # The lookup runs only for push builds that are not fast, build-only or notary tests.
        for excluded in ("fast_build", "build_only", "notary_test", "notary_probe"):
            self.assertIn(f"needs.decide.outputs.{excluded} != 'true'", condition)
        self.assertIn("github.event_name == 'push'", condition)
        self.assertIn("github.ref == 'refs/heads/nightly-next'", condition)
        allowed = set(fingerprint.NIGHTLY_PRODUCT_FLAGS) | {"fast_build", "build_only", "should_publish"}
        skipped = [step for step in self.steps() if "steps.nightly-product.outputs.hit != 'true'" in step]
        self.assertGreaterEqual(len(skipped), 15)
        for step in skipped:
            for output in re.findall(r"needs\.decide\.outputs\.([a-z_]+)", step):
                with self.subTest(step=step.splitlines()[0].strip(), output=output):
                    self.assertIn(output, allowed)
            # A repository variable in a skipped step would change the app without changing the key.
            with self.subTest(step=step.splitlines()[0].strip()):
                self.assertEqual(re.findall(r"vars\.[A-Z0-9_]+", step), [])

    def test_the_xcodebuild_step_is_skipped_on_a_hit(self):
        build = next(step for step in self.steps() if step.startswith("      - name: Build nightly app (Release)"))
        self.assertIn("steps.nightly-product.outputs.hit != 'true'", build.splitlines()[1])

    def test_only_nightly_yml_uses_the_nightly_lane(self):
        for workflow in (ROOT / ".github/workflows").glob("*.y*ml"):
            text = workflow.read_text()
            uses = "nightly-release-product.sh" in text or "cmux-nightly-next-release-product-" in text
            with self.subTest(workflow=workflow.name):
                self.assertEqual(uses, workflow.name == "nightly.yml")


if __name__ == "__main__":
    unittest.main()
