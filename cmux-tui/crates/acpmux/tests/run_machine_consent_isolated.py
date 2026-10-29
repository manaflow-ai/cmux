#!/usr/bin/env python3
"""Remote Linux CI only: run real consent-mutating processes in a disposable uid.

From repo root: python3 cmux-tui/crates/acpmux/tests/run_machine_consent_isolated.py
Requires passwordless sudo for useradd/runuser/userdel. Builds use the runner's
normal cache; only the resulting test processes run as the temporary account.
No production code reads ACPMUX_TEST_ACCOUNT_HOME. Its test-only guard verifies
that it equals getpwuid's home and refuses to alter any preexisting policy.
"""
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile


def main():
    built = subprocess.run([
        "cargo", "test", "--locked", "--manifest-path", "cmux-tui/Cargo.toml",
        "-p", "acpmux", "--test", "machine_join", "--test", "person_allow",
        "--no-run", "--message-format=json",
    ], check=True, text=True, stdout=subprocess.PIPE)
    binaries = {}
    for line in built.stdout.splitlines():
        record = json.loads(line)
        if record.get("reason") == "compiler-artifact" and record.get("executable"):
            binaries[record["target"]["name"]] = record["executable"]
    root = Path(tempfile.mkdtemp(prefix="acpmux-consent-ci-"))
    user = "acpx-test-" + str(os.getpid())
    created = False
    try:
        root.chmod(0o755)
        home = root / "home"
        home.mkdir()
        subprocess.run(["sudo", "-n", "useradd", "--home-dir", str(home),
                        "--no-create-home", "--user-group", "--shell", "/usr/sbin/nologin", user], check=True)
        created = True
        account = pwd.getpwnam(user)
        subprocess.run(["sudo", "-n", "chown", f"{account.pw_uid}:{account.pw_gid}", str(home)], check=True)
        for name, filters in [("machine_join", []), ("person_allow", ["machine_consent_"])]:
            subprocess.run([
                "sudo", "-n", "runuser", "-u", user, "--", "env", "-i",
                "PATH=/usr/bin:/bin", f"HOME={home}", f"ACPMUX_TEST_ACCOUNT_HOME={home}",
                # The selected tests start no agents. Avoid the harness's compiled
                # runner-owned scratch dir; children still use daemon_env's clean
                # per-process fixtures. No real CLI accounts enter the environment.
                "ACPMUX_TEST_HERMETIC=1", binaries[name], *filters,
                "--include-ignored", "--test-threads=1", "--nocapture",
            ], check=True)
    finally:
        if created:
            subprocess.run(["sudo", "-n", "userdel", user], check=True)
            subprocess.run(["sudo", "-n", "python3", "-c",
                            "import shutil,sys; shutil.rmtree(sys.argv[1])", str(root)], check=True)
        else:
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
