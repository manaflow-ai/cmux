#!/usr/bin/env python3
"""Regression tests for the iPhone dogfood readiness modes.

mac-rpc (default, unchanged) proves signed in + paired through the tagged Mac.
app-receipt proves signed in from a nonce-bound receipt that the app writes in
its own data container. These tests run the real launcher scripts against a
fake `xcrun` on PATH, so no simulator, device, Mac app, or credential leaves
the temporary directory. They run on Linux and macOS.
"""

from __future__ import annotations

import json
import os
import plistlib
import platform
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
LIB = SCRIPTS / "lib" / "mobile-attach.sh"
LAUNCHER = SCRIPTS / "mobile-dev-launch.sh"
VERIFIER = SCRIPTS / "verify-iphone-auth.sh"

DEVICE_ID = "11111111-2222-3333-4444-555555555555"
ACCOUNT = "person@example.com"
PASSWORD = "personal-password-value"

FAKE_XCRUN = r"""#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_STATE"
printf '%s\n' "$*" >> "$state/xcrun-argv.log"
out=""
dest=""
domain_id=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --json-output) out="${args[i+1]}" ;;
    --destination) dest="${args[i+1]}" ;;
    --domain-identifier) domain_id="${args[i+1]}" ;;
  esac
done
if [[ "$1 $2 $3" == "devicectl list devices" ]]; then
  cat > "$out" <<JSON
{"result": {"devices": [{
  "identifier": "$FAKE_DEVICE_ID",
  "hardwareProperties": {"platform": "iOS", "udid": "$FAKE_DEVICE_ID"},
  "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
  "deviceProperties": {"name": "TestPhone", "bootState": "booted", "developerModeStatus": "enabled"}
}]}}
JSON
  exit 0
fi
if [[ "$1 $2 $3 $4" == "devicectl device info apps" ]]; then
  printf '{"result":{"apps":[{"bundleIdentifier":"%s"}]}}\n' "$FAKE_BUNDLE_ID" > "$out"
  exit 0
fi
if [[ "$1 $2 $3 $4" == "devicectl device process launch" ]]; then
  {
    printf 'nonce=%s\n' "${DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE:-}"
    printf 'client=%s\n' "${DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID:-}"
    printf 'email_set=%s\n' "${DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL:+1}"
    printf 'password_set=%s\n' "${DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD:+1}"
    printf 'replace=%s\n' "${DEVICECTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION:-}"
  } > "$state/launch.env"
  exit 0
fi
if [[ "$1 $2 $3 $4" == "devicectl device copy from" ]]; then
  printf '%s\n' "$*" >> "$state/copy-from.log"
  [[ "$FAKE_SCENARIO" != missing ]] || exit 1
  nonce="$(sed -n 's/^nonce=//p' "$state/launch.env")"
  client="$(sed -n 's/^client=//p' "$state/launch.env")"
  account="$FAKE_ACCOUNT"
  [[ "$FAKE_SCENARIO" != stale-nonce ]] || nonce="0000stale"
  [[ "$FAKE_SCENARIO" != wrong-account ]] || account="someone-else@example.com"
  FAKE_NONCE="$nonce" FAKE_CLIENT="$client" FAKE_RECEIPT_ACCOUNT="$account" \
  FAKE_DOMAIN_ID="$domain_id" /usr/bin/python3 - "$dest" <<'PY'
import json, os, sys
json.dump({
    "schema": 1,
    "nonce": os.environ["FAKE_NONCE"],
    "client_id": os.environ["FAKE_CLIENT"],
    "bundle_id": os.environ["FAKE_DOMAIN_ID"],
    "dev_tag": "rdyt",
    "git_sha": "a" * 40,
    "api_base_url": "https://api.example.test",
    "account_email": os.environ["FAKE_RECEIPT_ACCOUNT"].upper(),
    "user_id": "user-1",
    "session_source": os.environ["FAKE_SESSION_SOURCE"],
    "written_at": "2026-10-02T00:00:00Z",
}, open(sys.argv[1], "w"))
PY
  exit 0
fi
if [[ "$1" == simctl ]]; then
  exit 1
fi
echo "fake xcrun: unhandled: $*" >&2
exit 1
"""

# Records that the mac-rpc path armed the tagged Mac without touching the
# developer's real defaults database.
FAKE_DEFAULTS = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_STATE/defaults.log"
exit 0
"""

FAKE_CMUX = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_STATE/cmux.log"
exit 0
"""

