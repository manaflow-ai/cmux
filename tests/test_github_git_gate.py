#!/usr/bin/env python3
"""Every git request to github.com from one Mac passes one gate (scripts/github_git_gate.py).

On 2026-11-25 github.com blocked the build Mac (403 "Access to this site has been restricted")
after its blobless clones sent about 1,900 lazy blob fetches in a day, one request per object,
from many agents at once and with nothing pausing them once GitHub began refusing (#57822).
These checks pin the class fix: git's https://github.com/ requests (lazy fetches included)
reach the helper, run at most SLOTS at a time and within a per-minute budget, and one host-wide
refusal backs every later request off instead of letting each retry. A shared full mirror,
adopted as an alternate, answers a blobless clone's blob reads locally, so they never become
lazy fetches at all, and many agents asking for a sync at once cost one fetch. Routing never
changes what `git remote -v` prints, so gh still finds the repository.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "github_git_gate.py"
_spec = importlib.util.spec_from_file_location("github_git_gate", SCRIPT)
gate_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate_mod)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).with_name("git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_fixture_spec)
_fixture_spec.loader.exec_module(git_fixture_env)

BLOCKED = "fatal: unable to access 'https://github.com/manaflow-ai/cmux.git/': The requested URL returned error: 403\n"
LAZY_FETCH = ("git -c fetch.negotiationAlgorithm=noop fetch origin --no-tags --no-write-fetch-head "
              "--recurse-submodules=no --filter=blob:none --stdin")
# A stand-in for `git remote-https`: echoes stdin to stdout (the helper protocol is stdio), prints
# CMUX_TEST_STDERR to stderr and exits CMUX_TEST_RC. With CMUX_TEST_NO_READ it reads nothing: git keeps the
# helper's stdin open for its answer, so a helper started by git itself must not wait for EOF.
FAKE_HELPER = json.dumps([sys.executable, "-I", "-c",
                          "import os,sys; os.environ.get('CMUX_TEST_NO_READ') or sys.stdout.write(sys.stdin.read()); "
                          "sys.stderr.write(os.environ.get('CMUX_TEST_STDERR','')); "
                          "sys.stderr.write('low-speed=%s/%s\\n' % (os.environ.get('GIT_HTTP_LOW_SPEED_LIMIT'), "
                          "os.environ.get('GIT_HTTP_LOW_SPEED_TIME'))); "
                          "sys.exit(int(os.environ.get('CMUX_TEST_RC','0')))"])


class Clock:
    def __init__(self) -> None:
        self.now = 1_000_000.0
        self.slept: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


class Case(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.clock = Clock()

    def gate(self, **env: str) -> "gate_mod.Gate":
        return gate_mod.Gate(self.dir / "state", dict(env), clock=self.clock, sleep=self.clock.sleep)


class Classify(Case):
    def test_host_wide_refusals_back_off_and_access_errors_do_not(self) -> None:
        self.assertEqual(gate_mod.classify(BLOCKED, 128), "block")
        self.assertEqual(gate_mod.classify("error: RPC failed; HTTP 429 curl 22\n", 128), "block")
        self.assertEqual(gate_mod.classify("gh: gitmon refuses to schedule us: fail-fast:network\n", 1), "block")
        self.assertEqual(gate_mod.classify("remote: Permission to manaflow-ai/cmux.git denied to bot.\n" + BLOCKED, 128),
                         "error")
        self.assertEqual(gate_mod.classify("The requested URL returned error: 502\n", 128), "server")
        self.assertEqual(gate_mod.classify("fatal: early EOF\n", 128), "error")
        self.assertEqual(gate_mod.classify(BLOCKED, 0), "ok")

    def test_kind_names_lazy_blob_fetches(self) -> None:
        self.assertEqual(gate_mod.request_kind(LAZY_FETCH), "lazy")
        self.assertEqual(gate_mod.request_kind("git fetch -q --no-tags origin feat-cmux-next"), "fetch")
        self.assertEqual(gate_mod.request_kind("git push origin HEAD"), "push")
        self.assertEqual(gate_mod.request_kind("git ls-remote https://github.com/a/b.git"), "ls-remote")


class Backoff(Case):
    def test_one_refusal_holds_every_later_request_and_doubles_until_a_success(self) -> None:
        gate = self.gate()
        gate.record("block", BLOCKED)
        slot, waited, refused = gate.admit("fetch")
        self.assertIsNone(slot)
        self.assertIn("refused git traffic", refused)
        self.assertEqual(waited, 0.0)
        self.assertEqual(self.clock.slept, [], "a long backoff fails at once rather than waiting")

        self.clock.now += gate_mod.BLOCK_BACKOFF + 1
        slot, _, refused = gate.admit("fetch")
        self.assertEqual(refused, "")
        slot.close()

        gate.record("block", BLOCKED)  # second strike in a row: twice as long
        remaining, state = gate.backoff_remaining()
        self.assertEqual(state["strikes"], 2)
        self.assertEqual(remaining, 2 * gate_mod.BLOCK_BACKOFF)

        gate.record("ok", "")
        self.assertEqual(gate.backoff_remaining()[0], 0.0)
        self.assertEqual(gate.read_state()["strikes"], 0)

    def test_backoff_is_capped_and_a_short_one_is_waited_out(self) -> None:
        gate = self.gate(CMUX_GH_GATE_BACKOFF_WAIT="20")
        for _ in range(12):
            gate.record("block", BLOCKED)
        self.assertEqual(gate.backoff_remaining()[0], gate_mod.BLOCK_BACKOFF_CAP)

        gate = self.gate(CMUX_GH_GATE_BACKOFF_WAIT="20")
        gate.record("ok", "")
        gate.record("server", "The requested URL returned error: 503")
        slot, waited, refused = gate.admit("fetch")
        self.assertEqual(refused, "")
        self.assertEqual(self.clock.slept, [gate_mod.SERVER_BACKOFF])
        self.assertEqual(waited, gate_mod.SERVER_BACKOFF)
        slot.close()

    def test_other_failures_do_not_back_off(self) -> None:
        gate = self.gate()
        gate.record("error", "fatal: early EOF")
        self.assertEqual(gate.backoff_remaining()[0], 0.0)


class Budget(Case):
    def test_lazy_fetches_get_their_own_smaller_minute_budget(self) -> None:
        gate = self.gate(CMUX_GH_GATE_LAZY_PER_MINUTE="3", CMUX_GH_GATE_PER_MINUTE="10", CMUX_GH_GATE_MAX_WAIT="5")
        for _ in range(3):
            slot, _, refused = gate.admit("lazy")
            self.assertEqual(refused, "")
            slot.close()
        slot, _, refused = gate.admit("lazy")
        self.assertIsNone(slot)
        self.assertIn("lazy blob fetches", refused)
        slot, _, refused = gate.admit("fetch")  # an explicit fetch still has budget
        self.assertEqual(refused, "")
        slot.close()

    def test_a_full_window_waits_for_its_oldest_token(self) -> None:
        gate = self.gate(CMUX_GH_GATE_PER_MINUTE="2", CMUX_GH_GATE_MAX_WAIT="120")
        for _ in range(2):
            gate.admit("fetch")[0].close()
            self.clock.now += 10
        slot, waited, refused = gate.admit("fetch")
        self.assertEqual(refused, "")
        self.assertEqual(self.clock.slept, [gate_mod.WINDOW - 20])
        self.assertEqual(waited, gate_mod.WINDOW - 20)
        slot.close()


class Slots(Case):
    def test_at_most_slots_requests_run_at_once(self) -> None:
        gate = self.gate(CMUX_GH_GATE_SLOTS="2", CMUX_GH_GATE_MAX_WAIT="1")
        held = [gate.try_slot(), gate.try_slot()]
        self.assertTrue(all(held))
        self.assertIsNone(gate.try_slot())
        slot, _, refused = gate.admit("fetch")
        self.assertIsNone(slot)
        self.assertIn("slots stayed busy", refused)
        held.pop().close()
        slot, _, refused = gate.admit("fetch")
        self.assertEqual(refused, "")
        for handle in (slot, *held):
            handle.close()


class Helper(Case):
    def run_helper(self, stdin: str = "", **extra: str) -> subprocess.CompletedProcess:
        env = git_fixture_env.fixture_env({
            **os.environ,
            "CMUX_GH_GATE_STATE": str(self.dir / "state"),
            "CMUX_GH_GATE_REAL_HELPER": FAKE_HELPER,
            "CMUX_GH_GATE_PARENT_PID": "1",
            "CMUX_GH_GATE_PARENT_ARGS": LAZY_FETCH,
            **extra,
        })
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "helper", "origin", "https://github.com/a/b.git"],
                              input=stdin, capture_output=True, text=True, env=env, timeout=60)

    def events(self) -> list[dict]:
        path = self.dir / "state" / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_helper_passes_the_protocol_through_and_logs_the_request(self) -> None:
        done = self.run_helper("capabilities\n\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "capabilities\n\n")
        [event] = self.events()
        self.assertEqual((event["kind"], event["result"], event["rc"]), ("lazy", "ok", 0))
        self.assertIn(f"low-speed={gate_mod.LOW_SPEED_BYTES}/{gate_mod.LOW_SPEED_SECONDS}", done.stderr,
                      "a stalled transfer is aborted by git rather than holding a slot for hours")
        mine = self.run_helper(GIT_HTTP_LOW_SPEED_LIMIT="1000", GIT_HTTP_LOW_SPEED_TIME="30")
        self.assertIn("low-speed=1000/30", mine.stderr, "a caller's own floor wins")

    def test_a_blocked_answer_stops_the_next_request_before_it_reaches_github(self) -> None:
        first = self.run_helper(CMUX_TEST_STDERR=BLOCKED, CMUX_TEST_RC="128")
        self.assertEqual(first.returncode, 128)
        self.assertIn("returned error: 403", first.stderr)
        second = self.run_helper(CMUX_TEST_STDERR="the real helper ran\n")
        self.assertEqual(second.returncode, gate_mod.REFUSED_EXIT)
        self.assertNotIn("the real helper ran", second.stderr)
        self.assertIn("not sending this git request to github.com", second.stderr)
        self.assertEqual([e["result"] for e in self.events()], ["block", "refused"])
        bypass = self.run_helper(CMUX_GH_GATE_BYPASS="1", CMUX_TEST_STDERR="the real helper ran\n")
        self.assertIn("the real helper ran", bypass.stderr)

    def test_a_broken_gate_still_runs_git(self) -> None:
        (self.dir / "state").write_text("not a folder")
        done = self.run_helper("x\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "x\n")
        self.assertIn("gate unavailable", done.stderr)


class Routing(Case):
    def setUp(self) -> None:
        super().setUp()
        self.env = git_fixture_env.fixture_env(dict(os.environ))
        self.repo = self.dir / "repo"
        git_fixture_env.init_repo(self.repo)
        self.git("remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git")
        self.git("remote", "add", "fork", "https://gitlab.example.invalid/a/b.git")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=self.env, capture_output=True,
                              text=True, timeout=60).stdout

    def test_routing_sends_github_remotes_through_the_helper_and_keeps_their_urls(self) -> None:
        self.assertEqual(gate_mod.route_repo(str(self.repo), self.env), ["origin"], "only github.com https remotes")
        # gh reads `git remote -v`; the old url.ghgate::...insteadOf rule made it print ghgate::https://..., and
        # gh then found no GitHub remote in any repository on the machine.
        self.assertIn("origin\thttps://github.com/manaflow-ai/cmux.git (fetch)", self.git("remote", "-v").split("\n"))
        worktree = self.dir / "wt"
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "x")
        self.git("worktree", "add", "-q", "--detach", str(worktree))
        bin_dir = self.dir / "bin"
        gate_mod.write_helper(bin_dir, self.dir / "share", sys.executable)
        env = {**self.env,
               "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
               "CMUX_GH_GATE_STATE": str(self.dir / "state"),
               "CMUX_GH_GATE_REAL_HELPER": FAKE_HELPER,
               "CMUX_TEST_STDERR": "fake remote-https\n",
               "CMUX_TEST_RC": "1",
               "CMUX_TEST_NO_READ": "1",
               "GIT_TERMINAL_PROMPT": "0"}
        done = subprocess.run(["git", "-C", str(worktree), "fetch", "origin"], capture_output=True, text=True,
                              env=env, timeout=60)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("fake remote-https", done.stderr, "a worktree of a routed clone is routed too")
        [event] = [json.loads(line) for line in (self.dir / "state" / "events.jsonl").read_text().splitlines()]
        self.assertEqual((event["url"], event["kind"]), ("https://github.com/manaflow-ai/cmux.git", "fetch"))

        self.assertEqual(gate_mod.unroute_repo(str(self.repo), self.env), ["origin"])
        self.assertEqual(self.git("config", "--get-regexp", r"remote\..*\.url").count("ghgate"), 0)

    def test_scan_finds_clones_not_worktrees(self) -> None:
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "x")
        self.git("worktree", "add", "-q", "--detach", str(self.dir / "wt"))
        self.assertEqual(gate_mod.find_clones([str(self.dir)]), [str(self.repo)])


class Prefetch(Case):
    def test_one_request_fetches_every_blob_a_revision_lacks(self) -> None:
        env = git_fixture_env.fixture_env(dict(os.environ))
        server = self.dir / "server"
        git_fixture_env.init_repo(server)
        for name in ("a", "b", "c"):
            (server / name).write_text(f"{name}\n")
        git = lambda repo, *args: subprocess.run(["git", "-C", str(repo), *args], check=True, env=env,
                                                 capture_output=True, text=True).stdout
        git(server, "add", ".")
        git(server, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
        git(server, "config", "uploadpack.allowFilter", "true")
        clone = self.dir / "clone"
        git_fixture_env.clone_repo(f"file://{server}", clone, "-q", "--no-checkout", "--filter=blob:none")
        self.assertEqual(len(gate_mod.missing_blobs(str(clone), ["HEAD"])), 3)
        pack = Path(git(clone, "rev-parse", "--git-path", "objects/pack").strip())
        if not pack.is_absolute():
            pack = clone / pack
        before = set(pack.glob("*.promisor"))
        self.assertEqual(gate_mod.prefetch(str(clone), "origin", ["HEAD"]), 0)
        self.assertEqual(gate_mod.missing_blobs(str(clone), ["HEAD"]), [])
        self.assertEqual(len(set(pack.glob("*.promisor")) - before), 1, "all three blobs in one fetch")


class Audit(Case):
    def test_audit_counts_single_object_promisor_packs(self) -> None:
        pack = self.dir / "clone.git" / "objects" / "pack"
        pack.mkdir(parents=True)
        for index, objects in enumerate((1, 1, 40)):
            (pack / f"pack-{index}.promisor").write_text("")
            (pack / f"pack-{index}.idx").write_bytes(b"\0" * (8 + 1024 + 28 * objects + 40))
        written = (pack / "pack-0.idx").stat().st_mtime
        [row] = gate_mod.audit([str(self.dir / "clone.git")], 24, written + 25 * 3600)
        self.assertEqual(row["promisor_packs"], 0, "older than the window")
        [row] = gate_mod.audit([str(self.dir / "clone.git")], 24, written + 1)
        self.assertEqual((row["promisor_packs"], row["single_object"]), (3, 2))

    def test_audit_counts_leftover_tmp_packs(self) -> None:
        pack = self.dir / "clone.git" / "objects" / "pack"
        pack.mkdir(parents=True)
        for name in ("tmp_pack_a", "tmp_pack_b"):
            (pack / name).write_bytes(b"\0" * 1000)
        [row] = gate_mod.audit([str(self.dir / "clone.git")], 24, self.clock())
        self.assertEqual(row["tmp_packs"], 2)


class Mirror(Case):
    """A file:// source stands in for GitHub; pointing the clone's remote at a missing path after
    the clone proves a read was answered locally (any fetch would fail)."""

    def setUp(self) -> None:
        super().setUp()
        self.env = git_fixture_env.fixture_env(dict(os.environ))
        self.source = self.dir / "source"
        git_fixture_env.init_repo(self.source)
        self.git("-C", str(self.source), "config", "uploadpack.allowFilter", "true")
        self.commit("a.txt", "first\n")
        self.root = self.dir / "mirrors"

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *args], capture_output=True, text=True, env=self.env, check=check, timeout=60)

    def commit(self, name: str, text: str) -> None:
        (self.source / name).write_text(text)
        self.git("-C", str(self.source), "add", name)
        self.git("-C", str(self.source), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                 "commit", "-q", "-m", name)

    def sync(self, **kw) -> dict:
        kw.setdefault("seed", None)
        kw.setdefault("min_interval", 300)
        return gate_mod.mirror_sync(str(self.source), self.root, env=self.env, clock=self.clock,
                                    sleep=self.clock.sleep, **kw)

    def blobless_clone(self) -> Path:
        clone = self.dir / "clone"
        self.git("clone", "-q", "--no-checkout", "--filter=blob:none", f"file://{self.source}", str(clone))
        self.git("-C", str(clone), "remote", "set-url", "origin", str(self.dir / "gone"))
        return clone

    def test_an_adopted_blobless_clone_reads_blobs_from_the_mirror_not_the_network(self) -> None:
        self.assertEqual(self.sync()["result"], "made")
        clone = self.blobless_clone()
        self.assertNotEqual(self.git("-C", str(clone), "cat-file", "-p", "HEAD:a.txt", check=False).returncode, 0,
                            "without the mirror the blob would need a lazy fetch")
        done = gate_mod.mirror_adopt(str(clone), gate_mod.mirror_path(self.root, str(self.source)), False,
                                     env=self.env)
        self.assertTrue(done["added"])
        self.assertEqual(done["dropped_filters"], ["remote.origin.partialclonefilter"])
        self.assertEqual(self.git("-C", str(clone), "cat-file", "-p", "HEAD:a.txt").stdout, "first\n")
        worktree = self.dir / "wt"
        self.git("-C", str(clone), "worktree", "add", "-q", "--detach", str(worktree), "HEAD")
        self.assertEqual((worktree / "a.txt").read_text(), "first\n", "every worktree of the clone shares it")
        again = gate_mod.mirror_adopt(str(worktree), gate_mod.mirror_path(self.root, str(self.source)), False,
                                      env=self.env)
        self.assertFalse(again["added"])
        lines = (clone / ".git" / "objects" / "info" / "alternates").read_text().splitlines()
        self.assertEqual(len(lines), 1)

        gate_mod.mirror_unadopt(str(clone), gate_mod.mirror_path(self.root, str(self.source)), env=self.env)
        self.assertFalse((clone / ".git" / "objects" / "info" / "alternates").exists())
        self.assertEqual(self.git("-C", str(clone), "cat-file", "-p", "HEAD:a.txt").stdout, "first\n",
                         "unadopt copied the objects the clone reached through the mirror")

    def test_a_fresh_mirror_is_not_fetched_again_and_a_stale_one_is(self) -> None:
        self.sync()
        self.commit("b.txt", "second\n")
        self.assertEqual(self.sync()["result"], "fresh", "agents asking within the interval share one fetch")
        mirror = gate_mod.mirror_path(self.root, str(self.source))
        self.assertNotEqual(self.git("--git-dir", str(mirror), "cat-file", "-e", "HEAD:b.txt", check=False).returncode, 0)
        self.clock.now += 301
        self.assertEqual(self.sync()["result"], "fetched")
        self.assertEqual(self.git("--git-dir", str(mirror), "cat-file", "-p", "HEAD:b.txt").stdout, "second\n")
        self.assertEqual(self.git("--git-dir", str(mirror), "config", "gc.pruneExpire").stdout.strip(), "never",
                         "the mirror never prunes an object an adopted clone may need")

    def test_one_sync_at_a_time(self) -> None:
        mirror = gate_mod.mirror_path(self.root, str(self.source))
        mirror.parent.mkdir(parents=True)
        import fcntl
        with open(mirror.parent / f".{mirror.name}.lock", "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertEqual(self.sync(lock_wait=3)["result"], "busy")
        self.assertFalse(mirror.exists())

    def test_a_seed_makes_the_mirror_without_the_remote_and_must_hold_every_blob(self) -> None:
        seed = self.dir / "seed"
        self.git("clone", "-q", str(self.source), str(seed))
        done = self.sync(seed=str(seed))
        self.assertEqual(done["result"], "made")
        partial = self.blobless_clone()
        with self.assertRaisesRegex(RuntimeError, "partial clone"):
            gate_mod.mirror_sync("https://github.com/o/r.git", self.root, str(partial), 300, self.env,
                                 clock=self.clock)

    def test_mirror_paths_name_the_github_repository(self) -> None:
        for url in ("https://github.com/manaflow-ai/cmux.git", "https://github.com/manaflow-ai/cmux",
                    "ghgate::https://github.com/manaflow-ai/cmux.git", "git@github.com:manaflow-ai/cmux.git"):
            self.assertEqual(gate_mod.mirror_path(Path("/m"), url), Path("/m/manaflow-ai/cmux.git"), url)



if __name__ == "__main__":
    unittest.main()
