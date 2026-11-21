from __future__ import annotations

import contextlib
import importlib.util
import hashlib
import os
import http.client
import urllib.error
import json
from pathlib import Path
import io
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
from unittest import TestCase, main
from unittest.mock import patch

import yaml


SCRIPT = Path(__file__).with_name("verify_published_manifest.py")
ROOT = SCRIPT.parents[2]
ARTIFACT_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
BUILD_PROFILES = ROOT / "scripts" / "cmux-next" / "cmux-tui-build-profiles.json"
WINDOWS_INSTALLER = ROOT / "web" / "public" / "tui" / "install-static.ps1"
SPEC = importlib.util.spec_from_file_location("verify_published_manifest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class FakeResponse:
    def __init__(self, body: dict[str, object]) -> None:
        self.body = json.dumps(body).encode("utf-8")
        self.headers: dict[str, str] = {}
        self._read = False

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, size: int = -1) -> bytes:
        if self._read:
            return b""
        self._read = True
        return self.body


class StreamResponse(FakeResponse):
    """A binary answer: these chunks in turn, then an error (a stall) or the end."""

    def __init__(
        self, chunks: list[bytes], *, status: int = 200, headers: dict[str, str] | None = None,
        then: BaseException | None = None,
    ) -> None:
        super().__init__({})
        self.chunks = list(chunks)
        self.status = status
        self.headers = headers or {}
        self.then = then

    def read(self, size: int = -1) -> bytes:
        raise AssertionError("a binary is read with read1, which returns what has come so far")

    def read1(self, size: int = -1) -> bytes:
        if self.chunks:
            return self.chunks.pop(0)
        if self.then is not None:
            raise self.then
        return b""


