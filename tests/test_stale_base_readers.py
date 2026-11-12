#!/usr/bin/env python3
"""Tools that measure "this branch's own change" fetch the shared base first, so a stale copy never widens it.

Each tool here takes where HEAD meets this clone's origin/feat-cmux-next. That ref is only as new as the clone's
last fetch of it: a branch that merged a newer base (a stacked parent fetched alone, `git fetch origin lane/parent`,
after the parent merged feat-cmux-next) had that base's files counted as its own. cmux#41310 fixed the pre-push gate
(scripts/cmux-next/push_range.py refresh_upstream); these are the readers left: affected tests, the Rust panic
ratchet, build_class, gate-plan, the test-determinism scan, codebase-health and a manual arch-ratchet run (the
gate and the web lint run by hand take the same push_range.manual_range). Each test builds one fixture: the topic
adds own files and merges a base that has base-only files, while the clone's origin/feat-cmux-next stays old.

Not in CI (tests/test-execution.d/other.toml: manual; no new CI tests, Lawrence 2026-10-23): run
`python3 -I tests/test_stale_base_readers.py` after changing one of these tools (a few seconds, no build).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
# A CI or pull-request environment would point the tools elsewhere (GITHUB_BASE_REF) or turn the fetch off.
CLEARED = ("GITHUB_ACTIONS", "GITHUB_BASE_REF", "CI", "CMUX_PREPUSH_RUN")


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


class StaleBaseFixture(unittest.TestCase):
    """The topic adds own files and merges a base that has base-only files; the clone's origin/feat-cmux-next stays old."""

    OWN = ("cmux-tui/z_own.rs", "plans/cmux-next/own.md", "tests/test_own_change.py")
    BASE = ("cmux-tui/a_base.rs", "plans/cmux-next/base.md", "tests/test_base_change.py")

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        env = {k: v for k, v in os.environ.items() if k not in CLEARED and not k.startswith("GIT_")}
        patcher = unittest.mock.patch.dict(os.environ, git_fixture_env.fixture_env(env), clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        origin = git_fixture_env.init_repo(self.tmp / "origin.git", "--bare", "-b", "feat-cmux-next")
        seed = self.seed = git_fixture_env.init_repo(self.tmp / "seed", "-b", "feat-cmux-next")
        self.git(seed, "remote", "add", "origin", str(origin))
        self.write(seed, "README.md", "base\n")
        self.commit(seed, "base")
        self.git(seed, "push", "--quiet", "origin", "feat-cmux-next")

        self.work = git_fixture_env.clone_repo(origin, self.tmp / "work")
        self.git(self.work, "checkout", "--quiet", "-b", "topic", "origin/feat-cmux-next")
        for path in self.OWN:
            self.write(self.work, path, "own\n")
        self.commit(self.work, "the branch's own change")

        # feat-cmux-next moves on; the stacked parent merges it; this clone fetches only the parent.
        for path in self.BASE:
            self.write(seed, path, "base\n")
        self.fresh_base = self.commit(seed, "a base change this clone never fetched")
        self.git(seed, "push", "--quiet", "origin", "feat-cmux-next", "feat-cmux-next:lane/parent")
        self.stale_base = self.git(self.work, "rev-parse", "origin/feat-cmux-next")
        self.git(self.work, "fetch", "--quiet", "origin", "lane/parent")
        self.git(self.work, "merge", "--quiet", "--no-edit", "--no-ff", "origin/lane/parent")
        self.assertNotEqual(self.stale_base, self.fresh_base)
        self.assertEqual(self.git(self.work, "rev-parse", "origin/feat-cmux-next"), self.stale_base)

    def git(self, repo: Path, *args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), "-c", "user.name=fixture",
                               "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()

    def write(self, repo: Path, relative: str, text: str) -> None:
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, repo: Path, message: str) -> str:
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "--quiet", "-m", message)
        return self.git(repo, "rev-parse", "HEAD")

    def assert_fetched(self) -> None:
        self.assertEqual(self.git(self.work, "rev-parse", "origin/feat-cmux-next"), self.fresh_base,
                         "the tool fetched the shared base first")


