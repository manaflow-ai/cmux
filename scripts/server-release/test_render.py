"""Portable bootstrap journeys: real TLS download, hashes, tar and child execution.

Only platform identity, signing checks and sudo are fixtures; no installed cmux,
service manager, production signing key or user configuration is touched.
"""

import copy
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("server_release_render", HERE / "render.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def archive(member="bin/cmux", symlink=False):
    buffer = io.BytesIO()
    binary = b'#!/bin/sh\nprintf "%s\\n" "$@" > "$TRACE"\nprintf "%s" "${CMUX_SERVER_MODE-unset}:${CMUX_SERVER_APP_BUNDLE-unset}:${CMUX_SERVER_REEXEC-unset}" > "$MODE_TRACE"\nexit "${FIXTURE_EXIT:-0}"\n'
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        entry = tarfile.TarInfo(member)
        entry.mode = 0o755
        if symlink:
            entry.type = tarfile.SYMTYPE
            entry.linkname = "/bin/sh"
            tar.addfile(entry)
        else:
            entry.size = len(binary)
            tar.addfile(entry, io.BytesIO(binary))
    return buffer.getvalue()


class BootstrapJourney(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tls = tempfile.TemporaryDirectory(prefix="server-release-tls-")
        root = Path(cls.tls.name)
        config = root / "tls.cnf"
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n')
        cls.cert = root / "cert.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-config", str(config), "-keyout", str(root / "key.pem"), "-out", str(cls.cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        cls.payload = archive()
        cls.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                cls.requests.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", str(len(cls.payload)))
                self.end_headers()
                self.wfile.write(cls.payload)

            def log_message(self, *args):
                pass

        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.cert, root / "key.pem")
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.tls.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="server-release-journey-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.work = self.root / "work"
        self.work.mkdir()
        type(self).payload = archive()
        type(self).requests.clear()
        self.plan = {
            "schema": 1, "version": "1.2.3", "macos_team_id": "TESTTEAM01",
            "release_keys": {"current": "11" * 32, "next": "22" * 32},
            "windows_publisher_thumbprints": ["A" * 40],
            "archives": {
                target: {"url": f"https://127.0.0.1:{self.server.server_port}/bootstrap" + (".zip" if target.endswith("windows") else ".tar.gz"),
                         "sha256": hashlib.sha256(self.payload).hexdigest(), "size": len(self.payload)}
                for target in release.TARGETS
            },
        }
        self.env = dict(os.environ, PATH=str(self.tools), TMPDIR=str(self.work),
                        TRACE=str(self.root / "trace"), MODE_TRACE=str(self.root / "mode"),
                        CMUX_SERVER_MODE="system", CMUX_SERVER_APP_BUNDLE="do-not-use",
                        CMUX_SERVER_REEXEC="do-not-use")
        for name in ("tar", "gzip", "wc", "tr", "mktemp", "rm", "mkdir", "chmod", "sha256sum", "shasum", "openssl"):
            path = shutil.which(name)
            if path:
                (self.tools / name).symlink_to(path)
        curl = shutil.which("curl")
        self.tool("curl", f'exec "{curl}" --cacert "{self.cert}" --noproxy "*" "$@"')
        self.tool("uname", 'case "$1" in -s) echo "${FIXTURE_OS:-Linux}" ;; -m) echo "${FIXTURE_ARCH:-x86_64}" ;; esac')
        self.tool("id", 'echo "${FIXTURE_UID:-1000}"')
        self.tool("codesign", 'printf "%s\\n" "$@" >> "$SIGN_TRACE"; case "$*" in *-R=*) exit "${FIXTURE_PUBLISHER_EXIT:-0}" ;; esac; exit "${FIXTURE_SIGN_EXIT:-0}"')
        self.env["SIGN_TRACE"] = str(self.root / "sign")
        self.tool("sudo", 'printf "%s\\n" "$@" > "$SUDO_TRACE"; shift; exec "$@"')
        self.env["SUDO_TRACE"] = str(self.root / "sudo")

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o700)

    def run_script(self, *args, script=None):
        if script is None:
            script = release.render(self.plan)["install.sh"]
        return subprocess.run(["/bin/sh", "-s", "--", *args], input=script,
                              env=self.env, capture_output=True, timeout=10)

    def assert_not_executed(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "trace").exists())
        self.assertEqual(list(self.work.iterdir()), [], result.stderr)

    def test_download_verifies_and_forwards_arguments_without_mode_overrides(self):
        result = self.run_script("--version", "1.2.3", "--channel", "beta", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "trace").read_text().splitlines(), ["server", "install", "--version", "1.2.3", "--channel", "beta", "--json"])
        self.assertEqual((self.root / "mode").read_text(), "unset:unset:unset")
        self.assertFalse((self.root / "sudo").exists())
        self.assertEqual(self.requests, ["/bootstrap.tar.gz"])
        self.assertEqual(list(self.work.iterdir()), [])

    def test_corrupt_archive_never_executes(self):
        for corruption in (b"x" * len(self.payload), b"truncated"):
            with self.subTest(size=len(corruption)):
                type(self).payload = corruption
                self.assert_not_executed(self.run_script())

    def test_verified_but_unsafe_archive_never_executes(self):
        for member, symlink in (("../cmux", False), ("bin/cmux", True)):
            with self.subTest(member=member, symlink=symlink):
                type(self).payload = archive(member, symlink)
                for entry in self.plan["archives"].values():
                    entry.update(sha256=hashlib.sha256(self.payload).hexdigest(), size=len(self.payload))
                self.assert_not_executed(self.run_script())

    def test_system_install_elevates_only_the_verified_binary(self):
        result = self.run_script("--system")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "sudo").read_text().splitlines()
        self.assertEqual(args[0], "--")
        self.assertTrue(args[1].endswith("/unpacked/bin/cmux"))
        self.assertEqual(args[2:], ["server", "install", "--system"])

    def test_root_requires_explicit_system_flag_before_network(self):
        self.env["FIXTURE_UID"] = "0"
        self.assert_not_executed(self.run_script())
        self.assertEqual(self.requests, [])
        result = self.run_script("--system")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "sudo").exists())

    def test_macos_requires_strict_signature_and_matching_team(self):
        self.env.update(FIXTURE_OS="Darwin", FIXTURE_ARCH="arm64")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "sign").read_text().splitlines()
        self.assertEqual(args[:2], ["--verify", "--strict"])
        self.assertIn('-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TESTTEAM01"', args)

    def test_macos_signature_failure_prevents_execution(self):
        self.env.update(FIXTURE_OS="Darwin", FIXTURE_ARCH="arm64")
        for flag in ("FIXTURE_SIGN_EXIT", "FIXTURE_PUBLISHER_EXIT"):
            with self.subTest(flag=flag):
                self.env[flag] = "1"
                self.assert_not_executed(self.run_script())
                del self.env[flag]

    @unittest.skipUnless(Path("/usr/bin/csreq").exists(), "Apple requirement parser needs macOS")
    def test_native_macos_requirement_parses_and_rejects_an_unrelated_signer(self):
        self.env.update(FIXTURE_OS="Darwin", FIXTURE_ARCH="arm64")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / "sign").read_text().splitlines()
        requirement = next(arg for arg in args if arg.startswith("-R="))[3:]
        parsed = subprocess.run(["/usr/bin/csreq", "-r", "=" + requirement], capture_output=True)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        basic = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "/usr/bin/true"], capture_output=True)
        self.assertEqual(basic.returncode, 0, basic.stderr)
        rejected = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, "/usr/bin/true"], capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)

    def test_untrusted_tls_certificate_prevents_download_and_execution(self):
        self.tool("curl", f'exec "{shutil.which("curl")}" --noproxy "*" "$@"')
        self.assert_not_executed(self.run_script())
        self.assertEqual(self.requests, [])

    def test_release_url_is_literal_shell_data(self):
        self.plan["archives"]["x86_64-linux"]["url"] = f"https://127.0.0.1:{self.server.server_port}/bootstrap'$(false).tar.gz"
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, ["/bootstrap'$(false).tar.gz"])

    def test_argument_rejection_happens_before_network(self):
        for args in (("--channel-url", "https://attacker.test"), ("--version",), ("--help",)):
            with self.subTest(args=args):
                self.assert_not_executed(self.run_script(*args))
        self.assertEqual(self.requests, [])

    def test_truncated_scripts_never_download_or_execute(self):
        script = release.render(self.plan)["install.sh"]
        invocation = script.rfind(b'if :; then main')
        for length in [script.index(b'main()'), script.index(b'curl --fail'), *range(invocation, len(script.rstrip()))]:
            with self.subTest(length=length):
                result = self.run_script(script=script[:length])
                self.assertFalse((self.root / "trace").exists(), result.stderr)
                self.assertEqual(self.requests, [])

    def test_installer_failure_is_preserved_and_temporary_files_removed(self):
        self.env["FIXTURE_EXIT"] = "7"
        result = self.run_script()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_hash_fallbacks_verify_actual_download(self):
        for name in ("sha256sum", "shasum"):
            path = self.tools / name
            if path.exists():
                path.unlink()
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_is_deterministic_and_checksums_match(self):
        first = release.render(self.plan)
        self.assertEqual(first, release.render(copy.deepcopy(self.plan)))
        for line in first["SHA256SUMS"].decode().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(hashlib.sha256(first[name]).hexdigest(), digest)

    def test_cli_writes_a_complete_candidate_and_refuses_to_mix_old_signatures(self):
        plan = self.root / "plan.json"
        plan.write_text(json.dumps(self.plan))
        output = self.root / "candidate"
        command = [sys.executable, str(HERE / "render.py"), str(plan), str(output)]
        result = subprocess.run(command, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = release.render(self.plan)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, expected)
        (output / "install.sh.sig").write_bytes(b"fixture-old-signature")
        result = subprocess.run(command, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((output / "install.sh.sig").read_bytes(), b"fixture-old-signature")
        for name, data in expected.items():
            self.assertEqual((output / name).read_bytes(), data)

    def test_invalid_plan_creates_no_candidate(self):
        plan = self.root / "plan.json"
        plan.write_text(json.dumps({**self.plan, "operator_only": "fixture"}))
        output = self.root / "candidate"
        result = subprocess.run([sys.executable, str(HERE / "render.py"), str(plan), str(output)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_rejects_incomplete_or_untrusted_metadata(self):
        bad_plans = []
        for target in release.TARGETS:
            plan = copy.deepcopy(self.plan)
            del plan["archives"][target]
            bad_plans.append(plan)
        for field, value in (("url", "http://insecure.test/bootstrap.tar.gz"), ("url", "https://user:secret@host/bootstrap.tar.gz"), ("url", "https://host/bootstrap.tar.gz?token=secret"), ("size", True), ("size", 0), ("sha256", "bad")):
            plan = copy.deepcopy(self.plan)
            plan["archives"]["x86_64-linux"][field] = value
            bad_plans.append(plan)
        plan = copy.deepcopy(self.plan)
        plan["release_keys"]["next"] = plan["release_keys"]["current"]
        bad_plans.append(plan)
        for plan in bad_plans:
            with self.subTest(plan=plan):
                with self.assertRaises(ValueError):
                    release.render(plan)

    def test_public_bootstrap_descriptor_refuses_unrecognized_operator_fields(self):
        for scope in ("release", "archive"):
            with self.subTest(scope=scope):
                plan = copy.deepcopy(self.plan)
                destination = plan if scope == "release" else plan["archives"]["x86_64-linux"]
                destination["operator_only"] = "fixture-must-not-be-published"
                with self.assertRaises(ValueError):
                    release.render(plan)

    def test_schema_is_an_integer_not_a_json_boolean(self):
        plan = copy.deepcopy(self.plan)
        plan["schema"] = True
        with self.assertRaises(ValueError):
            release.render(plan)


if __name__ == "__main__":
    unittest.main()