# dev-secrets.sh validates the credential file with BSD `stat -f`. Linux
# runners get an equivalent shim for exactly the two formats it uses.
FAKE_STAT = """#!/usr/bin/env python3
import os, sys
if len(sys.argv) == 4 and sys.argv[1] == "-f":
    st = os.stat(sys.argv[3])
    print({"%u": str(st.st_uid), "%Lp": format(st.st_mode & 0o7777, "o")}[sys.argv[2]])
    raise SystemExit(0)
os.execv("/usr/bin/stat", ["stat", *sys.argv[1:]])
"""


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


def write_app(path: Path, readiness: str | None) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    info = {"CFBundleIdentifier": "dev.cmux.ios.rdyt", "CFBundleExecutable": "cmux"}
    if readiness is not None:
        info["CMUXDogfoodReadiness"] = readiness
    (path / "Info.plist").write_bytes(plistlib.dumps(info))
    (path / "cmux").write_text("binary")
    return path


class Sandbox:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="cmux-readiness-test-"))
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.home = self.root / "home"
        self.receipts = self.root / "receipts"
        for directory in (self.state, self.bin, self.home):
            directory.mkdir()
        write_executable(self.bin / "xcrun", FAKE_XCRUN)
        write_executable(self.bin / "defaults", FAKE_DEFAULTS)
        write_executable(self.bin / "cmux", FAKE_CMUX)
        if platform.system() != "Darwin":
            write_executable(self.bin / "stat", FAKE_STAT)
        self.credentials = self.root / "personal.env"
        self.credentials.write_text(
            f"CMUX_DOGFOOD_STACK_EMAIL={ACCOUNT}\nCMUX_DOGFOOD_STACK_PASSWORD={PASSWORD}\n"
        )
        self.credentials.chmod(0o600)

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def env(self, scenario: str = "pass", session_source: str = "auto_login", **extra: str) -> dict[str, str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "FAKE_STATE": str(self.state),
            "FAKE_DEVICE_ID": DEVICE_ID,
            "FAKE_BUNDLE_ID": "dev.cmux.ios.rdyt",
            "FAKE_ACCOUNT": ACCOUNT,
            "FAKE_SCENARIO": scenario,
            "FAKE_SESSION_SOURCE": session_source,
            "CMUX_READINESS_RECEIPT_DIR": str(self.receipts),
            "CMUX_APP_RECEIPT_TIMEOUT_SECONDS": "2",
        }
        env.update(extra)
        return env

    def launch(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(LAUNCHER), "--tag", "rdyt", "--device", "--device-id", DEVICE_ID,
             "--auth-profile", "personal", "--credentials-file", str(self.credentials), *args],
            env=self.env(**env), cwd=REPO_ROOT, text=True, capture_output=True, timeout=120,
        )

    def verify(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(VERIFIER), "--tag", "rdyt", "--device-id", DEVICE_ID,
             "--credentials-file", str(self.credentials), *args],
            env=self.env(**env), cwd=REPO_ROOT, text=True, capture_output=True, timeout=120,
        )

    def launch_env(self) -> dict[str, str]:
        path = self.state / "launch.env"
        if not path.exists():
            return {}
        return dict(line.split("=", 1) for line in path.read_text().splitlines())

    def log(self, name: str) -> str:
        path = self.state / name
        return path.read_text() if path.exists() else ""

    def receipt(self) -> dict:
        return json.loads((self.receipts / f"rdyt-{DEVICE_ID.lower()}.json").read_text())


def lib_call(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f'set -euo pipefail; source "{LIB}"; {script}'],
        env={**os.environ, **(env or {})}, text=True, capture_output=True, timeout=60,
    )