class StaleBaseReaders(StaleBaseFixture):
    def test_affected_tests_plans_from_the_fresh_base(self):
        affected = load("stale_base_affected_tests", "scripts/ci/affected_tests.py")
        seen = {}

        def plan(root, base, head, files, shards, everything):
            seen["base"] = base
            return {"base": base}

        out = io.StringIO()
        with unittest.mock.patch.object(affected, "plan", plan), contextlib.redirect_stdout(out):
            self.assertEqual(affected.main(["--root", str(self.work)]), 0)
        self.assertEqual(seen["base"], self.fresh_base, "BASE...HEAD would hold the base's files as the change's")
        self.assertEqual(json.loads(out.getvalue())["base"], self.fresh_base)

    def test_rust_panic_ratchet_lists_the_branch_s_own_hits_first(self):
        ratchet = load("stale_base_rust_panic_ratchet", "scripts/cmux-next/rust_panic_ratchet.py")
        ordered = ratchet._changed_first(str(self.work), ["a_base.rs:1", "z_own.rs:1"])
        self.assertEqual(ordered, ["z_own.rs:1", "a_base.rs:1"], "a base file's hit is not the change's")

    def test_build_class_classifies_only_the_branch_s_own_files(self):
        build_class = load("stale_base_build_class", "scripts/ci/build_class.py")
        with unittest.mock.patch.object(build_class, "ROOT", self.work):
            changed = build_class.changed_files("origin/feat-cmux-next")
        self.assertEqual(sorted(changed), sorted(self.OWN))

    def test_gate_plan_routes_only_the_branch_s_own_files(self):
        gate_plan = load("stale_base_gate_plan", "scripts/cmux-next/gate-plan.py")

        class Routed(Exception):
            pass

        def route(root, event, changed, labels):
            raise Routed(changed)

        hq = self.tmp / "hq"
        hq.mkdir()
        with unittest.mock.patch.object(gate_plan, "ROOT", self.work), \
                unittest.mock.patch.dict(os.environ, {"HQ_ROOT": str(hq)}), \
                unittest.mock.patch.object(gate_plan.route_mod, "route", route), \
                self.assertRaises(Routed) as routed:
            gate_plan.main([])
        self.assertEqual(sorted(routed.exception.args[0]), sorted(self.OWN))

    def test_the_determinism_scan_reads_only_the_branch_s_own_tests(self):
        scan = load("stale_base_check_test_determinism", "scripts/check-test-determinism.py")
        self.assertEqual(scan._changed_python_tests(self.work), ["tests/test_own_change.py"])

    def test_codebase_health_names_only_the_tree_s_own_measured_changes(self):
        health = load("stale_base_codebase_health", "scripts/cmux-next/codebase-health.py")
        where = health.measured_at(self.work)
        self.assertIn(self.fresh_base[:11], where)
        self.assertIn("own.md", where)
        self.assertNotIn("base.md", where)

    def test_a_manual_arch_ratchet_run_judges_from_the_fresh_base(self):
        arch = load("stale_base_arch_ratchet", "scripts/cmux-next/arch-ratchet.py")
        out = io.StringIO()
        with unittest.mock.patch.object(arch, "run_push", lambda *args, **kwargs: []), \
                contextlib.redirect_stdout(out):
            self.assertEqual(arch.main(["--repo", str(self.work)]), 0)
        self.assertIn(f"over {self.fresh_base[:11]}", out.getvalue())
        self.assert_fetched()


