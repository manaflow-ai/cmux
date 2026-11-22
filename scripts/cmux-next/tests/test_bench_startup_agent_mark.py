#!/usr/bin/env python3
"""bench-startup.py --profile realistic waits for a mark the agent chat really sends.

The bench waited for `agent_pane.handshake_end`. Only AgentPaneBridge.reply marks it: the bridge of an agent page on
the pane's own WebKit host. Since 69a51bf63bed (2026-10-21) AgentPaneTunables.chromium is on by default, so
AgentTabs.makeView puts every new agent tab on the shared page host (`pageHost: pageHost || chromium`), whose
requests go through AgentPageProvider.call ("handshake" -> .ready -> AgentPaneModel.respond) and mark no handshake.
So the seeded chat "never loaded" on every build (/work/wt/perf-hot-tool-run/bench-1/, 10 of 10 runs "agent pane
missing"), the chat was not selected, and the realistic profile measured terminals only.
AgentPaneModel.respond marks `agent_pane.painted` for `pane.painted` (a chat's first frame after its handshake) on
both hosts. No app: the seeding launch is a pipe with the marks a page-host chat writes, the daemon and app sockets
are fakes. Run: python3 -I scripts/cmux-next/tests/test_bench_startup_agent_mark.py"""
import importlib.util, io, os, re, shutil, sys, tempfile, types, unittest
from contextlib import redirect_stderr
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)

AGENT_PANE = os.path.join(REPO, "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane")

# The marks of a seeding launch whose chat is on the page host (the default): the daemon tree, the chat's view, its
# page's first frame. No handshake mark: AgentPageProvider answers the handshake without one.
PAGE_HOST_SEED = ["daemon.first_tree_applied 900.0", "first_window_frame_committed 950.0",
                  "agent_pane.view_created 4000.0", "agent_pane.painted 4600.0"]


class PipeLaunch(bench_startup.Launch):
    """A launch whose marks are already written to its pipe; quitting it does nothing."""
    lines = []

    def __init__(self, *args, **kwargs):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, ("\n".join(self.lines) + "\n").encode())
        os.close(write_fd)
        self.read_fd, self.buffer, self.marks, self.arrived = read_fd, b"", {}, {}
        self.spawned_at = 0.0

    def quit(self):
        os.close(self.read_fd)


class FakeDaemon:
    def __init__(self, *args, **kwargs):
        self.spaces = {}

    def call(self, method, params=None, **kw):
        if method == "list-workspaces":
            return {"data": {"workspaces": list(self.spaces.values())}}
        if method == "new-workspace":
            wid = f"ws{len(self.spaces)}"
            self.spaces[wid] = {"id": wid, "screens": [{"panes": [{"id": f"p{wid}"}]}]}
        return {"ok": True}

    def close(self):
        pass


class AcceptingApp:
    calls = []

    def call(self, method, params=None, **kw):
        AcceptingApp.calls.append((method, params))
        return {"ok": True}

    def close(self):
        pass


