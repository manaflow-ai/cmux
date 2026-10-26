#!/usr/bin/env python3
"""Tests of hermetic_env.py (p15-oracle-200). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/hermetic_env_test.py
    python3 -I scripts/cmux-next/oracle/hermetic_env_test.py --daemon BIN [--cases 300] [--isolation netns|auto|none]

The second form starts BIN (a cargo-built cmux-tui, `--profile oracle`) once per case in parallel, each
in its own hermetic env through driver_daemon.Daemon, stops each owner, then checks that every
client.log says `feature-flags: off (offline)` and `update-check: off (offline)` and that no process
of the run is left. Linux or a fleet Mac only, never the person's Mac.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import hermetic_env  # noqa: E402

NO_ISOLATION = hermetic_env.Isolation("none", (), "test")
OFFLINE_LINES = ("feature-flags: off (offline)", "update-check: off (offline)")


def scratch(test: unittest.TestCase) -> Path:
    root = Path(tempfile.mkdtemp(prefix="o-", dir="/tmp"))
    test.addCleanup(shutil.rmtree, root, True)
    return root


class CaseEnvTests(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch(self)

    def case(self, **kwargs):
        return hermetic_env.daemon_case(self.tmp / "abc123" / "def456", NO_ISOLATION, **kwargs).prepare()

    def test_every_path_is_under_the_case_root(self):
        case = self.case()
        root = str(case.root)
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
                    "XDG_RUNTIME_DIR", "TMPDIR", "CMUX_TUI_CONFIG", "CMUX_NEXT_CONFIG_FILE",
                    "CMUX_TUI_STATE_DIR", "CMUX_TUI_LOG_FILE", "CMUX_TUI_SOCKET"):
            self.assertTrue(case.env[key].startswith(root + "/"), key)
        self.assertEqual(case.socket, case.root / hermetic_env.SOCKET_NAME)
        self.assertEqual(oct(os.stat(case.env["XDG_RUNTIME_DIR"]).st_mode & 0o777), "0o700")

    def test_fixed_values(self):
        env = self.case().env
        expected = {
            "TZ": "UTC", "LANG": "C.UTF-8", "SHELL": "/bin/sh", "PS1": "$ ", "CMUX_TUI_OFFLINE": "1",
            "CMUX_TUI_NO_LOGIN_SHELL": "1", "CMUX_TUI_UPDATE_CHECK": "off", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1", "CMUX_TUI_CLAUDE_HOOKS_DISABLED": "1",
            "CMUX_TUI_CODEX_HOOKS_DISABLED": "1", "CMUX_TUI_TELEMETRY": "off",
        }
        for key, value in expected.items():
            self.assertEqual(env[key], value, key)
        count = int(env["GIT_CONFIG_COUNT"])
        pairs = {env[f"GIT_CONFIG_KEY_{i}"]: env[f"GIT_CONFIG_VALUE_{i}"] for i in range(count)}
        self.assertEqual(pairs["core.hooksPath"], "")
        self.assertEqual(pairs["commit.gpgsign"], "false")

    def test_env_i_base_nothing_of_the_harness_leaks(self):
        marker = "ORACLE_HERMETIC_LEAK_CHECK"
        os.environ[marker] = "1"
        self.addCleanup(os.environ.pop, marker, None)
        case = self.case()
        self.assertNotIn(marker, case.env)
        printed = case.run(["/usr/bin/env"]).stdout.splitlines()
        self.assertEqual(sorted(printed), sorted(f"{k}={v}" for k, v in case.env.items()))

    def test_seed_switches_and_extra(self):
        self.assertNotIn("CMUX_TUI_ORACLE_SEED", self.case().env)
        env = hermetic_env.daemon_case(self.tmp / "a" / "b", NO_ISOLATION, seed="s1", switches="holder=new",
                                       extra={"CMUX_ORACLE_CASE": "x"}).env
        self.assertEqual(env["CMUX_TUI_ORACLE_SEED"], "s1")
        self.assertEqual(env["CMUX_TUI_SWITCHES"], "holder=new")
        self.assertEqual(env["CMUX_ORACLE_CASE"], "x")
        for owned in ("HOME", "CMUX_TUI_OFFLINE", "lower"):
            with self.subTest(owned=owned), self.assertRaises(hermetic_env.HermeticError):
                hermetic_env.daemon_case(self.tmp / "a" / "c", NO_ISOLATION, extra={owned: "x"})

    def test_socket_path_limit(self):
        with self.assertRaises(hermetic_env.SocketPathTooLong):
            hermetic_env.daemon_case(Path("/tmp/" + "x" * 100), NO_ISOLATION)
        case = hermetic_env.daemon_case(Path("/tmp/o/abcdef/ghijkl"), NO_ISOLATION)
        self.assertLessEqual(len(os.fsencode(str(case.socket))), hermetic_env.MAX_SOCKET_PATH_BYTES)
        with self.assertRaises(hermetic_env.HermeticError):
            hermetic_env.daemon_case(Path("relative/root"), NO_ISOLATION)

    def test_receipt_lists_every_variable_with_the_root_token(self):
        case = self.case()
        receipt = case.receipt()
        self.assertEqual(set(receipt["env"]), set(case.env))
        self.assertEqual(receipt["env"]["HOME"], "$CASE_ROOT/home")
        self.assertNotIn(str(case.root), json.dumps(receipt))
        self.assertEqual(receipt["isolation"]["kind"], "none")

    def test_isolation_prefix_wraps_every_command(self):
        prefix = hermetic_env.netns_prefix("/usr/bin/unshare", "/sbin/ip", 1001, 1002)
        isolation = hermetic_env.Isolation("netns", prefix, "t", 1001, 1002)
        case = hermetic_env.daemon_case(self.tmp / "a" / "b", isolation)
        self.assertEqual(case.command(["cmux-tui", "x"])[:2], ["/usr/bin/unshare", "-rn"])
        self.assertEqual(case.command(["cmux-tui", "x"])[-2:], ["cmux-tui", "x"])
        # lo comes up as namespace root, then the caller's uid and gid are mapped back before the exec.
        script = prefix[5]
        self.assertLess(script.index("link set lo up"), script.index("-U --map-user=1001 --map-group=1002"))
        self.assertTrue(script.endswith('-- "$@"'))
        self.assertEqual(hermetic_env.Isolation.from_description(isolation.describe()), isolation)
        self.assertEqual((case.receipt()["isolation"]["uid"], case.receipt()["isolation"]["gid"]), (1001, 1002))
        with self.assertRaises(hermetic_env.HermeticError):
            hermetic_env.Isolation.from_description({"kind": "netns", "prefix": []})

    def test_daemon_case_has_a_fixed_account_name(self):
        env = self.case().env
        self.assertEqual((env["USER"], env["LOGNAME"]), ("oracle", "oracle"))


class IsolationProbeTests(unittest.TestCase):
    def fake(self, returncode, stderr="", stdout="1001\n"):
        def run(argv, **_):
            self.argv = argv
            return subprocess.CompletedProcess(argv, returncode, stdout, stderr)
        return run

    def which(self, name):
        return f"/usr/bin/{name}"

    def ids(self):
        return 1001, 1002

    def test_netns_when_unshare_works(self):
        isolation = hermetic_env.probe_isolation("linux", run=self.fake(0), which=self.which, ids=self.ids)
        self.assertEqual(isolation.kind, "netns")
        self.assertEqual((isolation.uid, isolation.gid), (1001, 1002))
        self.assertEqual(self.argv[:2], ["/usr/bin/unshare", "-rn"])
        self.assertEqual(self.argv[-2:], ["/usr/bin/id", "-u"])

    def test_a_case_that_would_run_as_root_is_a_refusal(self):
        with self.assertRaises(hermetic_env.NetworkIsolationUnavailable) as raised:
            hermetic_env.probe_isolation("linux", run=self.fake(0, stdout="0\n"), which=self.which, ids=self.ids)
        self.assertIn("uid '0'", str(raised.exception))

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux namespaces")
    def test_live_probe_runs_the_case_as_the_caller(self):
        """On a host that allows unprivileged user namespaces (or under `aa-exec -p lxc-unshare` on
        Ubuntu with apparmor_restrict_unprivileged_userns=1), a command in the prefix sees only `lo`, up,
        as the caller's uid and gid; elsewhere the refusal names the host setting."""
        try:
            isolation = hermetic_env.probe_isolation("linux")
        except hermetic_env.NetworkIsolationUnavailable as error:
            self.assertIn("unprivileged user namespaces", str(error))
            self.skipTest(f"this host refuses the netns prefix: {error}")
        # /proc/net/dev lists the namespace's devices; `ip link show up` the ones that are up.
        script = ("id -u; id -g; tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' '; "
                  "ip -o link show up | cut -d: -f2 | tr -d ' '")
        shown = subprocess.run([*isolation.prefix, "/bin/sh", "-c", script], capture_output=True, text=True,
                               timeout=30, check=False, env={"PATH": hermetic_env.TOOL_PATH})
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertEqual(shown.stdout.split(), [str(os.getuid()), str(os.getgid()), "lo", "lo"])

    def test_refusal_is_an_error_unless_not_required(self):
        run = self.fake(1, "unshare: write failed /proc/self/uid_map: Operation not permitted")
        with self.assertRaises(hermetic_env.NetworkIsolationUnavailable):
            hermetic_env.probe_isolation("linux", run=run, which=self.which)
        isolation = hermetic_env.probe_isolation("linux", required=False, run=run, which=self.which, ids=self.ids)
        self.assertEqual(isolation.kind, "none")
        self.assertIn("uid_map", isolation.reason)

    def test_missing_tool_is_a_refusal(self):
        with self.assertRaises(hermetic_env.NetworkIsolationUnavailable):
            hermetic_env.probe_isolation("linux", run=self.fake(0), which=lambda name: None)

    def test_modes(self):
        self.assertEqual(hermetic_env.isolation_for("none", "linux").kind, "none")
        refused = self.fake(1, "denied")
        with self.assertRaises(hermetic_env.NetworkIsolationUnavailable):
            hermetic_env.isolation_for("netns", "linux", run=refused, which=self.which)
        self.assertEqual(hermetic_env.isolation_for("auto", "linux", run=refused, which=self.which).kind, "none")
        self.assertEqual(hermetic_env.isolation_for("netns", "mac", run=refused).kind, "none")
        with self.assertRaises(hermetic_env.HermeticError):
            hermetic_env.isolation_for("bogus", "linux")

    def test_mac_has_no_namespace(self):
        self.assertEqual(hermetic_env.probe_isolation("mac", run=self.fake(0)).kind, "none")


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch(self)
        self.case = hermetic_env.daemon_case(self.tmp / "r" / "c", NO_ISOLATION).prepare()

    def test_refuses_non_local_remotes(self):
        root = self.case.root
        for url in ("https://github.com/manaflow-ai/cmux.git", "git@github.com:manaflow-ai/cmux.git",
                    "ssh://127.0.0.1/x.git", "file://host/tmp/x.git", "git://localhost/x", "../x.git",
                    "//host/x.git", "/etc", f"{root}/../other.git"):
            with self.subTest(url=url), self.assertRaises(hermetic_env.NonLocalRemote):
                hermetic_env.require_local_remote(url, root)
        for url in (f"{root}/repos/a.git", f"file://{root}/repos/a.git"):
            self.assertEqual(hermetic_env.require_local_remote(url, root), (root / "repos" / "a.git").resolve())

    def test_local_bare_origin_without_hooks_or_global_config(self):
        work, bare = hermetic_env.local_bare_origin(self.case, "demo", {"README.md": "hi\n"})
        log = self.case.run(["git", "-C", str(bare), "log", "--format=%H %an %ad", "--date=iso-strict", "main"])
        self.assertEqual(log.returncode, 0, log.stderr)
        first = log.stdout.strip()
        self.assertIn("cmux oracle 2026-01-01T00:00:00", first)
        # The repository's own hook does not run: core.hooksPath is empty.
        hook = work / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\necho hook-ran >&2\nexit 1\n")
        hook.chmod(0o755)
        commit = self.case.run(["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "second"])
        self.assertEqual(commit.returncode, 0, commit.stderr)
        self.assertNotIn("hook-ran", commit.stderr)
        # A remote URL fails at once: protocol.allow=never.
        fetch = self.case.run(["git", "-C", str(work), "ls-remote", "https://127.0.0.1:9/x.git"])
        self.assertNotEqual(fetch.returncode, 0)
        self.assertIn("not allowed", fetch.stderr)
        # The same fixture in a second case gives the same commit id.
        other = hermetic_env.daemon_case(self.tmp / "r" / "d", NO_ISOLATION).prepare()
        _, bare2 = hermetic_env.local_bare_origin(other, "demo", {"README.md": "hi\n"})
        log2 = other.run(["git", "-C", str(bare2), "log", "--format=%H %an %ad", "--date=iso-strict", "main"])
        self.assertEqual(log2.stdout.strip(), first)

    def test_check_repo_remotes_refuses_an_added_github_remote(self):
        work, _ = hermetic_env.local_bare_origin(self.case, "demo", {})
        self.case.run(["git", "-C", str(work), "remote", "add", "up", "https://github.com/x/y.git"])
        with self.assertRaises(hermetic_env.NonLocalRemote):
            hermetic_env.check_repo_remotes(self.case, work)

    def test_repository_name_and_fixture_paths_stay_inside(self):
        with self.assertRaises(hermetic_env.HermeticError):
            hermetic_env.local_bare_origin(self.case, "../escape", {})
        with self.assertRaises(hermetic_env.HermeticError):
            hermetic_env.local_bare_origin(self.case, "demo2", {"../../outside": "x"})


class AppSessionTests(unittest.TestCase):
    def test_app_env_and_receipt(self):
        session = hermetic_env.app_session(Path("/tmp/scratch"), seed="s", switches="a=new")
        env = session["env"]
        self.assertEqual(env["TZ"], "UTC")
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(env["CMUX_NEXT_ORACLE_SEED"], "s")
        self.assertEqual(env["CMUX_NEXT_SWITCHES"], "a=new")
        self.assertFalse([key for key in env if key.startswith("CMUX_TUI_")])
        self.assertIn("CMUX_TUI_OFFLINE", session["receipt"]["daemon_env_not_forwarded"])

    def test_app_keeps_the_account_identity_of_bench_launch(self):
        env = hermetic_env.app_session(Path("/tmp/scratch"))["env"]
        for name in (*hermetic_env.ACCOUNT_IDENTITY, "HOME", "USER", "LOGNAME"):
            self.assertNotIn(name, env)


class AuditTests(unittest.TestCase):
    def test_audit_flags_a_driver_that_builds_env(self):
        folder = scratch(self)
        (folder / "driver_daemon.py").write_text("import os\nenv = dict(os.environ)\nenv['HOME'] = '/x'\n")
        (folder / "driver_app.py").write_text("from hermetic_env import app_session\n")
        findings, notes = hermetic_env.audit(folder)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(all(f.startswith("driver_daemon.py:") for f in findings))
        self.assertIn("gen_daemon_ops.py: not present (p15-oracle-060), not audited", notes)

    def test_audit_flags_a_process_started_with_the_harness_env(self):
        folder = scratch(self)
        (folder / "driver_daemon.py").write_text(
            "import subprocess, sys, os\n"
            "subprocess.Popen(['cmux-tui', '--headless'],\n    cwd='/')\n"  # a case process: refused
            "subprocess.run(['git', 'status'], env=case.env)\n"  # passes its env
            "subprocess.run(['ps', '-ax'], stdout=subprocess.PIPE)\n"  # listed: not a case process
            "subprocess.Popen([sys.executable, '-I', 'driver_daemon.py', 'case-worker'])\n"  # listed
            "subprocess.check_output(argv)\n"  # unknown argv: refused
            "os.execvp('sh', ['sh'])\n"  # refused
        )
        findings, _ = hermetic_env.audit(folder)
        self.assertEqual([f.split(":")[1] for f in findings], ["2", "7", "8"], findings)
        self.assertIn("without env=", findings[0])

    def test_audit_of_this_folder(self):
        findings, notes = hermetic_env.audit()
        self.assertEqual(findings, [])
        self.assertIn("driver_daemon.py: audited", notes)


# ---- daemon run ------------------------------------------------------------------------------------


def run_daemon_case(binary: str, root: Path, isolation: hermetic_env.Isolation) -> str:
    """One owner in its own env, started and stopped by driver_daemon.Daemon. Returns '' or an error."""
    import driver_daemon as d

    paths = d.CasePaths(root)
    paths.create()
    case = d.case_environment(paths, root.name, isolation).prepare()
    daemon = d.Daemon(binary, paths, case, 1.0)
    try:
        daemon.start("setup")
        daemon.stop("teardown", end_terminals=True)
    except d.CaseError as error:
        daemon.kill(9)
        return f"{root.name}: {error.message}"
    log = case.log_file.read_text(encoding="utf-8") if case.log_file.exists() else ""
    missing = [line for line in OFFLINE_LINES if line not in log]
    return f"{root.name}: missing {missing} in client.log:\n{log[-1500:]}" if missing else ""


def daemon_run(binary: str, cases: int, mode: str) -> int:
    import driver_daemon as d

    try:
        isolation = hermetic_env.isolation_for(mode, d.host_platform())
    except hermetic_env.HermeticError as error:
        print(f"hermetic_env_test: {error}", file=sys.stderr)
        return 2
    print(f"isolation: {json.dumps(isolation.describe())}")
    base = Path("/tmp/o")
    base.mkdir(exist_ok=True)
    run_root = Path(tempfile.mkdtemp(prefix="h", dir=str(base)))
    binary = str(Path(binary).resolve())
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(cases, 300)) as pool:
            errors = [e for e in pool.map(lambda i: run_daemon_case(binary, run_root / f"{i:05d}", isolation),
                                          range(cases)) if e]
        left = sorted(m for m in d.scan_markers() if m.startswith(f"{run_root}/"))
    finally:
        shutil.rmtree(run_root, ignore_errors=True)
    for error in errors[:5]:
        print(error, file=sys.stderr)
    print(f"cases: {cases}, failed: {len(errors)}, marked processes left: {len(left)}")
    return 0 if not errors and not left else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--daemon")
    parser.add_argument("--cases", type=int, default=300)
    parser.add_argument("--isolation", choices=hermetic_env.ISOLATION_MODES, default="netns")
    known, rest = parser.parse_known_args()
    if known.daemon:
        sys.exit(daemon_run(known.daemon, known.cases, known.isolation))
    unittest.main(argv=[sys.argv[0], *rest])