class BaseFetchOnce(StaleBaseFixture):
    """The fetch itself (cmux#41310 and #41662 review): once per hook run and once per process, never a prompt.

    A stamp that outlived its hook run let a retried push skip the fetch after the base moved; a reader that ran per
    failing group fetched per group (a stalled remote cost 30 s each); and GIT_TERMINAL_PROMPT=0 alone left an
    askpass helper free to open a credential window or wait out the limit."""

    def setUp(self) -> None:
        super().setUp()
        self.push_range = load("stale_base_push_range", "scripts/cmux-next/push_range.py")
        self.key = f"refs/heads/topic {self.git(self.work, 'rev-parse', 'HEAD')} refs/heads/topic {'0' * 40}"

    def count_fetches(self) -> list[list[str]]:
        fetches: list[list[str]] = []
        real = subprocess.run

        def counting(args, *rest, **kwargs):
            if isinstance(args, (list, tuple)) and "fetch" in args:
                fetches.append(list(args))
            return real(args, *rest, **kwargs)

        patcher = unittest.mock.patch.object(subprocess, "run", counting)
        patcher.start()
        self.addCleanup(patcher.stop)
        return fetches

    def advance_base(self, name: str) -> str:
        self.write(self.seed, name, "later\n")
        sha = self.commit(self.seed, f"the base moves again ({name})")
        self.git(self.seed, "push", "--quiet", "origin", "feat-cmux-next")
        return sha

    def refresh(self, run: str | None) -> str:
        env = {"CMUX_PREPUSH_RUN": run} if run is not None else {}
        with unittest.mock.patch.dict(os.environ, env):
            if run is None:
                os.environ.pop("CMUX_PREPUSH_RUN", None)
            return self.push_range.refresh_upstream(self.work, "origin", key=self.key)

    def tracked(self) -> str:
        return self.git(self.work, "rev-parse", "origin/feat-cmux-next")

    def test_the_checks_of_one_hook_run_fetch_once(self):
        fetches = self.count_fetches()
        for _ in range(3):
            self.assertEqual(self.refresh("run-1"), "")
        self.assertEqual(len(fetches), 1, fetches)
        self.assert_fetched()

    def test_a_retried_push_fetches_again_after_the_base_moved(self):
        self.assertEqual(self.refresh("run-1"), "")
        self.assert_fetched()
        later = self.advance_base("later.md")
        self.git(self.work, "update-ref", "refs/remotes/origin/feat-cmux-next", self.stale_base)
        self.assertEqual(self.refresh("run-2"), "")
        self.assertEqual(self.tracked(), later, "the retry's own hook run fetched the base again")

    def test_a_hook_that_names_no_run_fetches_every_time(self):
        self.assertEqual(self.refresh(None), "")
        later = self.advance_base("later.md")
        self.assertEqual(self.refresh(None), "")
        self.assertEqual(self.tracked(), later, "with no run to scope it to, no stamp skips the fetch")

    def test_the_base_fetch_never_opens_a_credential_prompt(self):
        record = self.tmp / "ssh-record"
        fake_ssh = self.tmp / "fake-ssh"
        fake_ssh.write_text("#!/bin/sh\n{ printf 'args=%s\\n' \"$*\"; printf 'GIT_ASKPASS=%s\\n' \"$GIT_ASKPASS\";"
                            " printf 'SSH_ASKPASS=%s\\n' \"$SSH_ASKPASS\";"
                            " printf 'SSH_ASKPASS_REQUIRE=%s\\n' \"$SSH_ASKPASS_REQUIRE\"; }"
                            f" >> '{record}'\nexit 255\n")
        fake_ssh.chmod(0o755)
        asker = self.tmp / "askpass"
        asker.write_text(f"#!/bin/sh\ntouch '{self.tmp / 'asked'}'\necho secret\n")
        asker.chmod(0o755)
        self.git(self.work, "remote", "set-url", "origin", "ssh://fixture.invalid/origin.git")
        with unittest.mock.patch.dict(os.environ, {"GIT_SSH_COMMAND": str(fake_ssh), "GIT_ASKPASS": str(asker),
                                                   "SSH_ASKPASS": str(asker), "SSH_ASKPASS_REQUIRE": "force"}):
            note = self.push_range.refresh_base(self.work, "origin/feat-cmux-next")
        self.assertIn("could not be fetched", note)
        seen = record.read_text()
        self.assertIn("BatchMode=yes", seen, "ssh must fail instead of asking")
        self.assertNotIn(str(asker), seen, "no askpass helper reaches the fetch or its ssh")
        self.assertIn("SSH_ASKPASS_REQUIRE=never", seen)
        self.assertFalse((self.tmp / "asked").exists())

    def test_the_rust_panic_ratchet_fetches_once_for_every_failing_group(self):
        ratchet = load("stale_base_rust_panic_ratchet_once", "scripts/cmux-next/rust_panic_ratchet.py")
        fetches = self.count_fetches()
        for _ in range(3):  # three crate/lint groups over their baseline
            self.assertEqual(ratchet._changed_first(str(self.work), ["a_base.rs:1", "z_own.rs:1"]),
                             ["z_own.rs:1", "a_base.rs:1"])
        self.assertEqual(len(fetches), 1, fetches)

    def test_a_failed_base_fetch_is_not_retried_by_the_next_reader(self):
        self.git(self.work, "remote", "set-url", "origin", str(self.tmp / "gone.git"))
        ratchet = load("stale_base_rust_panic_ratchet_gone", "scripts/cmux-next/rust_panic_ratchet.py")
        build_class = load("stale_base_build_class_gone", "scripts/ci/build_class.py")
        fetches = self.count_fetches()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), unittest.mock.patch.object(build_class, "ROOT", self.work):
            ratchet._changed_first(str(self.work), ["z_own.rs:1"])
            ratchet._changed_first(str(self.work), ["z_own.rs:1"])
            build_class.changed_files("origin/feat-cmux-next")
        self.assertEqual(len(fetches), 1, f"one process, one fetch of the base, failed or not: {fetches}")
        self.assertIn("could not be fetched", stderr.getvalue())



