#!/usr/bin/env python3
"""The release asset mirror reads the mirror first, waits out a broken upstream, and never lands bad bytes.

Network-free: every fetch here talks to a local http.server standing in for the mirror, the upstream and
the release-assets API.
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "release_asset_mirror.py"
sys.path.insert(0, str(SCRIPT.parent))
import release_asset_mirror as mirror  # noqa: E402

ASSET = b"release asset bytes\n" * 1000
ASSET_SHA = hashlib.sha256(ASSET).hexdigest()


class Server:
    """Answers each path with a queue of (status, body); the last answer repeats. Records every request."""

    def __init__(self):
        self.routes: dict[str, list[tuple[int, bytes]]] = {}
        self.requests: list[tuple[str, dict]] = []
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                path = urllib.parse.urlsplit(self.path).path
                server.requests.append((path, dict(self.headers)))
                answers = server.routes.get(path) or [(404, b"missing")]
                status, body = answers.pop(0) if len(answers) > 1 else answers[0]
                if status in (301, 302):
                    self.send_response(status)
                    self.send_header("Location", body.decode())
                    self.end_headers()
                    return
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def paths(self) -> list[str]:
        return [path for path, _ in self.requests]


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.addCleanup(self.server.close)
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.work)]))
        self.out = self.work / "out" / "asset.zip"
        self.env = mock.patch.dict(os.environ, {"CMUX_RELEASE_MIRROR_URL": self.server.url + "/m"}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        for name in ("CMUX_RELEASE_MIRROR", "CMUX_RELEASE_UPSTREAM", "GH_TOKEN", "GITHUB_TOKEN",
                     "CMUX_RELEASE_FETCH_DEADLINE"):
            os.environ.pop(name, None)
        self.sleeps: list[float] = []
        self.upstream = self.server.url + "/up/asset.zip"

    def object_path(self, sha=ASSET_SHA):
        return f"/m/release-assets/v1/sha256/{sha}"

    def fetch(self, url=None, sha=ASSET_SHA, deadline=100.0, **kwargs):
        return mirror.fetch(url or self.upstream, sha, self.out, deadline, sleep=self.sleeps.append, **kwargs)

    def assert_nothing_landed(self):
        self.assertFalse(self.out.exists())
        self.assertEqual([p.name for p in self.out.parent.iterdir()] if self.out.parent.exists() else [], [])



class FetchTest(ServerCase):
    def test_mirror_hit_never_touches_upstream(self):
        self.server.routes[self.object_path()] = [(200, ASSET)]
        self.assertEqual(self.fetch(), "mirror")
        self.assertEqual(self.out.read_bytes(), ASSET)
        self.assertNotIn("/up/asset.zip", self.server.paths())

    def test_mirror_miss_falls_through_to_upstream(self):
        self.server.routes["/up/asset.zip"] = [(200, ASSET)]
        self.assertEqual(self.fetch(), "upstream")
        self.assertEqual(self.server.paths(), [self.object_path(), "/up/asset.zip"])
        self.assertEqual(self.out.read_bytes(), ASSET)

    def test_upstream_504_waits_and_succeeds_within_the_deadline(self):
        self.server.routes["/up/asset.zip"] = [(504, b"gateway"), (503, b"busy"), (200, ASSET)]
        self.assertEqual(self.fetch(), "upstream")
        self.assertEqual(len(self.sleeps), 2)
        # 5 s doubling, with up to 20% jitter either way.
        self.assertTrue(4 <= self.sleeps[0] <= 6 and 8 <= self.sleeps[1] <= 12, self.sleeps)
        self.assertEqual(self.out.read_bytes(), ASSET)

    def test_backoff_caps_at_sixty_seconds(self):
        self.server.routes["/up/asset.zip"] = [(504, b"")] * 8 + [(200, ASSET)]
        clock = iter(range(0, 10_000, 1))
        self.assertEqual(self.fetch(deadline=5000, clock=lambda: next(clock)), "upstream")
        self.assertLessEqual(max(self.sleeps), 72)
        self.assertGreaterEqual(max(self.sleeps), 48)

    def test_deadline_exceeded_fails_with_a_next_line(self):
        self.server.routes["/up/asset.zip"] = [(504, b"gateway")]
        with self.assertRaises(mirror.FetchError) as raised:
            self.fetch(deadline=20)
        message = str(raised.exception)
        self.assertEqual(raised.exception.kind, "unavailable")
        self.assertIn("HTTP 504", message)
        self.assertTrue(message.splitlines()[-1].startswith("next:"), message)
        self.assertGreaterEqual(len(self.sleeps), 1)
        self.assert_nothing_landed()

    def test_deadline_zero_is_one_round(self):
        with self.assertRaises(mirror.FetchError):
            self.fetch(deadline=0, upstream=False)
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.server.paths(), [self.object_path()])

    def test_checksum_mismatch_never_lands(self):
        self.server.routes[self.object_path()] = [(200, b"tampered mirror copy")]
        self.server.routes["/up/asset.zip"] = [(200, b"tampered upstream copy")]
        with self.assertRaises(mirror.FetchError) as raised:
            self.fetch()
        self.assertEqual(raised.exception.kind, "definitive")
        self.assertEqual(len(self.sleeps), mirror.DEFINITIVE_ROUNDS - 1)
        self.assert_nothing_landed()

    def test_bad_mirror_copy_falls_through_to_good_upstream(self):
        self.server.routes[self.object_path()] = [(200, b"tampered mirror copy")]
        self.server.routes["/up/asset.zip"] = [(200, ASSET)]
        self.assertEqual(self.fetch(), "upstream")
        self.assertEqual(self.out.read_bytes(), ASSET)

    def test_existing_output_is_replaced_only_by_verified_bytes(self):
        self.out.parent.mkdir(parents=True)
        self.out.write_bytes(b"previous")
        self.server.routes["/up/asset.zip"] = [(200, b"wrong")]
        with self.assertRaises(mirror.FetchError):
            self.fetch(deadline=0)
        self.assertEqual(self.out.read_bytes(), b"previous")
        self.assertEqual(sorted(p.name for p in self.out.parent.iterdir()), ["asset.zip"])

    def test_upstream_off_simulates_github_down(self):
        self.server.routes["/up/asset.zip"] = [(200, ASSET)]
        with mock.patch.dict(os.environ, {"CMUX_RELEASE_UPSTREAM": "off"}):
            with self.assertRaises(mirror.FetchError):
                self.fetch(deadline=0)
            self.server.routes[self.object_path()] = [(200, ASSET)]
            self.assertEqual(self.fetch(deadline=0), "mirror")
        self.assertNotIn("/up/asset.zip", self.server.paths())

    def test_mirror_off_goes_straight_upstream(self):
        self.server.routes[self.object_path()] = [(200, ASSET)]
        self.server.routes["/up/asset.zip"] = [(200, ASSET)]
        with mock.patch.dict(os.environ, {"CMUX_RELEASE_MIRROR": "off"}):
            self.assertEqual(self.fetch(), "upstream")
        self.assertEqual(self.server.paths(), ["/up/asset.zip"])

    def test_both_off_is_a_config_error(self):
        with mock.patch.dict(os.environ, {"CMUX_RELEASE_MIRROR": "off", "CMUX_RELEASE_UPSTREAM": "off"}):
            with self.assertRaises(mirror.FetchError) as raised:
                self.fetch()
        self.assertEqual(raised.exception.kind, "config")
        self.assertEqual(self.server.requests, [])

    def test_from_index_reads_index_then_object(self):
        index = "/m/" + mirror.index_key(self.upstream)
        self.server.routes[index] = [(200, (ASSET_SHA + "\n").encode())]
        self.server.routes[self.object_path()] = [(200, ASSET)]
        self.assertEqual(self.fetch(sha=None), "mirror")
        self.assertEqual(self.server.paths(), [index, self.object_path()])

    def test_from_index_verifies_against_the_index(self):
        index = "/m/" + mirror.index_key(self.upstream)
        self.server.routes[index] = [(200, (ASSET_SHA + "\n").encode())]
        self.server.routes[self.object_path()] = [(200, b"other bytes")]
        self.server.routes["/up/asset.zip"] = [(200, b"other bytes")]
        with self.assertRaises(mirror.FetchError):
            self.fetch(sha=None)
        self.assert_nothing_landed()

    def test_from_index_without_an_entry_fails_at_once(self):
        with self.assertRaises(mirror.FetchError) as raised:
            self.fetch(sha=None)
        self.assertEqual(raised.exception.kind, "no-index")
        self.assertIn("next:", str(raised.exception))
        self.assertEqual(self.sleeps, [])

    def test_index_key_is_the_sha256_of_the_exact_url(self):
        url = "https://github.com/o/r/releases/download/t/a.zip"
        self.assertEqual(mirror.index_key(url),
                         "release-assets/v1/url/" + hashlib.sha256(url.encode("utf-8")).hexdigest())

    def test_api_fallback_and_token_only_to_the_api(self):
        """github.com and api.github.com are routed to the local server; the token goes to the API only."""
        url = "https://github.com/o/r/releases/download/v1/asset.zip"
        self.server.routes["/gh/o/r/releases/download/v1/asset.zip"] = [(504, b"")]
        self.server.routes["/api/repos/o/r/releases/tags/v1"] = [(200, json.dumps({"assets": [
            {"name": "asset.zip", "url": "https://api.github.com/repos/o/r/releases/assets/7"}]}).encode())]
        self.server.routes["/api/repos/o/r/releases/assets/7"] = [(302, f"{self.server.url}/storage/blob".encode())]
        self.server.routes["/storage/blob"] = [(200, ASSET)]
        real_open = mirror._open

        def routed(request, timeout=mirror.CONNECT_TIMEOUT):
            full = request.full_url
            for prefix, local in (("https://api.github.com/", "/api/"), ("https://github.com/", "/gh/")):
                if full.startswith(prefix):
                    request.full_url = self.server.url + local + full[len(prefix):]
            return real_open(request, timeout)

        with mock.patch.object(mirror, "_open", routed), mock.patch.dict(os.environ, {"GH_TOKEN": "secret-token"}):
            self.assertEqual(self.fetch(url=url), "api")
        self.assertEqual(self.out.read_bytes(), ASSET)
        for path, headers in self.server.requests:
            sent = headers.get("Authorization")
            if path.startswith("/api/"):
                self.assertEqual(sent, "Bearer secret-token", path)
            else:
                self.assertIsNone(sent, path)

    def test_cli_failure_ends_with_next(self):
        env = {**os.environ, "CMUX_RELEASE_UPSTREAM": "off"}
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "fetch", self.upstream, "--sha256", ASSET_SHA,
                                 "--out", str(self.out), "--deadline", "0"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("release-asset: mirror miss asset.zip (HTTP 404)", result.stderr)
        self.assertTrue(result.stderr.strip().splitlines()[-1].startswith("next:"), result.stderr)

    def test_cli_success_logs_source_and_time(self):
        self.server.routes[self.object_path()] = [(200, ASSET)]
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "fetch", self.upstream, "--sha256", ASSET_SHA,
                                 "--out", str(self.out)], env=dict(os.environ), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stderr, r"release-asset: mirror hit asset\.zip \d+\.\ds")
        self.assertEqual(self.out.read_bytes(), ASSET)


class DownloaderTest(ServerCase):
    """A script with the mirror in front installs from it while the release host is down."""

    def test_install_actionlint_reads_the_mirror(self):
        build = self.work / "build"
        build.mkdir()
        (build / "actionlint").write_text("#!/bin/sh\nexit 0\n")
        (build / "actionlint").chmod(0o755)
        archive = self.work / "actionlint.tar.gz"
        subprocess.run(["tar", "-czf", str(archive), "-C", str(build), "actionlint"], check=True)
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.server.routes[self.object_path(sha)] = [(200, archive.read_bytes())]
        fake_bin = self.work / "bin"
        fake_bin.mkdir()
        (fake_bin / "curl").write_text("#!/bin/sh\necho 'curl: (22) 504' >&2\nexit 22\n")
        (fake_bin / "curl").chmod(0o755)
        runner_temp = self.work / "runner"
        runner_temp.mkdir()
        env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", "RUNNER_TEMP": str(runner_temp),
               "ACTIONLINT_VERSION": "1.7.7", "ACTIONLINT_SHA256": sha, "ACTIONLINT_ASSET_ID": "1",
               "CMUX_RELEASE_UPSTREAM": "off", "CMUX_RELEASE_FETCH_DEADLINE": "0"}
        result = subprocess.run(["bash", str(ROOT / "scripts/ci/install-actionlint.sh")], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], str(runner_temp / "actionlint"))
        self.assertIn("mirror hit actionlint_1.7.7_linux_amd64.tar.gz", result.stderr)


class ManifestTest(unittest.TestCase):
    def test_literal_binary_target(self):
        manifest = '''
        targets: [
            .binaryTarget(
                name: "GhosttyNextKit",
                url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-abc-apple-v6/GhosttyNextKit.xcframework.zip",
                checksum: "007A462B6E99A96A21CBFE4D37756164494B5337F9482D3C25FE14DA7CEC9B8A" // comment (with parens)
            ),
            .binaryTarget(name: "Local", path: "Local.xcframework"),
        ]'''
        self.assertEqual(mirror.binary_targets(manifest), [(
            "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-abc-apple-v6/"
            "GhosttyNextKit.xcframework.zip",
            "007a462b6e99a96a21cbfe4d37756164494b5337f9482d3c25fe14da7cec9b8a")])

    def test_terminal_client_shape(self):
        manifest = '''
let releaseRepository = "manaflow-ai/cmux"
let releaseTag = "cmux-terminal-client-v0.1.0+6ba5de550cd4"
let releaseChecksum = "ecda518668cb64ad54c25869dd0996fc99e63c738bfa5e176b2b524d78290681"
let ffiBinary: Target =
    useLocal
    ? .binaryTarget(name: "CmuxTerminalClientFFI", path: "CmuxTerminalClient.xcframework")
    : .binaryTarget(
        name: "CmuxTerminalClientFFI",
        url:
            "https://github.com/\\(releaseRepository)/releases/download/\\(releaseTag)/CmuxTerminalClient.xcframework.zip",
        checksum: releaseChecksum)
'''
        self.assertEqual(mirror.binary_targets(manifest), [(
            "https://github.com/manaflow-ai/cmux/releases/download/cmux-terminal-client-v0.1.0+6ba5de550cd4/"
            "CmuxTerminalClient.xcframework.zip",
            "ecda518668cb64ad54c25869dd0996fc99e63c738bfa5e176b2b524d78290681")])

    def test_values_computed_at_evaluation_are_skipped(self):
        manifest = '''
let tag = ProcessInfo.processInfo.environment["TAG"] ?? "x"
.binaryTarget(name: "A", url: "https://example.com/\\(tag)/a.zip", checksum: "%s")
.binaryTarget(name: "B", url: makeURL(), checksum: "%s")
''' % ("a" * 64, "b" * 64)
        self.assertEqual(mirror.binary_targets(manifest), [])

    def test_every_tracked_manifest_with_a_remote_binary_target_parses(self):
        """A manifest on this tree that names a release URL and is not understood would silently go unmirrored."""
        listed = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True).stdout
        for path in listed.splitlines():
            if mirror.MANIFEST.search(path) and (ROOT / path).is_file():
                text = (ROOT / path).read_text(encoding="utf-8")
                remote = len(re.findall(r"\.binaryTarget\s*\([^)]*?\burl\s*:", text, re.S))
                if remote:
                    self.assertEqual(len(mirror.binary_targets(text)), remote, path)

    def test_resolved_pins_all_formats(self):
        v2 = {"pins": [
            {"location": "https://github.com/getsentry/sentry-cocoa.git", "state": {"revision": "a" * 40}},
            {"location": "https://gitlab.com/x/y", "state": {"revision": "b" * 40}},
            {"location": "https://github.com/o/r", "state": {"branch": "main"}},
        ]}
        v1 = {"object": {"pins": [{"repositoryURL": "https://github.com/o/r", "state": {"revision": "c" * 40}}]}}
        self.assertEqual(mirror.resolved_pins(json.dumps(v2)), [("getsentry", "sentry-cocoa", "a" * 40)])
        self.assertEqual(mirror.resolved_pins(json.dumps(v1)), [("o", "r", "c" * 40)])
        self.assertEqual(mirror.resolved_pins("not json"), [])


def lock_pairs() -> set[tuple[str, str]]:
    return {(p.url, p.sha256) for p in mirror.parse_lock(mirror.LOCK_FILE.read_text(encoding="utf-8"))}


def assignment(text: str, name: str) -> str:
    match = re.search(rf'\b{name}\s*[:=]\s*"?([^"\s]+)"?', text)
    assert match, f"no {name}"
    return match.group(1)


class LockTest(unittest.TestCase):
    def test_parse(self):
        pairs = mirror.parse_lock("# header\n\nhttps://e.com/a.zip %s  # trailing\n" % ("a" * 64))
        self.assertEqual([(p.url, p.sha256, p.pinned) for p in pairs], [("https://e.com/a.zip", "a" * 64, True)])
        for bad in ("https://e.com/a.zip", "http://e.com/a.zip " + "a" * 64, "https://e.com/a.zip " + "A" * 64,
                    "https://e.com/a.zip %s extra" % ("a" * 64)):
            with self.assertRaises(ValueError):
                mirror.parse_lock(bad)

    def test_lock_matches_each_source_script_on_this_tree(self):
        lock = lock_pairs()
        read = lambda relative: (ROOT / relative).read_text(encoding="utf-8")  # noqa: E731

        sentry = read("scripts/ensure-sentry-cli.sh")
        expected = {(f"https://github.com/getsentry/sentry-cli/releases/download/{assignment(sentry, 'SENTRY_CLI_VERSION')}/"
                     f"{assignment(sentry, 'SENTRY_CLI_ASSET')}", assignment(sentry, "SENTRY_CLI_SHA256"))}

        sparkle = read("scripts/sparkle_generate_appcast.sh")
        version = re.search(r'SPARKLE_VERSION="\$\{SPARKLE_VERSION:-([0-9.]+)\}"', sparkle).group(1)
        expected.add((f"https://github.com/sparkle-project/Sparkle/releases/download/{version}/Sparkle-{version}.tar.xz",
                      assignment(sparkle, "SPARKLE_281_TARBALL_SHA256")))

        guards = read(".github/workflows/ci-guards.yml")
        version = assignment(guards, "ACTIONLINT_VERSION")
        self.assertIn('releases/download/v${ACTIONLINT_VERSION}/${asset_name}', read("scripts/ci/install-actionlint.sh"))
        expected.add((f"https://github.com/rhysd/actionlint/releases/download/v{version}/"
                      f"actionlint_{version}_linux_amd64.tar.gz", assignment(guards, "ACTIONLINT_SHA256")))

        rcodesign = read("scripts/ci/install-rcodesign.sh")
        version = assignment(rcodesign, "RCODESIGN_VERSION")
        expected.add((f"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/{version}/"
                      f"apple-codesign-{version}-x86_64-unknown-linux-musl.tar.gz",
                      assignment(rcodesign, "RCODESIGN_SHA256")))

        macos = read(".github/workflows/ci-macos.yml")
        version = assignment(macos, "NU_VERSION")
        for arch, sha in re.findall(r'NU_ARCH="([^"]+)"\s+NU_SHA256="([0-9a-f]{64})"', macos):
            expected.add((f"https://github.com/nushell/nushell/releases/download/{version}/nu-{version}-{arch}.tar.gz",
                          sha))
        self.assertEqual(sum(1 for url, _ in expected if "nushell" in url), 2)

        warmup = read(".github/workflows/cmux-tui-testbox-warmup.yml")
        version = assignment(warmup, "NEXTEST_VERSION")
        expected.add((f"https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-{version}/"
                      f"cargo-nextest-{version}-x86_64-unknown-linux-gnu.tar.gz", assignment(warmup, "NEXTEST_SHA256")))

        self.assertEqual(expected - lock, set(), "scripts/ci/release-assets.lock is behind these pins")

    def test_lock_matches_feat_cmux_next_when_it_is_fetched(self):
        def show(path: str) -> str | None:
            result = subprocess.run(["git", "-C", str(ROOT), "show", f"origin/feat-cmux-next:{path}"],
                                    capture_output=True, text=True)
            return result.stdout if result.returncode == 0 else None

        tools = show("scripts/cmux-next/lint-tools.lock")
        if tools is None:
            self.skipTest("origin/feat-cmux-next is not fetched here")
        expected = set()
        for line in tools.splitlines():
            fields = line.split("\t")
            if not line.startswith("#") and len(fields) >= 5:
                expected.add((fields[3], fields[4]))
        sim = show("scripts/ci/cmux-next-ios-sim.sh") or ""
        if "xcodegen_version=" in sim:
            version = assignment(sim, "xcodegen_version")
            expected.add((f"https://github.com/yonaskolb/XcodeGen/releases/download/{version}/xcodegen.zip",
                          assignment(sim, "xcodegen_sha256")))
        self.assertEqual(expected - lock_pairs(), set())


class FakeStore:
    def __init__(self, objects=None, corrupt_readback=False, put_status=200):
        self.objects: dict[str, bytes] = dict(objects or {})
        self.corrupt_readback = corrupt_readback
        self.put_status = put_status
        self.calls: list[tuple[str, str]] = []

    def head(self, key):
        self.calls.append(("HEAD", key))
        return 200 if key in self.objects else 404

    def put(self, key, path, content_type):
        self.calls.append(("PUT", key))
        if key in self.objects:
            return 412
        if self.put_status == 200:
            self.objects[key] = Path(path).read_bytes()
        return self.put_status

    def get(self, key, path):
        self.calls.append(("GET", key))
        if key not in self.objects:
            return 404
        body = self.objects[key]
        Path(path).write_bytes(b"corrupt" if self.corrupt_readback and "/sha256/" in key else body)
        return 200


class FillTest(unittest.TestCase):
    def setUp(self):
        self.pair = mirror.Pair("https://example.invalid/asset.zip", ASSET_SHA, "test")

    def run_fill(self, store, fetched=ASSET, error=None):
        def fake_fetch(url, sha, out, deadline, **kwargs):
            self.assertEqual(kwargs, {"mirror": False, "upstream": True})
            if error:
                raise error
            Path(out).write_bytes(fetched)
            return "upstream"

        with mock.patch.object(mirror, "fetch", fake_fetch):
            return mirror.fill([self.pair], store, deadline=1, budget=100, workers=1)

    def test_missing_object_is_uploaded_verified_then_indexed(self):
        store = FakeStore()
        results = self.run_fill(store)
        self.assertEqual(list(results), ["mirrored"])
        index = mirror.index_key(self.pair.url)
        self.assertEqual(store.objects[mirror.object_key(ASSET_SHA)], ASSET)
        self.assertEqual(store.objects[index], (ASSET_SHA + "\n").encode())
        order = [call for call in store.calls if call[0] in ("PUT", "GET")]
        self.assertEqual(order[:2], [("PUT", mirror.object_key(ASSET_SHA)), ("GET", mirror.object_key(ASSET_SHA))])
        self.assertEqual(order[2], ("PUT", index))
        self.assertEqual(mirror.fatal(results), [])

    def test_present_object_only_gets_its_index(self):
        store = FakeStore({mirror.object_key(ASSET_SHA): ASSET})
        results = self.run_fill(store, error=AssertionError("must not download"))
        self.assertEqual(list(results), ["present"])
        self.assertIn(mirror.index_key(self.pair.url), store.objects)

    def test_bad_read_back_writes_no_index(self):
        store = FakeStore(corrupt_readback=True)
        results = self.run_fill(store)
        self.assertEqual(list(results), ["storage"])
        self.assertNotIn(mirror.index_key(self.pair.url), store.objects)
        self.assertEqual(len(mirror.fatal(results)), 1)

    def test_unavailable_upstream_does_not_fail_the_run(self):
        store = FakeStore()
        results = self.run_fill(store, error=mirror.FetchError("down\nnext: wait", "unavailable"))
        self.assertEqual(list(results), ["unavailable"])
        self.assertEqual(mirror.fatal(results), [])
        self.assertEqual([c for c in store.calls if c[0] == "PUT"], [])

    def test_wrong_bytes_upstream_fail_a_pinned_pair_but_not_a_scanned_one(self):
        error = mirror.FetchError("other bytes\nnext: check", "definitive")
        self.assertEqual(len(mirror.fatal(self.run_fill(FakeStore(), error=error))), 1)
        self.pair = mirror.Pair(self.pair.url, ASSET_SHA, "scan", pinned=False)
        self.assertEqual(mirror.fatal(self.run_fill(FakeStore(), error=error)), [])

    def test_index_naming_other_bytes_is_left_alone(self):
        index = mirror.index_key(self.pair.url)
        store = FakeStore({mirror.object_key(ASSET_SHA): ASSET, index: b"f" * 64 + b"\n"})
        results = self.run_fill(store)
        self.assertEqual(store.objects[index], b"f" * 64 + b"\n")
        self.assertEqual(results["present"][0][1], "index names other bytes")


class LayoutTest(unittest.TestCase):
    def test_prune_never_reaches_the_mirror_prefix(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import r2_cache_prune
        for key in (mirror.object_key(ASSET_SHA), mirror.index_key("https://e.com/a.zip")):
            self.assertIsNone(r2_cache_prune.ARCHIVE.match(key))
            self.assertIsNone(r2_cache_prune.POINTER.match(key))


if __name__ == "__main__":
    unittest.main()
