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
