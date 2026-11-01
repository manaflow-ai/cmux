#!/usr/bin/env python3
"""Checks the Austin's-day harness parts that run without a Mac or an app (any host with git and
python3; seconds). Not a CI test: run it yourself after a harness change (README.md).

  python3 scripts/cmux-next/austins-day/selftest.py

- fake_claude.py runs the hooks of its --settings file on each tool call and stop as Claude Code
  does (sync hooks are waited for, `async` ones not), and logs a refused `cmux` call by its code;
- packs.py builds a partial clone with the asked number of packs that git reads (fsck, cat-file);
- summarize.py turns a run into the distributions and counts, and names Austin's failures it saw;
- hog.py stops by itself at its deadline.
"""
import json
import re
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def run(*argv, **kw):
    return subprocess.run(list(argv), capture_output=True, text=True, timeout=kw.pop("timeout", 120), **kw)


class FakeClaude(unittest.TestCase):
    def test_hooks_run_per_tool_call_and_refusals_are_logged(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = os.path.join(tmp, "wt")
            os.makedirs(work)
            for args in (["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "a"]):
                run("git", "-c", "user.name=a", "-c", "user.email=a@b", *args, cwd=work)
            settings = {"hooks": {
                "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "cat >/dev/null; echo {}", "timeout": 5}]}],
                "PostToolUse": [{"hooks": [{"type": "command", "command": "cat >/dev/null"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "cat >/dev/null; sleep 30", "async": True}]}],
                # Runs past its timeout: stopped and logged as a time-out.
                "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "cat >/dev/null; sleep 30", "timeout": 1}]}]}}
            path = os.path.join(tmp, "settings.json")
            json.dump(settings, open(path, "w"))
            cli = os.path.join(tmp, "cmux")
            with open(cli, "w") as f:
                f.write('#!/bin/sh\necho \'{"ok":false,"error":{"code":"server.busy"}}\'; exit 1\n')
            os.chmod(cli, 0o755)
            log = os.path.join(tmp, "log.jsonl")
            env = {**os.environ, "AD_AGENT_LOG": log, "AD_AGENT_DEADLINE": str(int(time.time()) + 4), "AD_TOOL_GAP": "0.1",
                   "AD_TOOLS_PER_TURN": "3", "AD_CLI_EVERY": "1", "CMUX_BUNDLED_CLI_PATH": cli}
            start = time.monotonic()
            run(sys.executable, "-I", os.path.join(HERE, "fake_claude.py"), "--settings", path, cwd=work, env=env, timeout=60)
            # The async Stop hook sleeps 30 s: the agent must not wait for it.
            self.assertLess(time.monotonic() - start, 20)
            records = [json.loads(line) for line in open(log)]
            kinds = [(r["kind"], r.get("event")) for r in records]
            self.assertTrue(records[0]["hooked"])
            tools = sum(1 for k in kinds if k[0] == "tool")
            self.assertGreater(tools, 0)
            self.assertEqual(sum(1 for k in kinds if k == ("hook", "PreToolUse")), tools)
            self.assertEqual(sum(1 for k in kinds if k == ("hook", "PostToolUse")), tools)
            self.assertTrue(all(r["code"] == "server.busy" for r in records if r["kind"] == "cli"))
            # Each tool call says which command it ran (a Read has none).
            self.assertTrue(all(r["argv"] for r in records if r["kind"] == "tool" and r["event"] != "Read"))
            hooks = [r for r in records if r["kind"] == "hook" and r["event"] in ("PreToolUse", "PostToolUse")]
            self.assertTrue(all(isinstance(r["cpu_ms"], float) and r["rc"] == 0 for r in hooks), hooks[:2])
            prompts = [r for r in records if r["kind"] == "hook" and r["event"] == "UserPromptSubmit"]
            self.assertTrue(prompts and all(r["rc"] == "timeout" and r["ms"] < 5000 for r in prompts), prompts)


class Packs(unittest.TestCase):
    def test_partial_clone_with_many_packs_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "fx")
            done = run(sys.executable, "-I", os.path.join(HERE, "packs.py"), "build", root, "--packs", "300", "--worktrees", "2",
                       "--files", "40", "--commits", "5")
            self.assertEqual(done.returncode, 0, done.stderr)
            pack_dir = os.path.join(root, "clone", ".git", "objects", "pack")
            self.assertEqual(sum(n.endswith(".pack") for n in os.listdir(pack_dir)), 300)
            self.assertEqual(run("git", "fsck", "--connectivity-only", cwd=os.path.join(root, "clone")).returncode, 0)
            oid = run("git", "hash-object", "--stdin", input="austins day promisor blob 7\n").stdout.strip()
            shown = run("git", "cat-file", "-p", oid, cwd=os.path.join(root, "clone"))
            self.assertEqual(shown.stdout, "austins day promisor blob 7\n")
            self.assertEqual(run("git", "status", "--porcelain", cwd=os.path.join(root, "wt-1")).returncode, 0)
            # Promisor remote: a partial clone.
            self.assertEqual(run("git", "config", "remote.origin.partialclonefilter", cwd=os.path.join(root, "clone")).stdout.strip(),
                             "blob:none")


def synthetic_run():
    series = {"samples": [{"t": i, "phase": "load", "load1": 100 + i, "swap_used_mb": 1000 * i, "memory_level": 20,
                           "app_rss_mb": 500 + i, "daemon_rss_mb": 200, "acpmux_rss_mb": 50} for i in range(10)],
              "server_stats": [{"phase": "start", "t": 0.0, "stats": {"connections": {"accepted": 10, "refused": 0, "peak": 5, "limit": 64}}},
                               {"phase": "load", "t": 50.0, "code": "server.busy", "stats": None},
                               {"phase": "end", "t": 100.0, "stats": {"connections": {"accepted": 510, "refused": 70, "peak": 64, "limit": 64},
                                                          "registry_lock": {"wait_us": {"count": 9, "p50": 1, "p90": 5_000_000,
                                                                                         "p99": 17_000_000, "max": 20_000_000}}}}],
              "person_cli": [{"phase": "load", "ms": float(i), "code": "server.busy" if i == 99 else None} for i in range(100)],
              "app_control": [], "closes": [{"made": True, "app_gone_ms": 30.0, "daemon_gone_ms": None}],
              "waves": [{"chats": [[{"method": "session/new", "ms": 40.0, "error": None},
                                    {"method": "session/prompt", "ms": 900.0, "error": None}],
                                   [{"method": "session/new", "ms": 10000.0, "error": "agent host start did not finish within 10s"}],
                                   [{"method": "session/new", "ms": 90000.0, "error": "agent_start did not finish within 90s"}],
                                   # A chat whose connect was refused (acpmux restarting): a failed open too.
                                   [{"method": "connection", "ms": None, "error": "ConnectionRefusedError: [Errno 61]"}]],
                         "answers": []}],
              "acpmux_pids": [{"pid": 1}, {"pid": 2}], "notes": []}
    return {"series": series, "agents": 80,
            "agent_records": [{"kind": "start", "hooked": True}] * 80 + [{"kind": "hook", "ms": 3, "rc": 0}],
            "app_probe": {"start": {"bounds_us": [1000, 10000, 100000], "counts": [5, 0, 0], "timeouts": 0, "max_us": 900},
                          "end": {"bounds_us": [1000, 10000, 100000], "counts": [95, 4, 1], "timeouts": 2, "max_us": 80000}},
            "app_log": {"ok": True, "no_reply_within": 3, "no_reply_by_cmd": {"put-frontend-projection": 3}},
            "stalls": [{"duration_ms": 300.0, "cpu_ms": 250.0, "cmux_frame": True, "symbol": "CmuxNextSidebar.Foo.bar()"},
                       {"duration_ms": 200.0, "cpu_ms": 150.0, "cmux_frame": False, "symbol": None},
                       # A WAIT: 27 % on the CPU (run 1's largest share), with a cmux frame: not a red.
                       {"duration_ms": 1000.0, "cpu_ms": 270.0, "cmux_frame": True, "symbol": "CmuxNextSidebar.Wait.row()"},
                       # The app's own cause wins over the CPU share.
                       {"duration_ms": 400.0, "cpu_ms": 390.0, "cause": "wait", "task_pageins": 12, "cmux_frame": True,
                        "symbol": "CmuxNextSidebar.Paged.in()"}], "host": "h"}


class Summary(unittest.TestCase):
    def test_distributions_counts_and_austins_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = os.path.join(tmp, "base-1")
            os.makedirs(run_dir)
            json.dump(synthetic_run(), open(os.path.join(run_dir, "run.json"), "w"))
            json.dump({"arm": "base", "sha": "abc", "round": 1, "host": "h"}, open(os.path.join(run_dir, "arm.json"), "w"))
            out = os.path.join(tmp, "summary.json")
            done = run(sys.executable, "-I", os.path.join(HERE, "summarize.py"), out, run_dir)
            self.assertEqual(done.returncode, 0, done.stderr)
            m = json.load(open(out))["runs"][0]["metrics"]
            self.assertEqual(m["person_cli_ms"], {"n": 100, "p50": 49.0, "p95": 94.0, "p99": 98.0, "max": 99.0})
            self.assertEqual(m["person_cli_refusals"], {"server.busy": 1})
            self.assertEqual(m["daemon_connections"]["refused"], 70)
            # As a rate over the run's own server-stats window (100 s) and as a share of connects.
            self.assertEqual(m["daemon_connections"]["refused_per_s"], 0.7)
            self.assertEqual(m["daemon_connections"]["refused_share"], round(70 / 570, 4))
            self.assertEqual(m["daemon_connections"]["accepted"], 500)
            # The probe over the run: end minus start (90, 4, 1); rank 91 of 95 is in the second bucket, 95 in the third.
            self.assertEqual(m["app_requests"]["n"], 95)
            self.assertEqual(m["app_requests"]["p50"], 1.0)
            self.assertEqual(m["app_requests"]["p95"], 10.0)
            self.assertEqual(m["app_requests"]["p99"], 100.0)
            self.assertEqual(m["app_requests"]["timeouts"], 2)
            self.assertEqual(m["workspace_close_not_done"], 1)
            self.assertEqual(m["acpmux_restarts"], 1)
            self.assertEqual((m["acpmux_opens"], m["acpmux_open_failures"], m["acpmux_connection_failures"]), (4, 3, 1))
            self.assertEqual((m["acpmux_host_start_timeouts"], m["acpmux_agent_start_timeouts"]), (1, 1))
            self.assertEqual(m["acpmux_open_failure_share"], 0.75)
            self.assertEqual(m["stalls_over_100ms_cmux"], 1)
            self.assertEqual([s["symbol"] for s in m["stall_sites"]], ["CmuxNextSidebar.Foo.bar()"])
            self.assertEqual(m["stall_sites"][0]["owner"], "a590 (sidebar-owner agent)")
            self.assertEqual((m["stall_code_count"], m["stall_code_total_ms"]), (2, 500.0))
            self.assertEqual((m["stall_wait_count"], m["stall_wait_total_ms"]), (2, 1400.0))
            self.assertEqual(m["stall_wait_task_pageins"], 12)
            self.assertTrue(all(m["austin_failure"].values()), m["austin_failure"])


def write_run(root, name, arm, sha, round_, quiet=False, scale=1.0):
    d = os.path.join(root, name)
    os.makedirs(d)
    run_ = synthetic_run()
    if quiet:  # a base that shows none of Austin's failures
        last = run_["series"]["server_stats"][-1]["stats"]
        last["connections"]["refused"] = 0
        last["registry_lock"]["wait_us"]["p99"] = 1000
        run_["series"]["person_cli"] = [{"phase": "load", "ms": 5.0, "code": None}]
        run_["series"]["acpmux_pids"] = [{"pid": 1}]
        run_["app_log"]["no_reply_within"] = 0
        run_["app_probe"]["end"]["timeouts"] = 0
        run_["stalls"] = []
        run_["series"]["waves"] = [{"answers": [{"method": "session/new", "ms": 40.0, "error": None}]}]
    for p in run_["series"]["person_cli"]:
        p["ms"] *= scale
    with open(os.path.join(d, "run.json"), "w") as f:
        json.dump(run_, f)
    with open(os.path.join(d, "arm.json"), "w") as f:
        json.dump({"arm": arm, "sha": sha, "round": round_, "host": "h"}, f)
    return d


def summarize(out, dirs, *flags):
    done = run(sys.executable, "-I", os.path.join(HERE, "summarize.py"), *flags, out, *dirs)
    assert done.returncode == 0, done.stderr
    with open(out) as f:
        return json.load(f)


REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def harness_commits():
    """(a commit, its parent) where the parent changes nothing in the harness folder: the latest commit
    that does not touch it, and one that does (its first commit)."""
    touching = run("git", "-C", REPO, "log", "--format=%H", "--", "scripts/cmux-next/austins-day").stdout.split()
    first = touching[-1]
    return first + "~1", first


class Validity(unittest.TestCase):
    def test_a_base_that_did_not_reproduce_gives_no_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
            dirs = [write_run(tmp, "base-1", "base", head, 1, quiet=True), write_run(tmp, "head-1", "head", head, 1),
                    write_run(tmp, "base-2", "base", head, 2), write_run(tmp, "head-2", "head", head, 2)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertTrue(summary["invalid"].startswith("invalid: base did not reproduce"), summary["invalid"])
            self.assertNotIn("comparison", summary)
            with open(os.path.join(tmp, "s.txt")) as f:
                self.assertIn("NO VERDICT", f.read())

    def test_a_head_that_edits_the_harness_gives_no_verdict(self):
        before, after = harness_commits()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = [write_run(tmp, "base-1", "base", before, 1), write_run(tmp, "head-1", "head", after, 1)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertEqual(summary["invalid"], "invalid: head edits the harness (scripts/cmux-next/austins-day differs between base and head)")


class Verdicts(unittest.TestCase):
    def test_better_only_outside_the_interval(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            # Five rounds: the head's person CLI times are a third of the base's every round: better.
            for r in range(1, 6):
                dirs += [write_run(tmp, f"base-{r}", "base", head, r), write_run(tmp, f"head-{r}", "head", head, r, scale=1 / 3)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertIsNone(summary["invalid"])
            metrics = summary["comparison"]["metrics"]
            self.assertEqual(metrics["person CLI p99 ms"]["verdict"], "better")
            self.assertLess(metrics["person CLI p99 ms"]["ci_high"], 0)
            # Identical in every round: the interval is [0, 0], which is not outside 0.
            self.assertEqual(metrics["daemon refused per s"]["verdict"], "no difference")
            # The base's lock wait p99 is 17 s (over the daemon's 100 ms stall line): it has a verdict.
            self.assertEqual(metrics["lock wait p99 us"]["verdict"], "no difference")

    def test_a_metric_whose_failure_the_base_did_not_show_is_invalid(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            for r in range(1, 3):
                for arm in ("base", "head"):
                    d = write_run(tmp, f"{arm}-{r}", arm, head, r)
                    path = os.path.join(d, "run.json")
                    with open(path) as f:
                        run_ = json.load(f)
                    run_["series"]["server_stats"][-1]["stats"]["registry_lock"]["wait_us"]["p99"] = 50_000  # under 100 ms
                    run_["app_probe"] = {"start": None, "end": None}  # a build without the probe
                    with open(path, "w") as f:
                        json.dump(run_, f)
                    dirs.append(d)
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertIsNone(summary["invalid"])  # the base still shows refused connections and the rest
            metrics = summary["comparison"]["metrics"]
            self.assertEqual(metrics["lock wait p99 us"]["verdict"], "invalid: base did not reproduce")
            self.assertEqual(metrics["app request p99 ms"]["verdict"], "not measured")
            self.assertEqual(metrics["daemon refused per s"]["verdict"], "no difference")
        with tempfile.TemporaryDirectory() as tmp:
            # Two rounds that disagree (one better, one worse): no difference.
            dirs = [write_run(tmp, "base-1", "base", head, 1), write_run(tmp, "head-1", "head", head, 1, scale=0.5),
                    write_run(tmp, "base-2", "base", head, 2), write_run(tmp, "head-2", "head", head, 2, scale=2.0)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertEqual(summary["comparison"]["metrics"]["person CLI p99 ms"]["verdict"], "no difference")


class AA(unittest.TestCase):
    def test_aa_passes_a_metric_whose_interval_contains_zero_and_fails_one_that_does_not(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            for r in range(1, 6):
                # Same build in both arms; the "head" runs' person CLI is 3x slower every round: a metric
                # with an arm bias (for example from the run order) that the A/A must catch.
                dirs += [write_run(tmp, f"base-{r}", "base", head, r), write_run(tmp, f"head-{r}", "head", head, r, scale=3.0)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs, "--aa")
            self.assertIn("person CLI p99 ms", summary["aa"]["failed"])
            self.assertIn("daemon refused per s", summary["aa"]["passed"])  # identical: [0, 0] contains 0
            self.assertIn("app request p99 ms", summary["aa"]["passed"])
            self.assertNotIn("person CLI p99 ms", summary["aa"]["passed"])

    def test_aa_needs_one_build(self):
        before, after = harness_commits()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = [write_run(tmp, "base-1", "base", before, 1), write_run(tmp, "head-1", "head", after, 1)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs, "--aa")
            self.assertTrue(summary["invalid"].startswith("invalid: an A/A needs one build"), summary["invalid"])


class ReadTimes(unittest.TestCase):
    def test_refused_is_a_rate_over_each_runs_own_window(self):
        """A base whose last answered server-stats came earlier has a smaller cumulative count but the same
        rate: no verdict from the read time alone (#28159 review)."""
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            for r in range(1, 6):
                for arm, end_t in (("base", 60.0), ("head", 100.0)):
                    d = write_run(tmp, f"{arm}-{r}", arm, head, r)
                    path = os.path.join(d, "run.json")
                    with open(path) as f:
                        run_ = json.load(f)
                    stats = run_["series"]["server_stats"]
                    stats[-1]["t"] = end_t
                    stats[-1]["stats"]["connections"]["refused"] = int(7 * end_t)  # 7 refused a second in both arms
                    stats[-1]["stats"]["connections"]["accepted"] = 10 + int(21 * end_t)
                    with open(path, "w") as f:
                        json.dump(run_, f)
                    dirs.append(d)
            metrics = summarize(os.path.join(tmp, "s.json"), dirs)["comparison"]["metrics"]
            self.assertEqual(metrics["daemon refused per s"]["verdict"], "no difference")
            self.assertEqual(metrics["daemon refused share of connects"]["verdict"], "no difference")

    def test_a_base_that_is_not_the_heads_ancestor_is_invalid(self):
        before, after = harness_commits()
        with tempfile.TemporaryDirectory() as tmp:
            # Swapped: the later commit as base.
            dirs = [write_run(tmp, "base-1", "base", after, 1), write_run(tmp, "head-1", "head", before, 1)]
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertTrue(summary["invalid"].startswith("invalid: base is not an ancestor of head"), summary["invalid"])


class ChatRecord(unittest.TestCase):
    def test_a_refused_connect_is_recorded_as_a_failed_open(self):
        """The driver's own one_chat and acpmux_call, against a socket path nobody listens on: the chat must
        hold its failed connection (re-review of a84ddb0e414: it was stored as [] and counted nothing)."""
        source = open(os.path.join(HERE, "driver.py")).read()
        start = source.index("def acpmux_call(")
        end = source.index("def waves(")
        namespace = {"socket": __import__("socket"), "time": time, "json": json, "worktrees": lambda: ["/tmp"]}
        with tempfile.TemporaryDirectory() as tmp:
            namespace["ACPMUX_HOME"] = tmp  # acpmux.sock does not exist there
            namespace["acpmux_socket_of"] = lambda home: os.path.join(home, "acpmux.sock")
            exec(compile(source[start:end], "driver.py", "exec"), namespace)
            out = []
            namespace["one_chat"](1, 0, out)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0][0]["method"], "connection")
        self.assertTrue(out[0][0]["error"])
        # And summarize counts it: 1 chat, 1 failed open.
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            run_["series"]["waves"] = [{"chats": out, "answers": [a for c in out for a in c]}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            m = summarize(os.path.join(tmp, "s.json"), [d])["runs"][0]["metrics"]
            self.assertEqual((m["acpmux_opens"], m["acpmux_open_failures"], m["acpmux_open_failure_share"]), (1, 1, 1.0))
            self.assertTrue(m["austin_failure"]["acpmux_open_failures"])


class OldRuns(unittest.TestCase):
    def test_a_run_from_before_the_chat_record_is_read(self):
        """Drivers before 152ee4f4d1e (the A/A's 02ebc4c61a0 among them) wrote "chats": 25 per wave: the
        summary must read them through the session/new fallback, not raise."""
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            run_["series"]["waves"] = [{"chats": 25, "answers": [
                {"method": "session/new", "ms": 40.0, "error": None},
                {"method": "session/prompt", "ms": 900.0, "error": None},
                {"method": "session/new", "ms": 10000.0, "error": "agent host start did not finish within 10s"}]},
                # A wave whose chats all failed to connect: no answers at all.
                {"chats": 25, "answers": []}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            m = summarize(os.path.join(tmp, "s.json"), [d])["runs"][0]["metrics"]
            self.assertEqual((m["acpmux_opens"], m["acpmux_open_failures"]), (2, 1))


class ClientList(unittest.TestCase):
    def test_the_client_list_output_is_read_as_the_cli_prints_it(self):
        """`cmux --json client list` prints the daemon's bare array (review of f8a8afbee55: it was read as {})."""
        source = open(os.path.join(HERE, "driver.py")).read()
        start = source.index("def client_list_entries(")
        end = source.index("def connection_holders(")
        namespace = {}
        exec(compile(source[start:end], "driver.py", "exec"), namespace)
        entries = namespace["client_list_entries"]
        sample = [{"id": "client_1", "name": "cmux-next", "client_kind": "app", "transport": "unix", "connected_seconds": "12"}]
        self.assertEqual(entries(sample), sample)
        self.assertEqual(entries({"value": sample}), sample)
        self.assertIsNone(entries(None))
        self.assertIsNone(entries({"error": "usage.invalid"}))


class LockHeldShare(unittest.TestCase):
    def test_held_share_is_the_change_of_count_times_mean_over_the_window(self):
        sys.path.insert(0, HERE)
        try:
            import importlib
            summarize_module = importlib.import_module("summarize")
        finally:
            sys.path.remove(HERE)
        share = summarize_module.lock_held_share
        first = {"registry_lock": {"hold_us": {"count": 1000, "mean": 500}}}       # 0.5 s held
        last = {"registry_lock": {"hold_us": {"count": 101000, "mean": 4250}}}     # 429.25 s held
        # (429.25 - 0.5) s over a 500 s window.
        self.assertEqual(share(first, last, 500.0), round(428.75 / 500, 4))
        self.assertIsNone(share(first, last, None))
        self.assertIsNone(share(first, {}, 500.0))
        # A daemon restart in the window (counters reset below the first read): clamped at 0, never negative.
        self.assertEqual(share(last, first, 500.0), 0)


class Scenario(unittest.TestCase):
    def test_the_arm_is_named_and_mixed_cli_rates_are_refused(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            for r in (1, 2):
                for arm in ("base", "head"):
                    d = write_run(tmp, f"{arm}-{r}", arm, head, r)
                    path = os.path.join(d, "run.json")
                    with open(path) as f:
                        run_ = json.load(f)
                    run_["opts"] = {"cli_every": 0}
                    with open(path, "w") as f:
                        json.dump(run_, f)
                    dirs.append(d)
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertEqual(summary["scenario_note"], "main arm: no agent cmux CLI calls (hooks and the app only)")
            self.assertIsNone(summary["invalid"])
            path = os.path.join(dirs[-1], "run.json")
            with open(path) as f:
                run_ = json.load(f)
            run_["opts"] = {"cli_every": 3}
            with open(path, "w") as f:
                json.dump(run_, f)
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertTrue(summary["invalid"].startswith("invalid: the runs use different agent CLI rates"), summary["invalid"])


class AAPerScenario(unittest.TestCase):
    def test_a_scenario_without_an_aa_is_marked_on_every_verdict(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = []
            for r in (1, 2, 3):
                for arm in ("base", "head"):
                    d = write_run(tmp, f"{arm}-{r}", arm, head, r)
                    path = os.path.join(d, "run.json")
                    with open(path) as f:
                        run_ = json.load(f)
                    run_["opts"] = {"cli_every": 0}  # the main arm: no A/A recorded for it in this test's checkout
                    with open(path, "w") as f:
                        json.dump(run_, f)
                    dirs.append(d)
            with open(os.path.join(HERE, "aa-failures.json")) as f:
                recorded = json.load(f).get("scenarios", {})
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            verdicts = [row["verdict"] for row in summary["comparison"]["metrics"].values()]
            if "0" in recorded:
                self.assertNotIn("aa_note", summary)
            else:
                self.assertTrue(summary["aa_note"].startswith("no A/A yet for this scenario (agent CLI rate 0)"))
                self.assertTrue(all(v.startswith("not A/A-checked: ") for v in verdicts), verdicts[:3])


class RevertPair(unittest.TestCase):
    def test_only_the_head_plus_a_real_revert_is_a_revert_pair(self):
        """B3 1d: before = after + one commit that reverts a commit of after's history. Built in a scratch repo,
        with the wrong bases the review of 2ea5ef95cc4 found: a merge, and an empty "Revert" commit."""
        sys.path.insert(0, HERE)
        try:
            import importlib
            sm = importlib.import_module("summarize")
        finally:
            sys.path.remove(HERE)
        with tempfile.TemporaryDirectory() as tmp:
            g = lambda *a: run("git", "-c", "user.name=a", "-c", "user.email=a@b", *a, cwd=tmp)
            sha = lambda ref="HEAD": run("git", "rev-parse", ref, cwd=tmp).stdout.strip()
            g("init", "-q", "-b", "main")
            with open(os.path.join(tmp, "f"), "w") as f:
                f.write("one\n")
            g("add", "f"); g("commit", "-q", "-m", "base")
            with open(os.path.join(tmp, "f"), "w") as f:
                f.write("two\n")
            g("commit", "-q", "-am", "the fix")
            fix = sha()
            with open(os.path.join(tmp, "g"), "w") as f:
                f.write("x\n")
            g("add", "g"); g("commit", "-q", "-m", "later work")
            head = sha()
            g("revert", "--no-edit", fix)
            before = sha()
            self.assertFalse(sm.base_is_ancestor(before, head, repo=tmp))
            self.assertTrue(sm.is_revert_pair(before, head, repo=tmp))
            # An empty commit titled "Revert ..." on the head reverts nothing.
            g("checkout", "-q", head)
            g("commit", "-q", "--allow-empty", "-m", "Revert \"the fix\"", "-m", f"This reverts commit {fix}.")
            self.assertFalse(sm.is_revert_pair(sha(), head, repo=tmp))
            # A merge whose first parent is the head.
            g("checkout", "-q", "-b", "side", fix)
            with open(os.path.join(tmp, "h"), "w") as f:
                f.write("y\n")
            g("add", "h"); g("commit", "-q", "-m", "side work")
            g("checkout", "-q", head)
            g("merge", "-q", "--no-ff", "-m", "Revert by merge", "side")
            self.assertFalse(sm.is_revert_pair(sha(), head, repo=tmp))


class NamedSites(unittest.TestCase):
    def test_a_site_moved_within_its_function_pairs_and_a_listed_absence_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            def lock_run(name, registry):
                run_ = synthetic_run()
                run_["series"]["locks"] = [{"t": 400.0, "code": None, "locks": {"registry": registry, "state": {}}}]
                d = os.path.join(tmp, name)
                os.makedirs(d)
                with open(os.path.join(d, "run.json"), "w") as f:
                    json.dump(run_, f)
                return summarize(os.path.join(tmp, name + ".json"), [d])["runs"][0]["metrics"]["lock_sites"]
            site = lambda line, total: {"site": f"crates/cmux-tui-core/src/mux/frontend_projection.rs:{line}", "acquisitions": 3,
                                        "hold_total_us": total, "hold_max_us": 9, "hold_p99_us": 8}
            before = lock_run("before", {"sites": 2, "by_hold_total": [site(9, 5000), site(13, 1)], "by_hold_p99": []})
            after = lock_run("after", {"sites": 2, "by_hold_total": [site(20, 40), site(24, 1)], "by_hold_p99": []})
            listed_absent = lock_run("absent", {"sites": 1, "by_hold_total": [site(24, 1)], "by_hold_p99": []})
            unknown = lock_run("unknown", {"sites": 30, "by_hold_total": [site(24, 1)], "by_hold_p99": []})
        key = "registry:terminal_registry_revision"
        self.assertEqual(before[key]["hold_total_us"], 5000)
        self.assertEqual(after[key]["hold_total_us"], 40)
        self.assertEqual(after[key]["sites"], ["crates/cmux-tui-core/src/mux/frontend_projection.rs:20"])
        self.assertEqual(listed_absent[key]["hold_total_us"], 0)
        self.assertIsNone(unknown[key]["hold_total_us"])
        # Absent from a full list: an upper bound, the smallest listed total (1 µs here), kept apart.
        self.assertEqual(unknown[key]["hold_total_us_at_most"], 1)
        self.assertIsNone(before[key]["hold_total_us_at_most"])

    def test_the_bound_on_the_text_line_is_rounded_up(self):
        """Review of 748dc589635: a 40,000 us bound printed as "at most 0.0 s"."""
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            listed = {"site": "crates/cmux-tui-core/src/mux/other.rs:5", "acquisitions": 1, "hold_total_us": 40_000,
                      "hold_max_us": 1, "hold_p99_us": 1}
            run_["series"]["locks"] = [{"t": 400.0, "code": None, "locks": {
                "registry": {"sites": 30, "by_hold_total": [listed], "by_hold_p99": [listed]}, "state": {}}}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            summarize(os.path.join(tmp, "s.json"), [d])
            with open(os.path.join(tmp, "s.txt")) as f:
                text = f.read()
        self.assertIn("registry:terminal_registry_revision: total hold absent from the top 20, so at most 0.1 s", text)


class ProcessKinds(unittest.TestCase):
    def test_the_holder_sample_names_what_its_processes_run(self):
        source = open(os.path.join(HERE, "driver.py")).read()
        start = source.index("def connection_holders(")
        end = source.index("def sampler(")
        app = "/Users/Shared/cmux-capture/slots/1/lease-x/app/cmux DEV t.app"
        namespace = {"re": re, "opts": type("O", (), {"app": app})(), "CLI": app + "/Contents/Resources/bin/cmux",
                     "CLI_TUI": app + "/Contents/Resources/bin/cmux-tui", "cli": None, "client_list_entries": None,
                     "HOLDERS_ERROR": [], "note": None, "json": json}
        exec(compile(source[start:end], "driver.py", "exec"), namespace)
        rows = [(1, 1, 1, app + "/Contents/Resources/bin/cmux --socket /tmp/s --json workspace list"),
                (2, 1, 1, app + "/Contents/Resources/bin/cmux --socket /tmp/s --json workspace list"),
                (3, 1, 1, app + "/Contents/Resources/bin/cmux __hook-append term_0123456789abcdef"),
                (4, 1, 1, "/home/x/.local/share/cmux-tui/bin/cmux-tui-hook claude PreToolUse"),
                # The hook helper beside the bundle binary: its path has spaces.
                (5, 1, 1, app + "/Contents/Resources/bin/cmux-tui-hook claude Stop")]
        out = namespace["connection_holders"](rows, ask_daemon=False)
        self.assertEqual(out["processes"], {"hook_helper": 2, "cli": 3, "other_bundle": 0})
        self.assertIn("<app>/Contents/Resources/bin/cmux-tui-hook claude Stop", out["process_kinds"]["hook_helper"])
        self.assertEqual(out["process_kinds"]["cli"], {"cmux workspace list": 2, "cmux __hook-append": 1})


class FirstAnswer(unittest.TestCase):
    def test_the_first_answer_is_session_new_plus_the_prompts_first_chunk(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            run_["series"]["waves"] = [{"answers": [], "chats": [
                [{"method": "session/new", "ms": 2000.0, "error": None},
                 {"method": "session/prompt", "ms": 2900.0, "first_chunk_ms": 300.0, "error": None}],
                [{"method": "session/new", "ms": 4000.0, "error": None},
                 {"method": "session/prompt", "ms": 4900.0, "first_chunk_ms": 700.0, "error": None}],
                # A chat whose agent never started: no answer, not in the distribution.
                [{"method": "session/new", "ms": 90000.0, "error": "agent_start did not finish within 90s"}],
                # acpmux restarted after session/new: the prompt is lost (review of bcbeee46824).
                [{"method": "session/new", "ms": 2000.0, "error": None},
                 {"method": "connection", "ms": None, "error": "OSError: closed"}],
                # A refused connect.
                [{"method": "connection", "ms": None, "error": "ConnectionRefusedError: [Errno 61]"}]]}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            m = summarize(os.path.join(tmp, "s.json"), [d])["runs"][0]["metrics"]
        self.assertEqual(m["acpmux_answered_chats"], 2)
        self.assertEqual(m["acpmux_first_answer_ms"]["p50"], 2300.0)
        self.assertEqual(m["acpmux_first_answer_ms"]["max"], 4700.0)
        # All chats: every unanswered chat ranks last at 150 s, however it failed.
        self.assertEqual(m["acpmux_first_answer_all_chats_ms"]["n"], 5)
        self.assertEqual(m["acpmux_first_answer_all_chats_ms"]["p50"], 150000.0)
        self.assertEqual(m["acpmux_first_answer_all_chats_ms"]["max"], 150000.0)

    def test_the_driver_times_the_first_answer_chunk(self):
        """The driver's own acpmux_call against a tiny ACP server that streams one chunk, then answers."""
        import socket as socket_module
        import threading as threading_module
        source = open(os.path.join(HERE, "driver.py")).read()
        start = source.index("def acpmux_call(")
        end = source.index("def one_chat(")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "a.sock")
            server = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def serve():
                conn, _ = server.accept()
                buf = b""
                while True:
                    data = conn.recv(65536)
                    if not data:
                        return
                    buf += data
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        req = json.loads(line)
                        if req["method"] == "session/prompt":
                            update = {"jsonrpc": "2.0", "method": "session/update",
                                      "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"text": "t"}}}}
                            conn.sendall((json.dumps(update) + "\n").encode())
                            time.sleep(0.2)
                        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {}}) + "\n").encode())
            thread = threading_module.Thread(target=serve, daemon=True)
            thread.start()
            namespace = {"socket": socket_module, "time": time, "json": json, "ACPMUX_HOME": tmp,
                         "acpmux_socket_of": lambda home: path}
            exec(compile(source[start:end], "driver.py", "exec"), namespace)
            answers = namespace["acpmux_call"]([("session/prompt", {"sessionId": "s"})], timeout=10)
            server.close()
        prompt = answers[-1]
        self.assertEqual(prompt["method"], "session/prompt")
        self.assertIsNotNone(prompt["first_chunk_ms"])
        self.assertLess(prompt["first_chunk_ms"], prompt["ms"])


class LockDetail(unittest.TestCase):
    def test_the_lock_detail_after_the_load_is_kept_by_lock_and_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            site = {"site": "crates/cmux-tui-core/src/mux/resource_api.rs:551", "acquisitions": 9, "hold_total_us": 25_700_000,
                    "hold_max_us": 900_000, "hold_p99_us": 524_288, "wait_total_us": 1, "wait_max_us": 1, "wait_p99_us": 1}
            run_["series"]["locks"] = [{"t": 400.0, "code": None, "locks": {"registry": {"by_hold_total": [site], "by_hold_p99": [site]},
                                                                             "state": {"by_hold_total": [], "by_hold_p99": []}}}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            summary = summarize(os.path.join(tmp, "s.json"), [d])
            top = summary["runs"][0]["metrics"]["lock_top_sites"]
            self.assertEqual(top["registry"]["by_hold_total"][0]["hold_total_us"], 25_700_000)
            self.assertEqual(top["state"]["by_hold_p99"], [])
            with open(os.path.join(tmp, "s.txt")) as f:
                self.assertIn("registry lock, top holders by total hold (since the daemon started; read after the load): "
                              "resource_api.rs:551 25.7 s p99 524.3 ms", f.read())
        # Runs before this harness have no lock detail.
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(synthetic_run(), f)
            self.assertIsNone(summarize(os.path.join(tmp, "s.json"), [d])["runs"][0]["metrics"]["lock_top_sites"])


class AgentFaults(unittest.TestCase):
    def test_missing_or_unhooked_agents_void_the_ab(self):
        head = run("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        with tempfile.TemporaryDirectory() as tmp:
            dirs = [write_run(tmp, "base-1", "base", head, 1), write_run(tmp, "head-1", "head", head, 1)]
            path = os.path.join(dirs[1], "run.json")
            with open(path) as f:
                run_ = json.load(f)
            # The head's hook injection broke: its agents start without hooks (less load, "better" numbers).
            run_["agent_records"] = [{"kind": "start", "hooked": False}] * 80
            with open(path, "w") as f:
                json.dump(run_, f)
            summary = summarize(os.path.join(tmp, "s.json"), dirs)
            self.assertEqual(summary["invalid"], "invalid: harness faults (head round 1: 0 of 80 started agents got hooks)")
            self.assertNotIn("comparison", summary)


class StallCause(unittest.TestCase):
    def test_only_code_stalls_are_reds(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_ = synthetic_run()
            # Every stall is a WAIT (run 1's shape: the hog held 13.5 GB with 9.2 GB of swap).
            run_["stalls"] = [{"duration_ms": 3365.8, "cpu_ms": 120.0, "cmux_frame": True, "symbol": "CmuxNextSidebar.Row.configure()"},
                              {"duration_ms": 150.0, "cpu_ms": 74.9, "cmux_frame": True, "symbol": "CmuxNextSidebar.Section.filter()"}]
            d = os.path.join(tmp, "run-1")
            os.makedirs(d)
            with open(os.path.join(d, "run.json"), "w") as f:
                json.dump(run_, f)
            m = summarize(os.path.join(tmp, "s.json"), [d])["runs"][0]["metrics"]
            self.assertEqual(m["stall_sites"], [])
            self.assertEqual(m["stalls_over_100ms_cmux"], 0)
            self.assertFalse(m["austin_failure"]["cmux_stalls"])
            self.assertEqual((m["stall_wait_count"], m["stall_wait_total_ms"]), (2, 3515.8))
            # 74.9 of 150 is under half: a WAIT; exactly half would be CODE.
            self.assertEqual(m["stall_code_count"], 0)


class Hog(unittest.TestCase):
    def test_hog_ends_at_its_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            start = time.monotonic()
            # swap target 0: it never grows past the first chunk check; it must still end on time.
            run(sys.executable, "-I", os.path.join(HERE, "hog.py"), "--swap-gb", "0", "--deadline", str(time.time() + 2),
                "--log", os.path.join(tmp, "hog.jsonl"), timeout=30)
            self.assertLess(time.monotonic() - start, 15)


if __name__ == "__main__":
    unittest.main()