# A stand-in for ssh, a GIT_SSH wrapper or a credential helper: it records how it was started (its arguments, its
# session, the prompt settings it was handed) and fails, as a remote that wants a credential does.
FAKE_PROGRAM = """#!{python}
import json, os, sys
if sys.argv[1:2] in (["get"], ["store"], ["erase"]):
    sys.stdin.read()  # a credential helper's request
with open({record!r}, "a") as out:
    out.write(json.dumps({{"name": os.path.basename(sys.argv[0]), "args": sys.argv[1:], "sid": os.getsid(0),
                          "env": {{k: os.environ.get(k) for k in ("GIT_ASKPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE",
                                                                 "GIT_TERMINAL_PROMPT", "GCM_INTERACTIVE")}}}}) + "\\n")
sys.exit({code})
"""

# One pre-push checker: its own process, loading push_range.py by path as every checker does.
CHECKER = ("import importlib.util, sys\n"
           "from pathlib import Path\n"
           "spec = importlib.util.spec_from_file_location('checker_push_range', sys.argv[1])\n"
           "module = importlib.util.module_from_spec(spec)\n"
           "sys.modules[spec.name] = module\n"
           "spec.loader.exec_module(module)\n"
           "print(module.refresh_upstream(Path(sys.argv[2]), 'origin', key=sys.argv[3]))\n")


