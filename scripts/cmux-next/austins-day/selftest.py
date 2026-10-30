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
                "Stop": [{"hooks": [{"type": "command", "command": "cat >/dev/null; sleep 30", "async": True}]}]}}
            path = os.path.join(tmp, "settings.json")
            json.dump(settings, open(path, "w"))
            cli = os.path.join(tmp, "cmux")
            with open(cli, "w") as f:
                f.write('#!/bin/sh\necho \'{"ok":false,"error":{"code":"server.busy"}}\'; exit 1\n')
            os.chmod(cli, 0o755)
            log = os.path.join(tmp, "log.jsonl")
            env = {**os.environ, "AD_AGENT_LOG": log, "AD_AGENT_DEADLINE": str(int(time.time()) + 3), "AD_TOOL_GAP": "0.1",
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
              "server_stats": [{"phase": "start", "stats": {"connections": {"accepted": 10, "refused": 0, "peak": 5, "limit": 64}}},
                               {"phase": "load", "code": "server.busy", "stats": None},
                               {"phase": "end", "stats": {"connections": {"accepted": 510, "refused": 70, "peak": 64, "limit": 64},
                                                          "registry_lock": {"wait_us": {"count": 9, "p50": 1, "p90": 5_000_000,
                                                                                         "p99": 17_000_000, "max": 20_000_000}}}}],
              "person_cli": [{"phase": "load", "ms": float(i), "code": "server.busy" if i == 99 else None} for i in range(100)],
              "app_control": [], "closes": [{"made": True, "app_gone_ms": 30.0, "daemon_gone_ms": None}],
              "waves": [{"answers": [{"method": "session/new", "ms": 40.0, "error": None}]}],
              "acpmux_pids": [{"pid": 1}, {"pid": 2}], "notes": []}
    return {"series": series, "agents": 80, "agent_records": [{"kind": "start", "hooked": True}, {"kind": "hook", "ms": 3, "rc": 0}],
            "app_probe": {"start": {"bounds_us": [1000, 10000, 100000], "counts": [5, 0, 0], "timeouts": 0, "max_us": 900},
                          "end": {"bounds_us": [1000, 10000, 100000], "counts": [95, 4, 1], "timeouts": 2, "max_us": 80000}},
            "app_log": {"ok": True, "no_reply_within": 3, "no_reply_by_cmd": {"put-frontend-projection": 3}},
            "stalls": [{"duration_ms": 300.0, "cmux_frame": True, "symbol": "CmuxNextSidebar.Foo.bar()"},
                       {"duration_ms": 200.0, "cmux_frame": False, "symbol": None}], "host": "h"}


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
            self.assertEqual(m["daemon_connections"]["accepted"], 500)
            # The probe over the run: end minus start (90, 4, 1); rank 91 of 95 is in the second bucket, 95 in the third.
            self.assertEqual(m["app_requests"]["n"], 95)
            self.assertEqual(m["app_requests"]["p50"], 1.0)
            self.assertEqual(m["app_requests"]["p95"], 10.0)
            self.assertEqual(m["app_requests"]["p99"], 100.0)
            self.assertEqual(m["app_requests"]["timeouts"], 2)
            self.assertEqual(m["workspace_close_not_done"], 1)
            self.assertEqual(m["acpmux_restarts"], 1)
            self.assertEqual(m["stalls_over_100ms_cmux"], 1)
            self.assertEqual(m["stall_sites"][0]["owner"], "a590 (sidebar-owner agent)")
            self.assertTrue(all(m["austin_failure"].values()), m["austin_failure"])


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
