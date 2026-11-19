"""Tests for scripts/static-analysis/daily_findings.py: python3 -m unittest tests/test_static_analysis_daily_findings.py"""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "static-analysis"))
import daily_findings as nf  # noqa: E402


def deny_line(code, name, version="1.0.0", advisory=None, span="MIT", rejected=("MIT",)):
    fields = {"code": code, "severity": "error", "message": "m",
              "graphs": [{"Krate": {"name": name, "version": version}}],
              "labels": [{"span": span, "message": ""}] + [{"span": r, "message": "rejected: license is not explicitly allowed"} for r in rejected]}
    if advisory:
        fields["advisory"] = {"id": advisory, "title": "bad"}
    return json.dumps({"type": "diagnostic", "fields": fields})


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "cargo-deny").mkdir()
        (self.dir / "knip").mkdir()
        (self.dir / "osv-scanner.json").write_text(json.dumps({"results": [
            {"source": {"path": "/repo/cmux-tui/Cargo.lock"}, "packages": [
                {"package": {"ecosystem": "crates.io", "name": "idna", "version": "0.4.0"},
                 "groups": [{"ids": ["GHSA-h97m-ww89-6jmq", "RUSTSEC-2024-0421"], "max_severity": "5.3"}]}]},
            {"source": {"path": "/repo/coderouter/Cargo.lock"}, "packages": [
                {"package": {"ecosystem": "crates.io", "name": "idna", "version": "0.5.0"},
                 "groups": [{"ids": ["RUSTSEC-2024-0421", "GHSA-h97m-ww89-6jmq"]}]}]},
        ]}))
        (self.dir / "cargo-deny" / "cmux-tui.jsonl").write_text("\n".join([
            deny_line("vulnerability", "idna", advisory="RUSTSEC-2024-0421"),
            deny_line("rejected", "ring", span="ISC AND OpenSSL", rejected=("ISC", "OpenSSL")),
            deny_line("rejected", "serde", span="MIT OR Apache-2.0", rejected=("MIT", "Apache-2.0")),
            json.dumps({"type": "summary", "fields": {}}),
            "not json",
        ]))
        (self.dir / "cargo-machete.txt").write_text(
            "Analyzing dependencies of crates in this directory...\n"
            "cmux-foo -- ./cmux-tui/crates/cmux-foo/Cargo.toml:\n"
            "\tanyhow\n"
            "\tcmux-sdk  (not counted: lib name `cmux` is used; machete only knows the package name)\n")
        (self.dir / "knip" / "webviews.json").write_text(json.dumps({"issues": [
            {"file": "src/dead.ts", "files": [{"name": "src/dead.ts"}], "exports": [{"name": "x"}]},
            {"file": "package.json", "dependencies": [{"name": "left-pad", "line": 4}]},
        ]}))
        (self.dir / "knip" / "webviews.config.json").write_text("{}")
        (self.dir / "knip" / "web.json").write_text(json.dumps({"issues": [{"file": "a.ts", "files": [{"name": "a.ts"}]}]}))


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.tmp.cleanup)
        self.findings = nf.collect(self.fx.dir, "/repo")

    def test_keys(self):
        self.assertEqual(sorted(self.findings), [
            "advisory:crates.io:idna:RUSTSEC-2024-0421",
            "cargo-machete:./cmux-tui/crates/cmux-foo:anyhow",
            "knip:webviews:dependencies:package.json:left-pad",
            "knip:webviews:files:src/dead.ts",
            "license:ring:ISC AND OpenSSL",
            "license:serde:MIT OR Apache-2.0",
        ])

    def test_one_advisory_for_both_tools_and_both_lockfiles(self):
        f = self.findings["advisory:crates.io:idna:RUSTSEC-2024-0421"]
        self.assertEqual(f.tool, "osv-scanner")
        self.assertEqual(len(f.details), 3)  # two lockfiles from osv, one from cargo-deny
        self.assertIn("`cmux-tui/Cargo.lock`", f.details[0])

    def test_frozen_web_and_exports_are_not_filed(self):
        self.assertFalse(any(k.startswith("knip:web:") for k in self.findings))
        self.assertFalse(any(":exports:" in k for k in self.findings))


class DecideTests(unittest.TestCase):
    def test_rules(self):
        known = {"open": [(1, "open", "")], "wontfix": [(2, "closed", "not_planned")],
                 "done": [(3, "closed", "completed")], "dup": [(4, "closed", "duplicate")]}
        self.assertEqual(nf.decide("open", known), (False, None))
        self.assertEqual(nf.decide("wontfix", known), (False, None))
        self.assertEqual(nf.decide("dup", known), (False, None))
        self.assertEqual(nf.decide("done", known), (True, 3))
        self.assertEqual(nf.decide("new", known), (True, None))

    def test_body_carries_the_key(self):
        body = nf.issue_body(nf.Finding("k:1", "knip", "t", ["d"]), "u", "s", 7)
        self.assertEqual(nf.KEY_RE.findall(body), ["k:1"])
        self.assertIn("#7", body)


class FakeGitHub:
    def __init__(self, known):
        self.known, self.created = known, []

    def known_keys(self):
        return self.known

    def ensure_label(self):
        pass

    def create(self, title, body):
        self.created.append(nf.KEY_RE.findall(body)[0])
        return 100 + len(self.created)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.tmp.cleanup)

    def run_main(self, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = nf.main([str(self.fx.dir), "--root", "/repo", *args])
        return code, out.getvalue()

    def test_baseline_round_trip_files_nothing(self):
        base = self.fx.dir / "baseline.txt"
        self.run_main("--write-baseline", str(base))
        code, out = self.run_main("--baseline", str(base))
        self.assertEqual(code, 0)
        self.assertIn("new since the baseline: 0", out)

    def test_files_new_once_and_respects_max(self):
        fake = FakeGitHub({"license:serde:MIT OR Apache-2.0": [(9, "closed", "not_planned")]})
        with mock.patch.object(nf, "GitHub", lambda repo, token: fake), \
                mock.patch.dict("os.environ", {"GITHUB_TOKEN": "t"}):
            code, out = self.run_main("--file", "--max-new", "2")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.created), 2)
        self.assertNotIn("license:serde:MIT OR Apache-2.0", fake.created)
        self.assertIn("stop: filed 2", out)

    def test_deny_toml(self):
        text = nf.deny_toml(self.fx.dir, "2026-11-19")
        self.assertIn('"RUSTSEC-2024-0421"', text)
        self.assertIn('{ crate = "ring", allow = ["OpenSSL"] }', text)
        for lic in ('"ISC",', '"MIT",', '"Apache-2.0",'):
            self.assertIn(lic, text)
        if sys.version_info >= (3, 11):
            import tomllib
            data = tomllib.loads(text)
            self.assertEqual(data["advisories"]["ignore"][0]["id"], "RUSTSEC-2024-0421")


if __name__ == "__main__":
    unittest.main()