class BaseFetchFailsOnceAndNeverPrompts(StaleBaseFixture):
    """cmux#41715 review: a failed base fetch is tried once per hook run, and no route git takes can prompt.

    Each pre-push checker is its own process: a failed fetch wrote no stamp, so every checker of one hook run tried
    the same fetch again (up to 30 s each). And a fetch only cleared the prompts it named: a GIT_SSH program got no
    BatchMode, and anything the fetch started (ssh, a GIT_SSH wrapper, a credential helper) shared the hook's
    session, so it could open the terminal and ask. One row per way git connects or asks."""

    def setUp(self) -> None:
        super().setUp()
        self.push_range = load("stale_base_push_range_fails", "scripts/cmux-next/push_range.py")
        self.key = f"refs/heads/topic {self.git(self.work, 'rev-parse', 'HEAD')} refs/heads/topic {'0' * 40}"
        self.record = self.tmp / "record.jsonl"
        self.asker = self.tmp / "askpass"
        self.asker.write_text(f"#!/bin/sh\ntouch '{self.tmp / 'asked'}'\necho secret\n")
        self.asker.chmod(0o755)
        for name in ("GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"):
            os.environ.pop(name, None)

    def fake(self, name: str, code: int = 255) -> Path:
        folder = self.tmp / "bin" / name.replace("/", "_")
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / name
        path.write_text(FAKE_PROGRAM.format(python=sys.executable, record=str(self.record), code=code))
        path.chmod(0o755)
        return path

    def calls(self) -> list[dict]:
        if not self.record.exists():
            return []
        calls = [json.loads(line) for line in self.record.read_text().splitlines() if line.strip()]
        # `GIT_SSH -G`: git's probe of which ssh an unknown GIT_SSH program is (ssh.variant auto); it connects nowhere.
        return [call for call in calls if call["args"][:1] != ["-G"]]

    def over_ssh(self) -> None:
        self.git(self.work, "remote", "set-url", "origin", "ssh://fixture.invalid/origin.git")

    def checker(self, run: str) -> subprocess.Popen:
        env = {**os.environ, "CMUX_PREPUSH_RUN": run}
        return subprocess.Popen([sys.executable, "-I", "-c", CHECKER, str(ROOT / "scripts/cmux-next/push_range.py"),
                                 str(self.work), self.key], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, stdin=subprocess.DEVNULL)

    def finish(self, proc: subprocess.Popen) -> str:
        out, err = proc.communicate(timeout=120)
        self.assertEqual(proc.returncode, 0, err)
        return out.strip()

    def assert_no_prompt(self, call: dict) -> None:
        self.assertNotEqual(call["sid"], os.getsid(0),
                            f"{call['name']} ran in the hook's session, so it could open the terminal and ask")
        self.assertIn(call["env"]["GIT_ASKPASS"], ("", None))
        self.assertIn(call["env"]["SSH_ASKPASS"], ("", None))
        self.assertFalse((self.tmp / "asked").exists(), "no askpass helper ran")

    # -- F1: one fetch per hook run, a failed one included -------------------------------------------------------

    def test_a_failed_fetch_is_tried_once_by_the_checkers_of_one_hook_run(self):
        self.over_ssh()
        os.environ["GIT_SSH_COMMAND"] = str(self.fake("ssh"))
        notes = [self.finish(self.checker("run-1")) for _ in range(3)]
        self.assertEqual(len(self.calls()), 1, f"three checker processes, one fetch: {self.calls()}")
        for note in notes:
            self.assertIn("could not be fetched", note, "every checker still says the base is stale")

    def test_checkers_that_start_together_fetch_once(self):
        self.over_ssh()
        os.environ["GIT_SSH_COMMAND"] = str(self.fake("ssh"))
        procs = [self.checker("run-1") for _ in range(3)]
        notes = [self.finish(proc) for proc in procs]
        self.assertEqual(len(self.calls()), 1, f"three checkers at once, one fetch: {self.calls()}")
        self.assertTrue(all("could not be fetched" in note for note in notes), notes)

    def test_the_next_hook_run_tries_a_failed_fetch_again(self):
        self.over_ssh()
        os.environ["GIT_SSH_COMMAND"] = str(self.fake("ssh"))
        self.finish(self.checker("run-1"))
        self.finish(self.checker("run-2"))
        self.assertEqual(len(self.calls()), 2, "a failure stamp holds for its own run only")

    # -- F2 and its class: every route git takes to connect or ask -----------------------------------------------

    def fetch_note(self) -> str:
        return self.push_range.refresh_upstream(self.work, "origin")

    def test_git_ssh_command_gets_batchmode_and_no_terminal(self):
        self.over_ssh()
        os.environ.update(GIT_SSH_COMMAND=str(self.fake("ssh")), GIT_ASKPASS=str(self.asker),
                          SSH_ASKPASS=str(self.asker), SSH_ASKPASS_REQUIRE="force")
        self.assertIn("could not be fetched", self.fetch_note())
        [call] = self.calls()
        self.assertIn("BatchMode=yes", call["args"])
        self.assert_no_prompt(call)

    def test_core_sshcommand_gets_batchmode_and_no_terminal(self):
        self.over_ssh()
        self.git(self.work, "config", "core.sshCommand", str(self.fake("ssh")))
        self.assertIn("could not be fetched", self.fetch_note())
        [call] = self.calls()
        self.assertIn("BatchMode=yes", call["args"])
        self.assert_no_prompt(call)

    def test_git_ssh_set_to_openssh_gets_batchmode(self):
        self.over_ssh()
        os.environ["GIT_SSH"] = str(self.fake("ssh"))
        self.assertIn("could not be fetched", self.fetch_note())
        [call] = self.calls()
        self.assertIn("BatchMode=yes", call["args"], "GIT_SSH takes no options, so OpenSSH could still ask")
        self.assert_no_prompt(call)

    def test_a_git_ssh_wrapper_runs_with_no_terminal(self):
        self.over_ssh()
        os.environ["GIT_SSH"] = str(self.fake("ssh-wrapper"))
        self.assertIn("could not be fetched", self.fetch_note())
        [call] = self.calls()
        self.assertNotIn("BatchMode=yes", call["args"], "a wrapper's options are its own")
        self.assert_no_prompt(call)

    def test_an_http_credential_helper_and_askpass_never_prompt(self):
        import http.server
        import threading

        class WantsCredentials(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 (http.server's name)
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), WantsCredentials)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_address[1]
        self.git(self.work, "remote", "set-url", "origin", f"http://127.0.0.1:{port}/origin.git")
        self.git(self.work, "config", "credential.helper", str(self.fake("git-credential-fixture", code=0)))
        self.git(self.work, "config", "core.askPass", str(self.asker))
        for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
            os.environ.pop(name, None)
        os.environ.update(GIT_ASKPASS=str(self.asker), SSH_ASKPASS=str(self.asker), GIT_TERMINAL_PROMPT="1",
                          GCM_INTERACTIVE="always", no_proxy="*", NO_PROXY="*")
        self.assertIn("could not be fetched", self.fetch_note())
        helpers = [call for call in self.calls() if call["args"][:1] == ["get"]]
        self.assertTrue(helpers, f"the credential helper was asked: {self.calls()}")
        for call in helpers:
            self.assertEqual(call["env"]["GIT_TERMINAL_PROMPT"], "0")
            self.assertEqual(call["env"]["GCM_INTERACTIVE"], "never")
            self.assert_no_prompt(call)


    # -- cmux#41750 review: the fetch ends with whatever cancels its caller -------------------------------------

    def slow_ssh(self) -> Path:
        """An ssh that never answers; each start writes its pid to self.ssh_pids (git's `-G` probe connects nowhere)."""
        self.ssh_pids = self.tmp / "slow-ssh.pids"
        slow = self.tmp / "bin" / "slow" / "ssh"
        slow.parent.mkdir(parents=True, exist_ok=True)
        slow.write_text(f"#!{sys.executable}\nimport os, sys, time\n"
                        f"if sys.argv[1:2] != ['-G']:\n"
                        f"    open({str(self.ssh_pids)!r}, 'a').write(f'{{os.getpid()}}\\n')\n"
                        f"    time.sleep(120)\n")
        slow.chmod(0o755)
        return slow

    def ssh_started(self) -> list[int]:
        return [int(line) for line in self.ssh_pids.read_text().split()] if self.ssh_pids.exists() else []

    def assert_fetch_gone(self, started: list[int], why: str) -> None:
        """Every ssh in STARTED exits within 5 s (one the test started itself and finds alive is then killed)."""
        def alive(pid: int) -> bool:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            except PermissionError:
                return True
            try:  # an orphan its reaper has not collected yet is gone too
                return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
            except (OSError, IndexError):
                return True

        deadline = time.monotonic() + 5
        while any(alive(pid) for pid in started) and time.monotonic() < deadline:
            time.sleep(0.1)
        left = [pid for pid in started if alive(pid)]
        for pid in left:
            os.kill(pid, 9)
        self.assertEqual(left, [], why)

    def assert_attempt_stamped(self) -> None:
        stamp = Path(self.git(self.work, "rev-parse", "--path-format=absolute", "--git-common-dir")) / \
            "cmux-guardrails" / self.push_range.UPSTREAM_REFRESH_FILE
        self.assertTrue(stamp.exists(), "the cancelled fetch is stamped for its hook run")
        note = self.finish(self.checker("run-1"))
        self.assertIn("could not be fetched", note)
        self.assertEqual(len(self.ssh_started()), 1, "the next checker of the run did not fetch again")

    def test_the_fast_tier_s_cancel_ends_the_fetch_and_stamps_the_attempt(self):
        """prepush_fast_tier.py kills its worker's process group with SIGKILL after 4 s. The fetch ran in a session
        of its own, so it escaped: ssh ran on with no 30 s limit and no stamp, and the next checker of the same hook
        run fetched again beside it. Runs the real fast-tier entry point against an ssh that never answers."""
        self.over_ssh()
        os.environ.update(GIT_SSH_COMMAND=str(self.slow_ssh()), CMUX_PREPUSH_RUN="run-1")
        tier = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/cmux-next/prepush_fast_tier.py"),
                               "--repo", str(self.work), "--remote", "origin"], input=self.key + "\n",
                              capture_output=True, text=True, timeout=60)
        self.assertIn("4s budget exhausted", tier.stdout, f"the fast tier cancelled its worker: {tier.stdout}")
        self.assertTrue(self.ssh_started(), "the fetch reached ssh before the cancel")
        self.assert_fetch_gone(self.ssh_started(), "the fetch's ssh outlived the fast tier that cancelled it")
        self.assert_attempt_stamped()

    def test_ctrl_c_on_a_checker_ends_the_fetch_and_stamps_the_attempt(self):
        """cmux#41750 review: Ctrl-C (SIGINT) on a checker mid-fetch. The terminal's SIGINT reaches only the
        foreground process group, which the fetch's own session is not in, and subprocess.run answers the
        KeyboardInterrupt by killing its own child alone. The checker is interrupted once its fetch reaches ssh."""
        self.over_ssh()
        os.environ["GIT_SSH_COMMAND"] = str(self.slow_ssh())
        proc = self.checker("run-1")
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        deadline = time.monotonic() + 30
        while not self.ssh_started() and time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertTrue(self.ssh_started(), "the checker's fetch reached ssh")
        proc.send_signal(signal.SIGINT)
        proc.communicate(timeout=30)
        self.assertNotEqual(proc.returncode, 0, "the checker stopped on Ctrl-C")
        self.assert_fetch_gone(self.ssh_started(), "the fetch's ssh outlived the checker stopped by Ctrl-C")
        self.assert_attempt_stamped()

    # -- cmux#41765 review: a timeout is said only when the fetch's guard ended it --------------------------------

    def git_whose_fetch(self, body: str) -> None:
        """Puts a `git` first on PATH that runs BODY (python) for `fetch` and is the real git for anything else."""
        real = shutil.which("git")
        folder = self.tmp / "bin" / "git-stub"
        folder.mkdir(parents=True, exist_ok=True)
        stub = folder / "git"
        stub.write_text(f"#!{sys.executable}\nimport os, sys, time\n"
                        f"if 'fetch' in sys.argv[1:]:\n{body}\n"
                        f"os.execv({real!r}, [{real!r}, *sys.argv[1:]])\n")
        stub.chmod(0o755)
        os.environ["PATH"] = f"{folder}{os.pathsep}{os.environ.get('PATH', '')}"

    def test_a_git_that_exits_124_at_once_is_reported_with_its_real_exit(self):
        """cmux#41765 review: the keeper's exit 124 was read as a timeout every time, so a git (or a wrapper) that
        exits 124 at once was reported as "no answer in 30s", hiding the real failure."""
        self.git_whose_fetch("    sys.exit(124)")
        started = time.monotonic()
        note = self.fetch_note()
        self.assertLess(time.monotonic() - started, 20, "the fetch failed at once, not at the limit")
        self.assertIn("could not be fetched (exit 124)", note)
        self.assertNotIn("no answer", note)

    def test_a_fetch_the_guard_ends_at_the_limit_is_a_timeout(self):
        self.git_whose_fetch("    time.sleep(60)")
        with unittest.mock.patch.object(self.push_range, "UPSTREAM_FETCH_SECONDS", 1):
            note = self.fetch_note()
        self.assertIn("could not be fetched (no answer in 1s)", note)