class ReadinessModeTest(unittest.TestCase):
    def test_mode_comes_from_the_app_contract(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cases = {
                "missing": (None, 0, "mac-rpc"),
                "no-key": ("<absent>", 0, "mac-rpc"),
                "v1": ("app-receipt-v1", 0, "app-receipt"),
                "future": ("app-receipt-v2", 2, ""),
            }
            for name, (value, code, mode) in cases.items():
                with self.subTest(name=name):
                    app = Path(tmp) / f"{name}.app"
                    if value is not None:
                        write_app(app, None if value == "<absent>" else value)
                    result = lib_call(f'cmux_attach_app_readiness_mode "{app}"')
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual(result.stdout, mode)


class ReceiptValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="cmux-receipt-validate-"))
        self.base = {
            "schema": 1, "nonce": "n1", "client_id": "c1", "bundle_id": "dev.cmux.ios.rdyt",
            "account_email": ACCOUNT, "session_source": "auto_login",
            "written_at": "2026-10-02T00:00:00Z", "user_id": "u1",
        }

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def validate(self, receipt: dict | str | None, source: str = "") -> subprocess.CompletedProcess[str]:
        path = self.tmp / "readiness.json"
        path.unlink(missing_ok=True)
        if isinstance(receipt, dict):
            path.write_text(json.dumps(receipt))
        elif isinstance(receipt, str):
            path.write_text(receipt)
        return lib_call(
            f'cmux_attach_validate_app_receipt "{path}" n1 c1 dev.cmux.ios.rdyt {ACCOUNT} "{source}"'
        )

    def test_valid_receipt_is_sanitized(self) -> None:
        result = self.validate(dict(self.base, account_email="Person@Example.COM"))
        self.assertEqual(result.returncode, 0, result.stderr)
        sanitized = json.loads(result.stdout)
        self.assertEqual(sanitized["account_email"], ACCOUNT)
        self.assertNotIn("nonce", sanitized)

    def test_pending_or_stale_receipts_keep_waiting(self) -> None:
        for name, receipt in {
            "missing file": None,
            "partial write": "{",
            "nonce mismatch": dict(self.base, nonce="old"),
        }.items():
            with self.subTest(name=name):
                self.assertEqual(self.validate(receipt).returncode, 1)

    def test_identity_mismatches_fail_definitively(self) -> None:
        for name, receipt in {
            "wrong account": dict(self.base, account_email="other@example.com"),
            "wrong client": dict(self.base, client_id="c2"),
            "wrong bundle": dict(self.base, bundle_id="dev.cmux.ios.other"),
            "string schema": dict(self.base, schema="1"),
            "unknown source": dict(self.base, session_source="guessed"),
            "secret field": dict(self.base, access_token="x"),
            "missing account": {k: v for k, v in self.base.items() if k != "account_email"},
        }.items():
            with self.subTest(name=name):
                self.assertEqual(self.validate(receipt).returncode, 3)

    def test_restored_requirement(self) -> None:
        self.assertEqual(self.validate(self.base, "restored").returncode, 3)
        restored = dict(self.base, session_source="restored")
        self.assertEqual(self.validate(restored, "restored").returncode, 0)


class LauncherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()

    def tearDown(self) -> None:
        self.box.close()

    def assert_app_receipt_pass(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("signed in (app receipt)", result.stdout)
        self.assertRegex(result.stdout, r"iPhone auth gate: PASS")
        launched = self.box.launch_env()
        self.assertRegex(launched["nonce"], r"^[0-9a-f]{32}$")
        self.assertEqual(launched["password_set"], "1")
        self.assertEqual(launched["replace"], "1")
        argv = self.box.log("xcrun-argv.log")
        self.assertNotIn(launched["nonce"], argv, "nonce must travel in the environment")
        self.assertNotIn(PASSWORD, argv)
        self.assertIn("--domain-type appDataContainer --domain-identifier dev.cmux.ios.rdyt", argv)
        self.assertEqual(self.box.log("defaults.log"), "", "app-receipt must not arm the tagged Mac")
        receipt = self.box.receipt()
        self.assertEqual(receipt["readiness"], "app-receipt")
        self.assertEqual(receipt["auth_account"], ACCOUNT)
        self.assertEqual(receipt["client_id"], launched["client"])
        self.assertNotIn("socket_path", receipt)
        raw = json.dumps(receipt)
        self.assertNotIn(PASSWORD, raw)
        self.assertNotIn(launched["nonce"], raw)
        path = self.box.receipts / f"rdyt-{DEVICE_ID.lower()}.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_explicit_app_receipt_passes_without_the_mac(self) -> None:
        self.assert_app_receipt_pass(self.box.launch("--readiness", "app-receipt"))

    def test_app_receipt_ignores_ensure_mac(self) -> None:
        result = self.box.launch("--readiness", "app-receipt", "--ensure-mac")
        self.assert_app_receipt_pass(result)
        self.assertIn("skipping tagged Mac pairing", result.stdout)

    def test_auto_reads_the_installed_app_contract(self) -> None:
        app = write_app(self.box.root / "cmux.app", "app-receipt-v1")
        self.assert_app_receipt_pass(self.box.launch(CMUX_INSTALLED_APP_PATH=str(app)))

    def test_wrong_account_fails_with_app_receipt_retry(self) -> None:
        result = self.box.launch("--readiness", "app-receipt", scenario="wrong-account")
        self.assertEqual(result.returncode, 1)
        self.assertIn("different account", result.stderr)
        self.assertIn("iPhone auth gate FAILED", result.stderr)
        retry = next(line for line in result.stderr.splitlines() if line.startswith("error: retry:"))
        self.assertIn("--readiness app-receipt", retry)
        self.assertNotIn("--ensure-mac", retry)
        self.assertFalse(self.box.receipts.exists() and any(self.box.receipts.iterdir()))

    def test_stale_nonce_and_missing_receipt_time_out(self) -> None:
        for scenario, reason in (("stale-nonce", "nonce mismatch"), ("missing", "no receipt published yet")):
            with self.subTest(scenario=scenario):
                result = self.box.launch("--readiness", "app-receipt", scenario=scenario)
                self.assertEqual(result.returncode, 1)
                self.assertIn(reason, result.stderr)
                self.assertIn("iPhone auth gate FAILED", result.stderr)

    def test_default_mode_is_unchanged_mac_rpc(self) -> None:
        # No CMUXDogfoodReadiness key (or no app path) keeps the tagged Mac
        # flow: --ensure-mac arms the pairing host and, with no local Mac
        # build in this sandbox, fails before launching the phone.
        app = write_app(self.box.root / "old.app", None)
        for env in ({}, {"CMUX_INSTALLED_APP_PATH": str(app)}):
            with self.subTest(env=env):
                (self.box.state / "defaults.log").unlink(missing_ok=True)
                result = self.box.launch(**env)
                self.assertEqual(result.returncode, 1)
                self.assertIn("device launch defaults to --ensure-mac", result.stdout)
                self.assertIn("could not prepare tagged Mac", result.stderr)
                self.assertIn("mobile.iOSPairingHost.enabled", self.box.log("defaults.log"))
                self.assertEqual(self.box.log("copy-from.log"), "")
                self.assertEqual(self.box.launch_env(), {})

    def test_invalid_mode_and_release_gate_combination_are_refused(self) -> None:
        result = self.box.launch("--readiness", "pairing")
        self.assertEqual(result.returncode, 2)
        result = subprocess.run(
            ["bash", str(LAUNCHER), "--tag", "rdyt", "--iroh-release-gate", "relayOnly",
             "--readiness", "app-receipt"],
            env=self.box.env(), cwd=REPO_ROOT, text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot be combined with the Iroh release gate", result.stderr)


class VerifierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()

    def tearDown(self) -> None:
        self.box.close()

    def test_restored_session_passes_credential_free(self) -> None:
        result = self.box.verify("--readiness", "app-receipt", session_source="restored")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("restored session proven by app receipt", result.stdout)
        launched = self.box.launch_env()
        self.assertEqual(launched["password_set"], "", "relaunch must not inject credentials")
        self.assertEqual(launched["email_set"], "")
        self.assertEqual(launched["replace"], "")
        self.assertRegex(launched["nonce"], r"^[0-9a-f]{32}$")
        self.assertEqual(self.box.receipt()["session_source"], "restored")
        self.assertEqual(self.box.log("cmux.log"), "")

    def test_fresh_sign_in_does_not_prove_persistence(self) -> None:
        result = self.box.verify("--readiness", "app-receipt", session_source="auto_login")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL:", result.stdout)
        self.assertIn("expected restored", result.stdout)
        self.assertIn("--readiness app-receipt", result.stdout)

    def test_auto_reuses_the_launchers_recorded_mode(self) -> None:
        self.box.receipts.mkdir(mode=0o700)
        path = self.box.receipts / f"rdyt-{DEVICE_ID.lower()}.json"
        path.write_text(json.dumps({"readiness": "app-receipt"}))
        result = self.box.verify(session_source="restored")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_default_mode_still_requires_the_tagged_mac(self) -> None:
        result = self.box.verify(session_source="restored")
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOT verified signed in + paired", result.stdout)
        self.assertIn("is not running and no local build exists", result.stdout)
        self.assertEqual(self.box.log("copy-from.log"), "")


if __name__ == "__main__":
    unittest.main()