class VerifyPublishedManifestTests(TestCase):
    COMMIT = "a" * 40
    WINDOWS = "cmux-tui-x86_64-pc-windows-gnu.exe"
    CURRENT_UNIX_ONLY_MANIFEST = {
        "commit": "2dc5237c59e06b8f1007533cd4d14b13e702e553",
        "builtAt": "2026-07-15T06:35:13.005735+00:00",
        "binaries": {
            "cmux-tui-aarch64-apple-darwin":
                "21311bd5af176f5196937240b4f38c4810f01ed2e219731e8ba122256512b58d",
            "cmux-tui-aarch64-unknown-linux-gnu":
                "cc50a9cf5040f3d3a7d02d5d9faae6a479967adf3c3f5abb4c4c34796dee3046",
            "cmux-tui-x86_64-apple-darwin":
                "66ac1ee6d31fbb8de1004668de6517f59c075899a359c3946fce92f9273d3741",
            "cmux-tui-x86_64-unknown-linux-gnu":
                "8455dcebdb91d47a3988d64679f1d1ac0919ab558286e3a016ec88c24dce463a",
        },
    }

    def manifest(self, *, windows: bool = True) -> dict[str, object]:
        binaries: dict[str, str] = {}
        if windows:
            binaries[self.WINDOWS] = "b" * 64
        return {"commit": self.COMMIT, "binaries": binaries}

    def provenance(self, manifest: dict[str, object]) -> dict[str, object]:
        manifest.update(
            {
                "sourceRepository": "https://github.com/manaflow-ai/cmux",
                "sourceCommit": self.COMMIT,
                "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/123456789",
                "releaseUrl": None,
            }
        )
        return manifest

    MACHINE_TARGETS = (
        "aarch64-apple-darwin",
        "x86_64-apple-darwin",
        "x86_64-unknown-linux-musl",
        "aarch64-unknown-linux-musl",
    )
    INTEL_MAC = "x86_64-apple-darwin"

    def machine_targets(self, *, intel_mac: bool) -> tuple[str, ...]:
        """What the workflow builds: every target on main, no Intel Mac elsewhere."""
        return tuple(t for t in self.MACHINE_TARGETS if intel_mac or t != self.INTEL_MAC)

    def machine_manifest(self, payloads: dict[str, bytes], *, intel_mac: bool = True) -> dict[str, object]:
        artifacts: dict[str, dict[str, dict[str, object]]] = {}
        for target in self.machine_targets(intel_mac=intel_mac):
            target_artifacts: dict[str, dict[str, object]] = {}
            for kind in ("chatmux-relay", "cmux-tui"):
                name = f"{kind}-{target}"
                payload = payloads[name]
                target_artifacts[kind] = {
                    "name": name,
                    "url": f"https://files.cmux.com/chatmux-relay/{self.COMMIT}/{name}",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size": len(payload),
                }
            artifacts[target] = target_artifacts
        return {
            "schemaVersion": 1,
            "sourceRepository": "https://github.com/manaflow-ai/cmux",
            "sourceCommit": self.COMMIT,
            "version": f"0.0.0-r2.sha-{self.COMMIT}",
            "workflowRunUrl": "https://github.com/manaflow-ai/cmux/actions/runs/123456789",
            "releaseUrl": f"https://github.com/manaflow-ai/cmux/releases/tag/chatmux-relay-r2-{self.COMMIT}",
            "artifacts": artifacts,
        }

    def machine_payloads(self, *, intel_mac: bool = True) -> dict[str, bytes]:
        payloads: dict[str, bytes] = {}
        for target in self.machine_targets(intel_mac=intel_mac):
            for kind in ("chatmux-relay", "cmux-tui"):
                name = f"{kind}-{target}"
                payloads[name] = name.encode("utf-8")
        return payloads

    def machine_manifest_calls(self, *, intel_mac: bool) -> list[tuple[str, list[str]]]:
        """Each --machine-manifest call of the publish job as (step, argv), expanded as bash expands it
        with CMUX_TUI_DARWIN_X86_64 set (main) or empty (every other ref)."""
        document = yaml.safe_load(ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        calls: list[tuple[str, list[str]]] = []
        for step in document["jobs"]["publish"]["steps"]:
            run = step.get("run")
            if not isinstance(run, str) or "--machine-manifest" not in run:
                continue
            run = run.replace("\\\n", " ")
            run = re.sub(
                r"\$\{CMUX_TUI_DARWIN_X86_64:\+([^}]*)\}",
                lambda match: match.group(1) if intel_mac else "",
                run,
            )
            self.assertNotIn("CMUX_TUI_DARWIN_X86_64", run, step["name"])
            run = run.replace("$GITHUB_SHA", self.COMMIT)
            for call in run.split("verify_published_manifest.py")[1:]:
                argv = shlex.split(call.split("\n", 1)[0])
                if "--machine-manifest" in argv:
                    calls.append((step["name"], argv))
        return calls

    def run_machine_check(
        self, argv: list[str], manifest: dict[str, object], payloads: dict[str, bytes]
    ) -> tuple[int, str]:
        """Run one workflow call of the script on this manifest and these binaries: (exit code, stderr)."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)

            def opener(request: object, timeout: float = 0) -> object:
                url = request.full_url  # type: ignore[attr-defined]
                name = url.split("?", 1)[0].rsplit("/", 1)[1]
                response = FakeResponse({})
                response.body = (root / name).read_bytes()
                response.headers = {"Content-Length": str(len(response.body))}
                return response

            local = [arg.replace("assets/chatmux-relay", str(root)) for arg in argv]
            errors = io.StringIO()
            with patch.object(VERIFY, "urlopen", side_effect=opener), \
                    contextlib.redirect_stderr(errors), contextlib.redirect_stdout(io.StringIO()):
                code = VERIFY.main(local)
            return code, errors.getvalue().replace(str(root), "assets/chatmux-relay").strip()

    @staticmethod
    def reads_latest(argv: list[str]) -> bool:
        return any("/latest/" in arg for arg in argv)

    def workflow_machine_manifest(
        self, payloads: dict[str, bytes], *, intel_mac: bool
    ) -> dict[str, object]:
        """The machine manifest as the workflow's own build_machine_manifest writes it for these files."""
        workflow = ARTIFACT_WORKFLOW.read_text(encoding="utf-8")
        function = workflow.split("build_machine_manifest() {", 1)[1]
        builder = textwrap.dedent(function.split("<<'PY'\n", 1)[1].split("\n          PY\n", 1)[0])
        self.assertIn("CMUX_TUI_DARWIN_X86_64", builder)
        environment = {k: v for k, v in os.environ.items() if k != "CMUX_TUI_DARWIN_X86_64"}
        if intel_mac:
            environment["CMUX_TUI_DARWIN_X86_64"] = "1"
        with tempfile.TemporaryDirectory() as directory:
            relay, tui = Path(directory) / "chatmux-relay", Path(directory) / "cmux-tui"
            relay.mkdir()
            tui.mkdir()
            for name, payload in payloads.items():
                ((tui if name.startswith("cmux-tui-") else relay) / name).write_bytes(payload)
            subprocess.run(
                [
                    sys.executable, "-", str(relay), str(tui), self.COMMIT, f"0.0.0-r2.sha-{self.COMMIT}",
                    "https://github.com", "manaflow-ai/cmux", "123456789",
                    f"https://github.com/manaflow-ai/cmux/releases/tag/chatmux-relay-r2-{self.COMMIT}",
                    "https://github.com/manaflow-ai/cmux/actions/runs/123456789",
                ],
                input=builder, text=True, check=True, capture_output=True, env=environment,
            )
            return json.loads((relay / "manifest.json").read_text(encoding="utf-8"))

    def verify(self, manifest: dict[str, object]) -> None:
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def binary_reads(self, manifest: dict[str, object], *payloads: bytes) -> tuple[list[str], object]:
        """urlopen that serves the manifest, then each binary read in turn; records the URLs."""
        seen: list[str] = []
        reads = iter(payloads)

        def opener(request: object, timeout: float = 0) -> object:
            url = request.full_url  # type: ignore[attr-defined]
            seen.append(url)
            if url.endswith("/manifest.json"):
                return FakeResponse(manifest)
            response = FakeResponse({})
            response.body = next(reads)
            response.headers = {"Content-Length": str(len(response.body)), "ETag": '"e1"', "CF-Cache-Status": "HIT"}
            return response

        return seen, opener

    def test_a_transient_wrong_binary_read_is_retried_with_a_fresh_url(self) -> None:
        """Run 37505519359 read other bytes for a binary R2 held correctly, and the publish failed."""
        good = b"browser-host"
        manifest = {"commit": self.COMMIT, "binaries": {"cmux-tui-browser-host-x86_64-apple-darwin": hashlib.sha256(good).hexdigest()}}
        seen, opener = self.binary_reads(manifest, b"stale bytes", good)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY, "RETRY_PAUSE_SECONDS", 0, create=True):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/sha/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(),
                artifact_base_url="https://files.example/cmux-tui/sha",
            )
        binary_urls = [url for url in seen if not url.endswith("/manifest.json")]
        self.assertEqual(len(binary_urls), 2)
        self.assertNotEqual(binary_urls[0], binary_urls[1])
        self.assertTrue(binary_urls[1].startswith(binary_urls[0] + "?"))

    def test_a_persistent_wrong_binary_names_what_the_server_sent(self) -> None:
        manifest = {"commit": self.COMMIT, "binaries": {"cmux-tui-browser-host-x86_64-apple-darwin": "a" * 64}}
        seen, opener = self.binary_reads(manifest, b"x", b"x", b"x")
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY, "RETRY_PAUSE_SECONDS", 0, create=True):
            with self.assertRaisesRegex(VERIFY.ManifestError, r"digest mismatch .* after 3 reads .*size 1.*CF-Cache-Status HIT"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/sha/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    artifact_base_url="https://files.example/cmux-tui/sha",
                )

    def test_a_read_timeout_or_5xx_is_read_again_with_backoff(self) -> None:
        """Run 40466861832 lost a tree's publish to one read timeout during verification."""
        manifest = {"commit": self.COMMIT, "binaries": {self.WINDOWS: hashlib.sha256(b"w").hexdigest()}}
        failures = [TimeoutError("The read operation timed out"),
                    urllib.error.HTTPError("https://files.example/x", 503, "Service Unavailable", {}, None)]
        calls: list[str] = []
        pauses: list[float] = []

        def opener(request: object, timeout: float = 0) -> object:
            calls.append(request.full_url)  # type: ignore[attr-defined]
            if failures:
                raise failures.pop(0)
            return FakeResponse(manifest)

        with patch.object(VERIFY, "urlopen", side_effect=opener), \
                patch.object(VERIFY.time, "sleep", side_effect=pauses.append):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )
        self.assertEqual(len(calls), 3)
        self.assertEqual(pauses, [VERIFY.RETRY_PAUSE_SECONDS, 2 * VERIFY.RETRY_PAUSE_SECONDS])

    def test_a_body_cut_off_mid_read_is_read_again(self) -> None:
        manifest = {"commit": self.COMMIT, "binaries": {self.WINDOWS: hashlib.sha256(b"w").hexdigest()}}

        class CutOff(FakeResponse):
            def read(self, size: int = -1) -> bytes:
                raise http.client.IncompleteRead(b"{", 100)

        responses = [CutOff({}), FakeResponse(manifest)]
        with patch.object(VERIFY, "urlopen", side_effect=lambda request, timeout=0: responses.pop(0)), \
                patch.object(VERIFY.time, "sleep") as sleep:
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )
        self.assertEqual(responses, [])
        sleep.assert_called_once_with(VERIFY.RETRY_PAUSE_SECONDS)

    def test_a_persistent_timeout_fails_after_the_bounded_reads(self) -> None:
        calls: list[str] = []

        def opener(request: object, timeout: float = 0) -> object:
            calls.append(request.full_url)  # type: ignore[attr-defined]
            raise TimeoutError("The read operation timed out")

        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            with self.assertRaisesRegex(VERIFY.ManifestError, r"timed out \(after 5 reads .*5 in a row with no new byte\)"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )
        self.assertEqual(len(calls), VERIFY.FETCH_ATTEMPTS)
        self.assertEqual(calls[0], "https://files.example/cmux-tui/latest/manifest.json")
        self.assertEqual(len(set(calls)), len(calls), "every read again goes to a fresh URL")

    PAYLOAD = bytes(range(256)) * 4
    BINARY = "cmux-tui-aarch64-unknown-linux-gnu"
    BASE = "https://files.example/cmux-tui/sha"

    def stalling_binary(self, serve) -> tuple[list[tuple[str, str | None]], object]:
        """urlopen that serves the manifest, then hands each binary request (its URL and Range
        header, recorded) to serve."""
        manifest = {"commit": self.COMMIT, "binaries": {self.BINARY: hashlib.sha256(self.PAYLOAD).hexdigest()}}
        seen: list[tuple[str, str | None]] = []

        def opener(request: object, timeout: float = 0) -> object:
            url = request.full_url  # type: ignore[attr-defined]
            if url.endswith("/manifest.json"):
                response = FakeResponse(manifest)
                response.headers = {"Content-Length": str(len(response.body))}
                return response
            seen.append((url, request.get_header("Range")))  # type: ignore[attr-defined]
            return serve(len(seen), request.get_header("Range"))  # type: ignore[attr-defined]

        return seen, opener

    def verify_binaries(self) -> None:
        VERIFY.verify_manifest(
            f"{self.BASE}/manifest.json",
            expected_commit=self.COMMIT,
            required_artifacts=(),
            artifact_base_url=self.BASE,
        )

    def stall_at(self, offset: int) -> StreamResponse:
        return StreamResponse(
            [self.PAYLOAD[:offset]], headers={"Content-Length": str(len(self.PAYLOAD))},
            then=TimeoutError("The read operation timed out"),
        )

    def rest_from(self, offset: int, body: bytes | None = None) -> StreamResponse:
        total = len(self.PAYLOAD)
        rest = self.PAYLOAD[offset:] if body is None else body
        return StreamResponse([rest], status=206, headers={
            "Content-Length": str(len(rest)), "Content-Range": f"bytes {offset}-{total - 1}/{total}"})

    def whole(self) -> StreamResponse:
        return StreamResponse([self.PAYLOAD], headers={"Content-Length": str(len(self.PAYLOAD))})

    def test_a_stalled_binary_read_resumes_from_a_fresh_url_with_a_range(self) -> None:
        """Run 40651931144 read one binary's URL three times, each read stalled, and the tree's publish failed."""
        seen, opener = self.stalling_binary(
            lambda n, range_header: self.stall_at(600) if n == 1
            else self.rest_from(600) if range_header == "bytes=600-" else self.whole())
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            self.verify_binaries()
        self.assertEqual(seen[0], (f"{self.BASE}/{self.BINARY}", None))
        self.assertEqual(len(seen), 2)
        self.assertTrue(seen[1][0].startswith(f"{self.BASE}/{self.BINARY}?read="), seen[1][0])
        self.assertEqual(seen[1][1], "bytes=600-")

    def test_a_binary_whose_reads_keep_stalling_is_read_from_fresh_urls_until_one_answers(self) -> None:
        def serve(n: int, range_header: str | None) -> StreamResponse:
            if n <= 3:
                raise TimeoutError("The read operation timed out")
            return self.whole()

        seen, opener = self.stalling_binary(serve)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            self.verify_binaries()
        self.assertEqual(len(seen), 4)
        self.assertEqual(len({url for url, _ in seen}), 4, "every read again goes to a fresh URL")

    def test_a_resumed_read_the_server_answers_whole_or_with_another_range_starts_over(self) -> None:
        wrong_range = StreamResponse([self.PAYLOAD], status=206, headers={
            "Content-Length": str(len(self.PAYLOAD)), "Content-Range": f"bytes 0-1023/{len(self.PAYLOAD)}"})
        for name, second in (("ignores the Range", self.whole()), ("answers another range", wrong_range)):
            with self.subTest(name):
                answers = [self.stall_at(600), second, self.whole()]
                seen, opener = self.stalling_binary(lambda n, range_header: answers.pop(0))
                with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
                    self.verify_binaries()
                if name == "answers another range":
                    self.assertEqual(len(seen), 3)
                    self.assertIsNone(seen[2][1], "a read that starts over asks for the whole object")
                else:
                    self.assertEqual(len(seen), 2)

    def test_a_stalled_read_with_no_length_still_resumes(self) -> None:
        """A chunked answer gives no Content-Length; the 206 that resumes it gives the length."""
        def serve(n: int, range_header: str | None) -> StreamResponse:
            if n == 1:
                return StreamResponse([self.PAYLOAD[:600]], then=TimeoutError("The read operation timed out"))
            total = len(self.PAYLOAD)
            return StreamResponse([self.PAYLOAD[600:]], status=206, headers={
                "Content-Range": f"bytes 600-{total - 1}/{total}"})

        seen, opener = self.stalling_binary(serve)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            self.verify_binaries()
        self.assertEqual([range_header for _, range_header in seen], [None, "bytes=600-"])

    def test_a_range_answer_that_does_not_fit_the_request_starts_over(self) -> None:
        total = len(self.PAYLOAD)
        for content_range, content_length in (
            (f"bytes 600-700/{total}", None),  # ends before the last byte
            (f"bytes 600-{total - 1}/{total}", "5"),  # Content-Length disagrees with the range
            (f"bytes 600-{total - 1}/{total + 1}", None),  # another length
        ):
            with self.subTest(content_range=content_range, content_length=content_length):
                headers = {"Content-Range": content_range}
                if content_length is not None:
                    headers["Content-Length"] = content_length
                answers = [self.stall_at(600), StreamResponse([self.PAYLOAD[600:]], status=206, headers=headers),
                           self.whole()]
                seen, opener = self.stalling_binary(lambda n, range_header: answers.pop(0))
                with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
                    self.verify_binaries()
                self.assertEqual([range_header for _, range_header in seen], [None, "bytes=600-", None])

    def test_a_trickling_read_is_cut_and_resumed(self) -> None:
        def serve(n: int, range_header: str | None) -> StreamResponse:
            offset = int(range_header[len("bytes="):-1]) if range_header else 0
            chunks = [self.PAYLOAD[at:at + 100] for at in range(offset, len(self.PAYLOAD), 100)]
            total = len(self.PAYLOAD)
            if not offset:
                return StreamResponse(chunks, headers={"Content-Length": str(total)})
            return StreamResponse(chunks, status=206, headers={
                "Content-Length": str(total - offset), "Content-Range": f"bytes {offset}-{total - 1}/{total}"})

        seen, opener = self.stalling_binary(serve)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"), \
                patch.object(VERIFY, "READ_ATTEMPT_SECONDS", -1):
            self.verify_binaries()
        self.assertEqual([range_header for _, range_header in seen],
                         [None] + [f"bytes={at}-" for at in range(100, len(self.PAYLOAD), 100)])

    def test_a_resumed_read_never_passes_a_4xx_or_wrong_bytes(self) -> None:
        def not_found(n: int, range_header: str | None) -> StreamResponse:
            if n == 1:
                return self.stall_at(600)
            raise urllib.error.HTTPError("https://files.example/x", 404, "Not Found", {}, None)

        seen, opener = self.stalling_binary(not_found)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            with self.assertRaisesRegex(VERIFY.ManifestError, "404"):
                self.verify_binaries()
        self.assertEqual(len(seen), 2)

        wrong_tail = b"\0" * (len(self.PAYLOAD) - 600)
        seen, opener = self.stalling_binary(
            lambda n, range_header: self.rest_from(600, wrong_tail) if range_header else self.stall_at(600))
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"):
            with self.assertRaisesRegex(VERIFY.ManifestError, rf"digest mismatch for {self.BINARY}.* after 3 reads"):
                self.verify_binaries()
        self.assertEqual(len(seen), 2 * VERIFY.BINARY_READ_ATTEMPTS)

    def test_a_fetch_stops_reading_again_at_its_deadline(self) -> None:
        def stall(n: int, range_header: str | None) -> StreamResponse:
            return self.stall_at(n * 10)

        seen, opener = self.stalling_binary(stall)
        with patch.object(VERIFY, "urlopen", side_effect=opener), patch.object(VERIFY.time, "sleep"), \
                patch.object(VERIFY, "FETCH_DEADLINE_SECONDS", 0):
            with self.assertRaisesRegex(VERIFY.ManifestError, r"timed out \(after 1 reads"):
                self.verify_binaries()
        self.assertEqual(len(seen), 1)

    def test_a_4xx_or_a_wrong_manifest_fails_at_once(self) -> None:
        calls: list[str] = []

        def not_found(request: object, timeout: float = 0) -> object:
            calls.append(request.full_url)  # type: ignore[attr-defined]
            raise urllib.error.HTTPError("https://files.example/x", 404, "Not Found", {}, None)

        with patch.object(VERIFY, "urlopen", side_effect=not_found), patch.object(VERIFY.time, "sleep") as sleep:
            with self.assertRaisesRegex(VERIFY.ManifestError, "404"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )
            sleep.assert_not_called()
        self.assertEqual(len(calls), 1)
        wrong = {"commit": "b" * 40, "binaries": {self.WINDOWS: "a" * 64}}
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(wrong)) as opener, \
                patch.object(VERIFY.time, "sleep") as sleep:
            with self.assertRaises(VERIFY.ManifestError):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )
            sleep.assert_not_called()
        self.assertEqual(opener.call_count, 1)

    def test_accepts_required_windows_artifact_and_digest(self) -> None:
        self.verify(self.manifest())

    def test_rejects_manifest_without_windows_artifact(self) -> None:
        with self.assertRaisesRegex(VERIFY.ManifestError, "missing required artifact"):
            self.verify(self.manifest(windows=False))

    def test_rejects_current_unix_only_latest_manifest(self) -> None:
        manifest = self.CURRENT_UNIX_ONLY_MANIFEST
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(
                VERIFY.ManifestError,
                "missing required artifact",
            ):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=manifest["commit"],
                    required_artifacts=(self.WINDOWS,),
                )

    def test_artifact_workflow_verifies_unix_machine_manifest_before_latest(self) -> None:
        document = yaml.safe_load(ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        build = document["jobs"]["build"]["with"]
        # build-windows reads what it builds from the keyed profile file
        # (scripts/cmux-next/cmux-tui-build-profiles.json, a tree-key input).
        profile = json.loads(BUILD_PROFILES.read_text(encoding="utf-8"))["windows"]
        ref = "${{ fromJSON(needs.tree-preflight.outputs.build_profiles).windows.%s }}"
        windows = {
            key: profile[key] if value == ref % key else value
            for key, value in document["jobs"]["build-windows"]["with"].items()
        }
        # The Windows daemon is built for GPUI's Windows daemon mode, but is
        # published only under cmux-tui-windows/<sha>/ and the tree: never in
        # cmux-tui/<sha>/ or cmux-tui/latest/, which the public Windows
        # installer reads (asserted below with --forbid-artifact). It builds
        # in build-windows, its own call, so the macOS and Linux tree never
        # waits for it (tests/test_cmux_tui_feat_publish_order.py).
        self.assertIs(build["include_windows"], False)
        self.assertIs(windows["include_windows"], True)
        self.assertEqual(windows["target_set"], "windows")
        # A Windows failure must not block the macOS and Linux tree.
        self.assertIs(windows["windows_optional"], True)
        for call in (build, windows):
            self.assertIs(call["package_npm"], False)
            self.assertIs(call["package_pypi"], False)

        installer = WINDOWS_INSTALLER.read_text(encoding="utf-8")
        advertised = re.search(r'^\$Artifact = "([^"]+)"$', installer, re.MULTILINE)
        self.assertIsNotNone(advertised)
        self.assertEqual(advertised.group(1), self.WINDOWS)

        steps = document["jobs"]["publish"]["steps"]
        names = [step.get("name", "") for step in steps]
        before_upload = names.index("Verify Unix manifests before upload")
        upload = names.index("Upload to R2")
        before_latest = names.index("Verify immutable Unix manifests before latest publish")
        rolling = names.index("Publish rolling latest artifacts")
        after_publish = names.index("Verify published Unix manifests")
        self.assertLess(before_upload, upload)
        self.assertLess(upload, before_latest)
        self.assertLess(before_latest, rolling)
        self.assertLess(rolling, after_publish)

        upload_run = steps[upload]["run"]
        self.assertNotIn("cmux-tui/latest", upload_run)
        before_upload_run = steps[before_upload]["run"]
        before_latest_run = steps[before_latest]["run"]
        after_publish_run = steps[after_publish]["run"]
        self.assertIn(f"cmux-tui/$GITHUB_SHA/manifest.json", after_publish_run)
        self.assertIn("cmux-tui/latest/manifest.json?verify=$GITHUB_SHA", after_publish_run)
        self.assertIn("--artifact-directory assets/cmux-tui", before_upload_run)
        self.assertIn("--artifact-base-url", before_latest_run)
        self.assertIn("--artifact-base-url", after_publish_run)
        self.assertIn("chatmux-relay/$GITHUB_SHA/manifest.json", after_publish_run)
        self.assertIn("--machine-manifest", before_upload_run)
        self.assertNotIn("chatmux-relay-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertIn("--forbid-artifact cmux-tui-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertIn("--forbid-artifact cmux-relay-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertNotIn("--require-dependency-artifact", before_upload_run)
        self.assertNotIn("--dependency-artifact-directory assets/cmux-tui", before_upload_run)
        self.assertIn("--require-provenance", before_upload_run)
        self.assertIn("--require-provenance", before_latest_run)
        self.assertIn("--require-provenance", after_publish_run)
        self.assertIn("pattern: chatmux-relay-*", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("assets/chatmux-relay/cmux-tui-*", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertNotIn("chatmux-relay-x86_64-pc-windows-gnu.exe", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("chatmux-relay/$GITHUB_SHA", upload_run)
        self.assertIn("--machine-manifest", before_upload_run)
        self.assertIn("--machine-manifest", before_latest_run)
        self.assertIn("--machine-manifest", after_publish_run)
        self.assertIn("0.0.0-r2.sha-${GITHUB_SHA}", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))

        rolling_run = steps[rolling]["run"]
        self.assertNotIn("cmux-tui-windows", rolling_run)
        self.assertIn('publish_prefix assets/cmux-tui-windows "cmux-tui-windows/$GITHUB_SHA"', upload_run)
        self.assertIn("--require-artifact cmux-tui-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertIn("--forbid-artifact cmux-tui-x86_64-pc-windows-gnu.exe", before_latest_run)
        self.assertIn("--forbid-artifact cmux-tui-x86_64-pc-windows-gnu.exe", after_publish_run)

        attestation = steps[names.index("Attest raw binary subjects")]
        self.assertEqual(attestation["with"]["push-to-registry"], False)

    def test_machine_manifest_builder_copies_dependency_before_directory_change(self) -> None:
        workflow = ARTIFACT_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            'cp "assets/cmux-tui/cmux-tui-${target}" "assets/chatmux-relay/cmux-tui-${target}"',
            workflow,
        )
        self.assertIn('directory="$(cd "$directory" && pwd)"', workflow)
        self.assertIn('dependency_directory="$(cd "$dependency_directory" && pwd)"', workflow)
        self.assertIn("build_machine_manifest assets/chatmux-relay assets/cmux-tui", workflow)

    def test_machine_manifest_requires_dual_unix_binaries_and_full_digests(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
            VERIFY.verify_manifest_file(
                root / "manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(),
                artifact_directory=root,
                machine_manifest=True,
            )

    def test_each_machine_manifest_check_passes_what_the_workflow_writes_without_intel_mac(self) -> None:
        """Off main the workflow builds no x86_64-apple-darwin and writes the machine manifest without it.

        Runs 43328431497 and 43328655357 failed 'Verify Unix manifests before upload' on that manifest
        ("machine manifest target set mismatch"), so no feat-cmux-next tree was published.
        """
        payloads = self.machine_payloads(intel_mac=False)
        manifest = self.machine_manifest(payloads, intel_mac=False)
        calls = [(step, argv) for step, argv in self.machine_manifest_calls(intel_mac=False)
                 if not self.reads_latest(argv)]
        self.assertEqual(
            [step for step, _ in calls],
            [
                "Verify Unix manifests before upload",
                "Verify immutable Unix manifests before latest publish",
                "Verify the kept Unix manifests",
                "Verify published Unix manifests",
            ],
        )
        for step, argv in calls:
            with self.subTest(step=step):
                self.assertEqual(self.run_machine_check(argv, manifest, payloads), (0, ""))

    def test_the_workflow_writes_and_checks_the_same_machine_targets_on_each_ref(self) -> None:
        """The writer and each check take the target set from the same switch, so one cannot move alone.

        #42230 took the Intel Mac target out of the writer and left the check at four targets.
        """
        for intel_mac in (False, True):
            payloads = self.machine_payloads(intel_mac=intel_mac)
            manifest = self.workflow_machine_manifest(payloads, intel_mac=intel_mac)
            self.assertEqual(manifest, self.machine_manifest(payloads, intel_mac=intel_mac))
            for step, argv in self.machine_manifest_calls(intel_mac=intel_mac):
                if self.reads_latest(argv) and not intel_mac:
                    continue
                with self.subTest(intel_mac=intel_mac, step=step):
                    self.assertEqual(self.run_machine_check(argv, manifest, payloads), (0, ""))

    def test_a_ref_without_intel_mac_refuses_a_machine_manifest_that_has_it(self) -> None:
        """The check wants exactly the targets the caller built, not 'three or four'."""
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        for step, argv in self.machine_manifest_calls(intel_mac=False):
            if self.reads_latest(argv):
                continue
            with self.subTest(step=step):
                code, errors = self.run_machine_check(argv, manifest, payloads)
                self.assertEqual(code, 1)
                self.assertIn("machine manifest target set mismatch", errors)
                self.assertIn(f"expected {list(self.machine_targets(intel_mac=False))}", errors)

    def test_main_refuses_a_machine_manifest_without_intel_mac(self) -> None:
        """Main builds all four targets, and latest/ is published only there: each check stays strict."""
        calls = self.machine_manifest_calls(intel_mac=True)
        self.assertEqual(len(calls), 5)
        self.assertEqual(sum(self.reads_latest(argv) for _, argv in calls), 1)
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        short_payloads = self.machine_payloads(intel_mac=False)
        short = self.machine_manifest(short_payloads, intel_mac=False)
        for step, argv in calls:
            with self.subTest(step=step, latest=self.reads_latest(argv)):
                self.assertEqual(self.run_machine_check(argv, manifest, payloads), (0, ""))
                code, errors = self.run_machine_check(argv, short, short_payloads)
                self.assertEqual(code, 1)
                self.assertIn("machine manifest target set mismatch", errors)
                self.assertIn(f"expected {list(self.MACHINE_TARGETS)}", errors)

    def test_the_latest_machine_manifest_check_wants_intel_mac_whatever_the_ref_built(self) -> None:
        """latest/ is what the universal classic app reads; its check never takes the short set."""
        latest = [argv for _, argv in self.machine_manifest_calls(intel_mac=False) if self.reads_latest(argv)]
        self.assertEqual(len(latest), 1)
        short_payloads = self.machine_payloads(intel_mac=False)
        short = self.machine_manifest(short_payloads, intel_mac=False)
        code, errors = self.run_machine_check(latest[0], short, short_payloads)
        self.assertEqual(code, 1)
        self.assertIn(f"expected {list(self.MACHINE_TARGETS)}", errors)

    def test_the_caller_can_leave_out_only_the_intel_mac_machine_target(self) -> None:
        """The target set is the caller's argument, bounded: an empty or short expansion cannot pass a thin manifest."""
        payloads = self.machine_payloads(intel_mac=False)
        manifest = self.machine_manifest(payloads, intel_mac=False)
        base = ["--manifest-file", "assets/chatmux-relay/manifest.json", "--expected-commit", self.COMMIT,
                "--artifact-directory", "assets/chatmux-relay"]

        def check(*targets: str, machine: bool = True) -> tuple[int, str]:
            argv = base + (["--machine-manifest"] if machine else [])
            for target in targets:
                argv += ["--machine-target", target]
            return self.run_machine_check(argv, manifest, payloads)

        built = self.machine_targets(intel_mac=False)
        self.assertEqual(check(*built), (0, ""))
        self.assertEqual(check(*reversed(built)), (0, ""))
        for targets, message in (
            ((), "target set mismatch: expected " + str(list(self.MACHINE_TARGETS))),
            (built[:2], "machine target set cannot leave out ['aarch64-unknown-linux-musl']"),
            (built[1:], "machine target set cannot leave out ['aarch64-apple-darwin']"),
            ((self.INTEL_MAC,), "machine target set cannot leave out"),
            (built + ("x86_64-pc-windows-gnu",), "unknown machine target: ['x86_64-pc-windows-gnu']"),
            (built + built[:1], "machine target named more than once: ['aarch64-apple-darwin']"),
        ):
            with self.subTest(targets=targets):
                code, errors = check(*targets)
                self.assertEqual(code, 1)
                self.assertIn(message, errors)
        code, errors = check(*built, machine=False)
        self.assertEqual(code, 1)
        self.assertIn("--machine-target needs --machine-manifest", errors)

    def test_machine_manifest_rejects_compatibility_fields_and_windows(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        manifest["binaries"] = {}
        manifest["artifacts"]["x86_64-pc-windows-gnu"] = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(VERIFY.ManifestError, "shape mismatch"):
                VERIFY.verify_manifest_file(
                path,
                expected_commit=self.COMMIT,
                required_artifacts=(),
                artifact_directory=Path(directory),
                machine_manifest=True,
                )

    def test_machine_manifest_rejects_size_or_digest_drift(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        target = manifest["artifacts"]["x86_64-unknown-linux-musl"]["chatmux-relay"]
        target["size"] += 1
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
            with self.assertRaisesRegex(VERIFY.ManifestError, "size mismatch"):
                VERIFY.verify_manifest_file(
                    root / "manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    artifact_directory=root,
                    machine_manifest=True,
                )

    def test_rejects_manifest_with_invalid_digest(self) -> None:
        manifest = self.manifest()
        manifest["binaries"] = {self.WINDOWS: "not-a-sha256"}
        with self.assertRaisesRegex(VERIFY.ManifestError, "invalid SHA-256"):
            self.verify(manifest)

    def test_requires_source_build_provenance_when_requested(self) -> None:
        manifest = self.provenance(self.manifest())
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
                require_provenance=True,
            )

    def test_rejects_provenance_for_a_different_source_commit(self) -> None:
        manifest = self.provenance(self.manifest())
        manifest["sourceCommit"] = "b" * 40
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "sourceCommit"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                    require_provenance=True,
                )

    def test_rejects_provenance_attestation_outside_source_repository(self) -> None:
        manifest = self.provenance(self.manifest())
        manifest["attestationUrl"] = "https://example.com/actions/runs/1"
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "attestationUrl"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                    require_provenance=True,
                )

    def test_validates_local_manifest_before_upload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(self.manifest()), encoding="utf-8")
            VERIFY.verify_manifest_file(
                path,
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_verifies_every_local_binary_digest_and_exact_set(self) -> None:
        payload = b"verified binary"
        manifest = {
            "commit": self.COMMIT,
            "binaries": {"relay-linux": hashlib.sha256(payload).hexdigest()},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            (root / "relay-linux").write_bytes(payload)
            VERIFY.verify_manifest_file(
                manifest_path,
                expected_commit=self.COMMIT,
                required_artifacts=(),
                exact_artifacts=("relay-linux",),
                artifact_directory=root,
            )

    def test_rejects_local_binary_digest_mismatch(self) -> None:
        manifest = {
            "commit": self.COMMIT,
            "binaries": {"relay-linux": "a" * 64},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            (root / "relay-linux").write_bytes(b"tampered")
            with self.assertRaisesRegex(VERIFY.ManifestError, "digest mismatch"):
                VERIFY.verify_manifest_file(
                    manifest_path,
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    artifact_directory=root,
                )

    def test_rejects_unexpected_artifact_in_exact_set(self) -> None:
        manifest = self.manifest()
        manifest["binaries"] = {
            self.WINDOWS: "b" * 64,
            "unexpected": "c" * 64,
        }
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "artifact set mismatch"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    exact_artifacts=(self.WINDOWS,),
                )

    def test_rejects_forbidden_windows_artifact(self) -> None:
        manifest = self.manifest()
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "forbidden artifact"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    forbidden_artifacts=(self.WINDOWS,),
                )

    def test_rejects_manifest_for_a_different_commit(self) -> None:
        manifest = self.manifest()
        manifest["commit"] = "c" * 40
        with self.assertRaisesRegex(VERIFY.ManifestError, "commit mismatch"):
            self.verify(manifest)

    def test_rejects_oversized_published_manifest(self) -> None:
        class OversizedResponse(FakeResponse):
            def __init__(self) -> None:
                self.headers = {}
                self.remaining = VERIFY.MAX_MANIFEST_BYTES + 1

            def read(self, size: int = -1) -> bytes:
                if self.remaining <= 0:
                    return b""
                count = min(size, self.remaining)
                self.remaining -= count
                return b"x" * count

        with patch.object(VERIFY, "urlopen", return_value=OversizedResponse()):
            with self.assertRaisesRegex(VERIFY.ManifestError, "size limit"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )


if __name__ == "__main__":
    main()