class SshBatchModeWins(StaleBaseFixture):
    """cmux#41750 review: OpenSSH keeps the FIRST value of an option, so `-o BatchMode=yes` appended after a user's
    `BatchMode=no` lost, and ssh could still ask. Each row resolves the command the fetch would run with the real ssh
    (`ssh -G` connects nowhere) and reads the batchmode it ends up with."""

    def setUp(self) -> None:
        super().setUp()
        self.push_range = load("stale_base_push_range_batch", "scripts/cmux-next/push_range.py")
        for name in ("GIT_SSH", "GIT_SSH_COMMAND"):
            os.environ.pop(name, None)
        self.ssh = shutil.which("ssh")
        self.assertIsNotNone(self.ssh, "these rows need OpenSSH's client on PATH")

    def batchmode(self) -> str:
        command = self.push_range._no_prompt_env(self.work).get("GIT_SSH_COMMAND", "")
        self.assertTrue(command, "the fetch runs ssh through a GIT_SSH_COMMAND it set")
        out = subprocess.run(["sh", "-c", f"{command} -F /dev/null -G fixture.invalid"], capture_output=True,
                             text=True, stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return next(line.split()[1] for line in out.stdout.splitlines() if line.startswith("batchmode "))

    def test_git_ssh_as_a_full_path_to_openssh(self):
        os.environ["GIT_SSH"] = self.ssh
        self.assertEqual(self.batchmode(), "yes")

    def test_git_ssh_command_that_turns_batchmode_off(self):
        os.environ["GIT_SSH_COMMAND"] = "ssh -o BatchMode=no"
        self.assertEqual(self.batchmode(), "yes")

    def test_core_sshcommand_that_turns_batchmode_off(self):
        self.git(self.work, "config", "core.sshCommand", f"{self.ssh} -o BatchMode=no")
        self.assertEqual(self.batchmode(), "yes")

    def test_a_quoted_program_path_keeps_its_arguments(self):
        os.environ["GIT_SSH_COMMAND"] = f"'{self.ssh}' -oBatchMode=no -o ConnectTimeout=7"
        self.assertEqual(self.batchmode(), "yes")


if __name__ == "__main__":
    unittest.main()