class AgentMark(unittest.TestCase):
    def test_the_mark_is_sent_by_the_page_host_too(self):
        """The mark the bench waits for is made on the path both agent page hosts take, not only the old bridge's."""
        mark = bench_startup.AGENT_MARK
        quoted = re.compile(r'"' + re.escape(mark) + r'"')
        senders = []
        for name in sorted(os.listdir(AGENT_PANE)):
            if name.endswith(".swift"):
                with open(os.path.join(AGENT_PANE, name)) as handle:
                    if quoted.search(handle.read()):
                        senders.append(name)
        self.assertTrue(senders, f"no agent pane source marks {mark}")
        self.assertIn("AgentPaneModel.swift", senders,
                      f"{mark} is marked only in {senders}; the page host (AgentPageProvider) answers through "
                      "AgentPaneModel.respond")

    def seed(self, lines, session="sess-1"):
        """seed_realistic on a pipe launch with `lines` marks; (seeded_agent, stderr, action.run params)."""
        root = tempfile.mkdtemp(prefix="seed-agent-")
        AcceptingApp.calls = []
        try:
            tag = "seedagent"
            os.makedirs(os.path.join(root, "Library/Application Support/cmux-next/tags", tag, "tui"))
            PipeLaunch.lines = lines
            fake_storm = types.ModuleType("bench_cli_storm")
            fake_storm.Client = FakeDaemon
            env = {k: v for k, v in os.environ.items() if k != "BENCH_LAUNCH_STATE_BASE"}
            env["HOME"] = root
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.dict(sys.modules, {"bench_cli_storm": fake_storm}), \
                    mock.patch.object(bench_startup, "account_home", lambda: root, create=True), \
                    mock.patch.object(bench_startup, "Launch", PipeLaunch), \
                    mock.patch.object(bench_startup, "reset_state", lambda tag: None), \
                    mock.patch.object(bench_startup, "daemon_socket", lambda tag, timeout=20: "/nonexistent.sock"), \
                    mock.patch.object(bench_startup, "app_client", lambda *a, **k: AcceptingApp()), \
                    mock.patch.object(bench_startup, "app_tab_id", lambda *a, **k: "tab-1"), \
                    mock.patch.object(bench_startup, "seed_chat_session", lambda tag: session):
                with redirect_stderr(io.StringIO()) as err:
                    bench_startup.seed_realistic(tag, tempfile.mkdtemp(dir=root), 2)
                    marker = bench_startup.seeded_focus(tag)
                return bench_startup.seeded_agent(tag), err.getvalue(), [p for m, p in AcceptingApp.calls if m == "action.run"], marker
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_a_page_host_chat_seeds_the_agent_profile(self):
        agent, err, _, _ = self.seed(PAGE_HOST_SEED)
        self.assertNotIn("never loaded", err)
        self.assertTrue(agent, err)

    def test_the_seeded_chat_is_a_session_shown_in_the_focused_pane(self):
        """The chat is an acpmux session opened as a tab (agent.openSessionTab, shown), not New Agent Chat: a chat with
        no session restores as a New Tab page, which marks agent_pane.newtab_painted and never the bench's mark, so the
        launch-chat part had no agent_pane.painted in 10 of 10 relaunches on the measure Macs (2026-11-19)."""
        agent, err, runs, marker = self.seed(PAGE_HOST_SEED)
        self.assertTrue(agent, err)
        actions = [p["action"] for p in runs]
        self.assertNotIn("palette.newAgentChat", actions)
        opened = [p for p in runs if p["action"] == "agent.openSessionTab"]
        self.assertEqual(len(opened), 1, actions)
        self.assertEqual(opened[0]["args"], {"session": "sess-1"})
        self.assertTrue(opened[0]["focus"], "a script's open leaves the tab unshown, so its page never loads")
        self.assertLess(actions.index("splitRight"), actions.index("agent.openSessionTab"))
        self.assertEqual(marker, bench_startup.seed_layout())

    def test_a_new_tab_page_chat_is_not_an_agent_seed(self):
        """A seeding launch whose chat only drew a New Tab page (agent_pane.newtab_painted) seeds terminals, said."""
        lines = [line.replace("agent_pane.painted", "agent_pane.newtab_painted") for line in PAGE_HOST_SEED]
        agent, err, _, _ = self.seed(lines)
        self.assertFalse(agent)
        self.assertIn("never loaded", err)

    def test_no_session_seeds_terminals_and_says_why(self):
        agent, err, runs, _ = self.seed(PAGE_HOST_SEED, session=None)
        self.assertFalse(agent)
        self.assertIn("no session on the test agent", err)
        self.assertNotIn("agent.openSessionTab", [p["action"] for p in runs])

    def test_a_tag_seeded_with_the_old_chat_seeds_again(self):
        """A marker from before SEED_CHAT_KIND (the New Agent Chat seed, "terminals focus=agent") is not this layout."""
        self.assertNotEqual("agent", bench_startup.seed_layout())
        self.assertTrue(bench_startup.seed_layout().endswith("+" + bench_startup.SEED_CHAT_KIND))


if __name__ == "__main__":
    unittest.main()
