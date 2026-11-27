#!/usr/bin/env python3
"""scripts/cmux-next/owner_live.py and guardrails.owner_route: an OWNERS.md owner resolves to a live session.

The regression: cmux#50549's push into cmux-tui/crates/acpmux/ printed "owner PL-acpmux (session cmux-4f; lead
decision 2026-10-23)" on 2026-11-22, a month after cmux-4f had ended; the warning reached no one. Now the owner cell
resolves at push time (an `owns=` holder, the named session, its successor, the Performance Lead, the coordinator)
and that live session is sent one notice per area and pushed head.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


live = _load("cmux_next_owner_live", "scripts/cmux-next/owner_live.py")
CELL = "PL-acpmux (session cmux-4f; lead decision 2026-10-23)"


def row(name, status="idle", sid=None, updated=1, **tags):
    return {"name": name, "status": status, "sessionId": sid or f"id-{name}", "updatedAt": updated, "tags": tags or None}


class Holder(unittest.TestCase):
    def test_the_cell_of_2026_11_22_names_a_workstream_and_a_session(self):
        self.assertEqual(live.cell_names(CELL), (["PL-acpmux"], ["cmux-4f"]))
        self.assertEqual(live.cell_names("a590 (sidebar-owner agent)"), ([], []))

    def test_an_owns_tag_wins_over_the_named_session(self):
        rows = [row("host-a/cmux-4f"), row("host-b/acpmux-keeper", owns="PL-daemon,PL-acpmux")]
        self.assertEqual(live.holder(CELL, rows, ""), ("host-b/acpmux-keeper", "holds owns=PL-acpmux"))

    def test_a_role_cell_names_lanes_by_glob_and_the_newest_live_one_holds_it(self):
        cell = "PL-instant (lanes tabs-refine,tab-strip-*; coordinator rule 2026-11-23)"
        self.assertEqual(live.cell_lanes(cell), ["tabs-refine", "tab-strip-*"])
        rows = [row("h1/tab-strip-old", "closed", updated=9), row("h2/tab-strip-pins", updated=3),
                row("h3/tabs-refine", "ready", updated=5), row("h4/sidebar-x", updated=99)]
        self.assertEqual(live.holder(cell, rows, ""), ("h3/tabs-refine", "a lane of tabs-refine,tab-strip-*"))

    def test_a_pr_finisher_named_for_the_area_never_holds_the_role(self):
        # 2026-11-23: `lanes *sidebar*` sent every sidebar push to finish-cmux-52161-sidebar, a one-PR finisher.
        cell = "sidebar lanes: lanes *sidebar* (coordinator rule 2026-11-23)"
        rows = [row("g9/finish-cmux-52161-sidebar", "running", updated=99), row("g12/sidebar-running-tree", updated=3)]
        self.assertEqual(live.holder(cell, rows, ""), ("g12/sidebar-running-tree", "a lane of *sidebar*"))
        only = [row("g9/finish-cmux-52161-sidebar", "running"), row("c/coord", owns="coordinator")]
        self.assertEqual(live.holder(cell, only, "")[0], "c/coord")
        self.assertFalse(live.FINISHER.match("sidebar-finish-pass"))
        self.assertTrue(live.FINISHER.match("finish-cmux-52161"))

    def test_a_lane_that_only_mentions_the_area_never_holds_the_role(self):
        # 2026-11-25: `lanes *sidebar*` sent ~12 "you hold it now" notices in two days to rex-sidebar-look, a lane on
        # one sidebar PR (cmux#54990). A glob is anchored at the name's start; with no lane of the area, the push
        # goes the unheld way.
        cell = "sidebar lanes: lanes *sidebar* (coordinator rule 2026-11-23)"
        rows = [row("g7/rex-sidebar-look", "running", updated=99), row("g9/finish-cmux-52161-sidebar", updated=98),
                row("g3/sidebar-owner", updated=2)]
        self.assertEqual(live.holder(cell, rows, ""), ("g3/sidebar-owner", "a lane of *sidebar*"))
        rows = rows[:2] + [row("c/coord", owns="coordinator")]
        who, how = live.holder(cell, rows, "")
        self.assertEqual((who, how), ("c/coord", "no live lane of *sidebar*; the coordinator"))
        self.assertTrue(live.is_fallback(how))
        tagged = rows + [row("g7/rex-sidebar-look-2", owns="PL-sidebar")]
        self.assertEqual(live.holder("PL-sidebar, else lanes *sidebar*", tagged, "")[0], "g7/rex-sidebar-look-2")
        for name, globs in [("ghostty-scroll", ["*-ghostty*"]), ("tdaemon-journal", ["*tdaemon*"]),
                            ("tab-strip-pins", ["tab-strip*"]), ("tabs-refine", ["tabs-refine"])]:
            self.assertTrue(live.fills_role(name, globs), name)
        for name, globs in [("rex-sidebar-look", ["*sidebar*"]), ("finish-cmux-52161-sidebar", ["*sidebar*"]),
                            ("chat-hover-card-pin", ["*hover-card*"]), ("cmux-tdaemon", ["*tdaemon*"]),
                            ("sidebar-owner", ["tabs-*"])]:
            self.assertFalse(live.fills_role(name, globs), name)

    def test_a_tag_the_full_listing_dropped_is_read_from_the_filtered_one(self):
        rows = [{"name": "h2/acpmux-owner", "sessionId": "s1", "status": "ready", "tags": None, "updatedAt": 1}]
        merged = live.merge_tagged(rows, [{"name": "h2/acpmux-owner", "sessionId": "s1", "tags": {"owns": "PL-acpmux"}}])
        self.assertEqual(live.holder("PL-acpmux (session cmux-4f)", merged, ""), ("h2/acpmux-owner", "holds owns=PL-acpmux"))
        self.assertIs(live.merge_tagged(rows, []), rows)

    def test_an_owns_tag_still_wins_over_a_role(self):
        cell = "PL-instant (lanes tabs-refine)"
        rows = [row("h3/tabs-refine"), row("h5/keeper", owns="PL-instant")]
        self.assertEqual(live.holder(cell, rows, "")[0], "h5/keeper")

    def test_an_owns_tag_naming_the_area_holds_it(self):
        # 2026-11-27 01:20Z: gcp-agent-lane-13/goal-next-code-shrinks-a-2-2 was live and tagged owns=package-layering,
        # yet a push into the area still told the coordinator it "has no live holder (PL-arch, else lanes ...)": only
        # the PL- token was read. Chromium hosting and Guardrails were tagged by name the same night.
        area = "Package layering, signpost catalog (CmuxNextSignposts names; app moves out of CmuxNextApp)"
        cell = ("PL-arch, else lanes arch-*,*layering*,*signpost* (coordinator rule 2026-11-23: the live lane working "
                "in it; Performance Lead, 2026-10-23); new signpost names: PL-arch + PL-telemetry")
        coord = row("cosmic-gray/claude-sr2-coord", "running", owns="coordinator")
        holder_row = row("gcp-agent-lane-13/goal-next-code-shrinks-a-2-2", "ready", owns="package-layering")
        self.assertEqual(live.holder(cell, [coord, holder_row], "", area),
                         ("gcp-agent-lane-13/goal-next-code-shrinks-a-2-2", "holds owns=package-layering"))
        # the area's own words, any case, a comma list, or the whole name
        for tag in ("Package layering", "PACKAGE-LAYERING, other", area, "package layering, signpost catalog"):
            rows = [coord, row("h/keeper", owns=tag)]
            self.assertEqual(live.holder(cell, rows, "", area)[0], "h/keeper", tag)
        chromium = "Chromium hosting (page layer, host view, clip, shim)"
        rows = [coord, row("g17/feed-fix-chromium-pane", "running", owns="Chromium hosting")]
        self.assertEqual(live.holder("PL-cef-layer (clip memo: Leo, c22a10712b6)", rows, "", chromium)[0],
                         "g17/feed-fix-chromium-pane")
        guard = "Guardrails, pre-push gate, codebase health"
        rows = [coord, row("g11/lint-never-blocks-autofix", "running", owns="Guardrails, pre-push gate, codebase health")]
        self.assertEqual(live.holder("Performance Lead (PL-guardrails)", rows, "", guard)[0],
                         "g11/lint-never-blocks-autofix")
        # a word's start, another area, or a closed session holds nothing
        for tag in ("pack", "layering", "Chromium side of motion", "package-layeringx"):
            rows = [coord, row("h/other", owns=tag)]
            self.assertEqual(live.holder(cell, rows, "", area)[0], "cosmic-gray/claude-sr2-coord", tag)
        closed = [coord, row("h/gone", "closed", owns="package-layering")]
        self.assertEqual(live.holder(cell, closed, "", area)[0], "cosmic-gray/claude-sr2-coord")
        # the notices print a tag that works
        self.assertIn("owns=PL-arch", live.unheld_notice(area, cell, ["a"], "0" * 12, "b", "d"))
        self.assertIn("owns=motion-gate-and-animation-switches",
                      live.unheld_notice("Motion gate and animation switches", "Performance Lead", ["a"], "0" * 12,
                                         "b", "d"))
        self.assertEqual(live.tag_hint(area, "lead: cmux-ad"), "package-layering")

    def test_a_role_with_no_live_lane_falls_to_the_coordinator(self):
        rows = [row("h1/tabs-refine", "closed"), row("c/coord", owns="coordinator")]
        found = live.holder("Aziz (human); lanes ios-*", rows, "")
        self.assertEqual(found, ("c/coord", "no live lane of ios-*; the coordinator"))
        self.assertTrue(live.is_fallback(found[1]))

    def test_the_named_session_while_it_is_live(self):
        self.assertEqual(live.holder(CELL, [row("host-a/cmux-4f", "running")], ""), ("host-a/cmux-4f", "named"))

    def test_a_gone_session_falls_to_its_successor_chain(self):
        rows = [row("host-a/cmux-4f", "closed", sid="A"),
                row("host-c/cmux-4f-2", "closed", sid="B", succeeds="A"),
                row("host-c/cmux-4f-3", "ready", sid="C", succeeds="B")]
        self.assertEqual(live.holder(CELL, rows, ""), ("host-c/cmux-4f-3", "successor of cmux-4f"))
        failover = [row("host-a/cmux-4f", "closed", failover="host-d/acpmux-next"), row("host-d/acpmux-next")]
        self.assertEqual(live.holder(CELL, failover, "")[0], "host-d/acpmux-next")

    def test_a_successor_loop_ends(self):
        rows = [row("x/cmux-4f", "closed", sid="A", failover="x/b"), row("x/b", "closed", sid="B", failover="x/cmux-4f")]
        self.assertEqual(live.successor(rows, "cmux-4f"), None)

    def test_no_successor_goes_to_the_performance_lead_then_the_coordinator(self):
        gone = [row("host-a/cmux-4f", "closed")]
        self.assertEqual(live.holder(CELL, gone + [row("h/perf", owns="PL-lead")], "")[0], "h/perf")
        who, how = live.holder(CELL, gone + [row("host-a/coordinator", "running")], "host-a/coordinator")
        self.assertEqual(who, "host-a/coordinator")
        self.assertIn("cmux-4f gone; the coordinator", how)
        self.assertEqual(live.holder(CELL, gone, "host-a/coordinator"),
                         (None, "cmux-4f gone; no live lead or coordinator"))

    def test_a_stale_row_is_not_live(self):
        self.assertFalse(live.is_live({"name": "a/b", "status": "idle", "stale": True}))
        self.assertTrue(live.is_live({"name": "a/b", "status": "idle", "stale": None}))

    def test_the_registry_coordinator_follows_retired_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.json"
            path.write_text(json.dumps({"coordinators": {"current": "c/old", "retired": {"c/old": "c/new"}}}))
            self.assertEqual(live.registry_coordinator(path), "c/new")
            path.write_text("{")
            self.assertIsNone(live.registry_coordinator(path))


class Notify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"CMUX_OWNER_NOTICES": str(Path(self.tmp.name) / "n.json"),
                                                "ACPMUX_SESSION_ID": "id-pusher"})
        self.env.start()
        self.me = mock.patch.object(live, "sender_name", return_value="host-p/pusher")
        self.me.start()

    def tearDown(self):
        self.me.stop()
        self.env.stop()
        self.tmp.cleanup()

    def test_one_notice_per_holder_area_and_head(self):
        ok = types.SimpleNamespace(returncode=0, stdout="id", stderr="")
        with mock.patch.object(live.subprocess, "run", return_value=ok) as run:
            self.assertIsNone(live.notify("h/s", "acpmux", "a" * 40, "text"))
            self.assertIsNone(live.notify("h/s", "acpmux", "a" * 40, "text"))
            self.assertIsNone(live.notify("h/s", "acpmux", "b" * 40, "text"))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0], ["acpmux", "send", "--no-wait", "--class", "action", "h/s", "-"])

    def test_a_refused_send_is_named_and_retried_next_push(self):
        bad = types.SimpleNamespace(returncode=1, stdout="", stderr="no session h/s")
        with mock.patch.object(live.subprocess, "run", return_value=bad) as run:
            self.assertIn("no session h/s", live.notify("h/s", "acpmux", "a" * 40, "t"))
            live.notify("h/s", "acpmux", "a" * 40, "t")
        self.assertEqual(run.call_count, 2)

    def test_opt_out_sends_nothing(self):
        with mock.patch.dict(os.environ, {"CMUX_OWNER_NOTIFY": "0"}), mock.patch.object(live.subprocess, "run") as run:
            self.assertEqual(live.notify("h/s", "a", "h", "t"), "CMUX_OWNER_NOTIFY=0")
        run.assert_not_called()

    def test_no_sender_session_sends_nothing(self):
        # 2026-11-25: a push outside any acpmux session sent "you hold it now" from the bare host, with no Sent-by.
        env = {k: v for k, v in os.environ.items() if k not in live.SENDER_ENV}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(live.subprocess, "run") as run:
            self.assertEqual(live.notify("h/s", "a", "h", "t"), live.NO_SENDER)
        run.assert_not_called()

    def test_the_notice_names_the_pusher_as_host_slash_name(self):
        # 2026-11-26: notices arrived labelled "gcp-agent-lane-5" (a bare host) and inbox_reply could not answer them.
        ok = types.SimpleNamespace(returncode=0, stdout="id", stderr="")
        with mock.patch.object(live.subprocess, "run", return_value=ok) as run:
            self.assertIsNone(live.notify("h/s", "acpmux", "a" * 40, "you hold it now."))
        self.assertIn("From host-p/pusher; answer with `lane-gh send host-p/pusher -`", run.call_args.kwargs["input"])

    def test_a_session_acpmux_cannot_name_sends_nothing(self):
        with mock.patch.object(live, "sender_name", return_value=None), mock.patch.object(live.subprocess, "run") as run:
            self.assertEqual(live.notify("h/s", "a", "h", "t"), live.NO_SENDER_NAME)
        run.assert_not_called()

    def test_sender_name_is_host_slash_name_never_a_bare_host(self):
        self.me.stop()
        try:
            info = types.SimpleNamespace(returncode=0, stdout="machine\tgcp-agent-lane-5\nname\tfix-sidebar\n", stderr="")
            with mock.patch.object(live.subprocess, "run", return_value=info) as run:
                self.assertEqual(live.sender_name(), "gcp-agent-lane-5/fix-sidebar")
            self.assertEqual(run.call_args.args[0][:4], ["acpmux", "session", "info", "id-pusher"])
            host_only = types.SimpleNamespace(returncode=0, stdout="machine\tgcp-agent-lane-5\nname\t\n", stderr="")
            gone = types.SimpleNamespace(returncode=4, stdout="", stderr="no_session")
            for out in (host_only, gone):
                with mock.patch.object(live.subprocess, "run", return_value=out):
                    self.assertIsNone(live.sender_name())
            env = {k: v for k, v in os.environ.items() if k not in ("ACPMUX_SESSION_ID", "ACPMUX_SESSION_NAME")}
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(live.subprocess, "run") as run:
                self.assertIsNone(live.sender_name())
            run.assert_not_called()
        finally:
            self.me.start()

    def test_ci_lists_nothing(self):
        with mock.patch.dict(os.environ, {"CI": "true"}):
            self.assertEqual(live.list_sessions(), (None, None))


class Route(unittest.TestCase):
    """guardrails.owner_route over a real commit: the push into the acpmux crate reaches the live holder."""

    def test_a_push_into_pl_acpmux_reaches_a_live_session(self):
        guardrails = _load("cmux_next_guardrails_owner_live_test", "scripts/cmux-next/guardrails.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args):
            return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True,
                                  text=True).stdout.strip()

        git("init", "-q", "-b", "main")
        owners = repo / "plans/cmux-next/OWNERS.md"
        owners.parent.mkdir(parents=True)
        owners.write_text("| Area | Paths | Owner | Read first |\n|---|---|---|---|\n"
                          f"| acpmux daemon | `cmux-tui/crates/acpmux/` | {CELL} | [acpmux-audit.md](acpmux-audit.md) |\n")
        git("add", "-A")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        crate = repo / "cmux-tui/crates/acpmux/src/lib.rs"
        crate.parent.mkdir(parents=True)
        crate.write_text("// change\n")
        git("add", "-A")
        git("commit", "-qm", "change")
        head = git("rev-parse", "HEAD")
        own = types.SimpleNamespace(base=base, head=head)
        rows = [row("host-a/cmux-4f", "closed"), row("host-a/coordinator", "running")]
        sent = []
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual(len(lines), 1, lines)
        self.assertIn("acpmux daemon is held by host-a/coordinator (cmux-4f gone; the coordinator)", lines[0])
        # The coordinator stands in: one notice an area a UTC day, asking for a holder, not one per push.
        (to, area, key, text), = sent
        self.assertEqual((to, area), ("host-a/coordinator", "acpmux daemon"))
        self.assertRegex(key, r"^day \d{4}-\d\d-\d\d$")
        self.assertIn("has no live holder", text)
        self.assertIn("cmux-tui/crates/acpmux/src/lib.rs", text)
        # A session tagged with the area's name holds it too (guardrails passes the area to holder()).
        sent.clear()
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows + [row("host-c/area-keeper", owns="acpmux-daemon")], None),
                                           "host-a/coordinator")
        self.assertIn("held by host-c/area-keeper (holds owns=acpmux-daemon)", lines[0])
        self.assertEqual(sent[0][0], "host-c/area-keeper")
        self.assertNotIn("has no live holder", sent[0][3])
        # A holder that took the workstream hears of each branch once a UTC day, not each pushed head.
        rows.append(row("host-b/acpmux-keeper", owns="PL-acpmux"))
        sent.clear()
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertIn("held by host-b/acpmux-keeper (holds owns=PL-acpmux); told of this push", lines[0])
        branch = git("rev-parse", "--abbrev-ref", "HEAD")
        self.assertEqual(sent[0][:2], ("host-b/acpmux-keeper", "acpmux daemon"))
        self.assertRegex(sent[0][2], rf"^{re.escape(branch)} day \d{{4}}-\d\d-\d\d$")
        # A second head on the same branch the same day keys the same, so notify() sends it once.
        crate.write_text("// change again\n")
        git("commit", "-qam", "again")
        own2 = types.SimpleNamespace(base=base, head=git("rev-parse", "HEAD"))
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            guardrails.owner_route(repo, [own2], (rows, None), "host-a/coordinator")
        self.assertEqual(sent[1][2], sent[0][2])

    def test_a_base_merge_carries_no_owned_files(self):
        """2026-11-25: lane/port-46285 (webviews only) merged feat-cmux-next, whose new commit touched
        Packages/iOS/CmuxTabsKit; the push's base was the old remote head, so the two-tree diff counted CmuxTabsKit
        and the live iOS lane was told it held it. Only the push's own commits count."""
        guardrails = _load("cmux_next_guardrails_owner_merge_test", "scripts/cmux-next/guardrails.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args, committer="t@t"):
            return subprocess.run(["git", *args], cwd=repo, env={**env, "GIT_COMMITTER_EMAIL": committer},
                                  check=True, capture_output=True, text=True).stdout.strip()

        def commit(path, text, message, committer="t@t"):
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
            git("add", "-A")
            git("commit", "-qm", message, committer=committer)

        git("init", "-q", "-b", "main")
        commit("plans/cmux-next/OWNERS.md", "| Area | Paths | Owner | Read first |\n|---|---|---|---|\n"
               "| iOS tabs | `Packages/iOS/` | lanes ios-* | [AGENTS.md](AGENTS.md) |\n", "base")
        git("checkout", "-qb", "lane/port")
        commit("webviews/src/a.tsx", "a\n", "own change")
        old_remote = git("rev-parse", "HEAD")
        git("checkout", "-q", "main")
        # Upstream's squash merge: GitHub is its committer.
        commit("Packages/iOS/CmuxTabsKit/Tab.swift", "tab\n", "tabs (#1)", committer=guardrails.GITHUB_COMMITTER)
        git("checkout", "-q", "lane/port")
        git("merge", "-q", "--no-edit", "main")
        head = git("rev-parse", "HEAD")
        own = types.SimpleNamespace(base=old_remote, head=head, before=())
        rows = [row("host-a/ios-terminal-first-composer", "running")]
        sent = []
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual((lines, sent), ([], []))
        # The lane's own edit to the area after the merge still reaches the holder.
        commit("Packages/iOS/CmuxTabsKit/Tab.swift", "tab 2\n", "own tabs edit")
        own = types.SimpleNamespace(base=old_remote, head=git("rev-parse", "HEAD"), before=())
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual([(to, area) for to, area, *_ in sent], [("host-a/ios-terminal-first-composer", "iOS tabs")])


    def test_a_branch_cut_before_an_owners_change_routes_by_the_merged_row(self):
        """2026-11-27: cmux#60006 dropped `design-*motion*` from Layout motion upstream, yet lane/mobile-bandwidth-steps
        (cut before it) still sent its push to the transcript-motion lane: the hook read the row from the lane's own
        copy. The merged table answers who holds an area now."""
        guardrails = _load("cmux_next_guardrails_owner_upstream_test", "scripts/cmux-next/guardrails.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args):
            return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True,
                                  text=True).stdout.strip()

        def commit(path, text, message):
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
            git("add", "-A")
            git("commit", "-qm", message)

        table = "| Area | Paths | Owner | Read first |\n|---|---|---|---|\n| Layout motion | `Layout/` | lanes {} | x |\n"
        git("init", "-q", "-b", "main")
        commit("plans/cmux-next/OWNERS.md", table.format("motion-*,design-*motion*"), "base")
        base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "lane/mobile")
        commit("Layout/Pane.swift", "pane\n", "own change")
        head = git("rev-parse", "HEAD")
        git("checkout", "-q", "main")
        commit("plans/cmux-next/OWNERS.md", table.format("motion-*"), "owners fix (#60006)")
        git("update-ref", guardrails.UPSTREAM, "HEAD")
        git("checkout", "-q", "lane/mobile")
        own = types.SimpleNamespace(base=base, head=head, before=())
        rows = [row("host-a/design-transcript-motion", "running"), row("host-b/motion-springs", "running")]
        sent = []
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual([(to, area) for to, area, *_ in sent], [("host-b/motion-springs", "Layout motion")])
        # A push that itself rewrites the row means its own table.
        prev = git("rev-parse", "HEAD")
        commit("plans/cmux-next/OWNERS.md", table.format("mobile-*"), "claim the row")
        commit("Layout/Pane.swift", "pane 2\n", "own change 2")
        own = types.SimpleNamespace(base=prev, head=git("rev-parse", "HEAD"), before=())
        rows.append(row("host-c/mobile-bandwidth-steps", "running"))
        sent.clear()
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual([to for to, *_ in sent], ["host-c/mobile-bandwidth-steps"])

    def test_a_github_update_branch_merge_carries_no_owned_files(self):
        """2026-11-26: lane/updater-restore-adopt at a2b890f491d4 told the sidebar lane it changed
        CmuxNextSidebar/Views/WorkspaceRowView+TrailingCloud.swift. Its head's parent c60664bd4f1f was GitHub's
        "Merge branch 'feat-cmux-next' into ..." (update branch, committer GitHub), and the file came from that
        merge: `git diff $(git merge-base HEAD origin/feat-cmux-next) HEAD` of it was empty (lane/link-race-warm,
        cmux#53632, the same through base merge 0accd367). Neither the merge nor what it brought in is the push's,
        whether upstream's commit was GitHub's squash or a person's push this clone has under refs/remotes."""
        guardrails = _load("cmux_next_guardrails_owner_update_branch_test", "scripts/cmux-next/guardrails.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args, committer="t@t"):
            return subprocess.run(["git", *args], cwd=repo, env={**env, "GIT_COMMITTER_EMAIL": committer},
                                  check=True, capture_output=True, text=True).stdout.strip()

        def commit(path, text, message, committer="t@t"):
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
            git("add", "-A")
            git("commit", "-qm", message, committer=committer)

        sidebar = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/WorkspaceRowView+TrailingCloud.swift"
        git("init", "-q", "-b", "feat-cmux-next")
        commit("plans/cmux-next/OWNERS.md", "| Area | Paths | Owner | Read first |\n|---|---|---|---|\n"
               "| Sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/` | lanes *sidebar* | "
               "[AGENTS.md](AGENTS.md) |\n", "base")
        git("checkout", "-qb", "lane/updater-restore-adopt")
        commit("Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Restore.swift", "a\n", "own change")
        old_remote = git("rev-parse", "HEAD")
        git("checkout", "-q", "feat-cmux-next")
        commit(sidebar, "cloud\n", "sidebar trailing cloud (#2)", committer=guardrails.GITHUB_COMMITTER)
        # A person's direct push upstream: not GitHub's, but on a remote-tracking ref this clone fetched.
        commit(sidebar.replace("TrailingCloud", "Leading"), "lead\n", "sidebar leading", committer="p@p")
        git("update-ref", "refs/remotes/origin/feat-cmux-next", "HEAD")
        git("checkout", "-q", "lane/updater-restore-adopt")
        # GitHub's update-branch merge, then the lane's next commit on top of it.
        git("merge", "-q", "--no-ff", "--no-edit", "-m", "Merge branch 'feat-cmux-next' into "
            "lane/updater-restore-adopt", "feat-cmux-next", committer=guardrails.GITHUB_COMMITTER)
        commit("Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Restore.swift", "b\n", "own change 2")
        head = git("rev-parse", "HEAD")
        rows = [row("host-a/sidebar-owner", "running")]
        for base, before in ((old_remote, ()), (git("merge-base", "HEAD", "feat-cmux-next"), ())):
            own = types.SimpleNamespace(base=base, head=head, before=before)
            self.assertEqual(guardrails.owner_route_files(repo, own),
                             ["Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Restore.swift"])
            sent = []
            with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
                lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
            self.assertEqual((lines, sent), ([], []))


if __name__ == "__main__":
    unittest.main()
