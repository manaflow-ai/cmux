#!/usr/bin/env python3
"""Tagged-build check of the default hidden local WebKit chat release and wake.

Run on a fleet Mac: hidden-chat-wake.py --app BUNDLE --out DIR. Uses the same
isolated launch and persisted fake-agent chat as bench_memory.py; no page-local
seed rows, shortened timeout or forced release. A missing release, draft,
transcript or scroll anchor fails. Before/after page PNGs and the composited
wake frame strip are saved with report.json. --socket/--app-pid attach to an
already isolated tagged WebKit build instead. No shared config is changed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time


def matching_restore(before: dict, after: dict, tolerance: float = 2) -> bool:
    """The visible result matters: a session/row count alone cannot pass."""
    old_anchor = before.get("scroll", {}).get("anchor") or {}
    new_anchor = after.get("scroll", {}).get("anchor") or {}
    return bool(
        before.get("draft", {}).get("text")
        and before["draft"]["text"] == before["draft"].get("durableText")
        and after.get("draft", {}).get("text") == before["draft"]["text"]
        and after["draft"].get("durableText") == before["draft"]["text"]
        and before.get("chat", {}).get("transcript")
        and after.get("chat", {}).get("transcript") == before["chat"]["transcript"]
        and old_anchor.get("rowId")
        and old_anchor.get("rowId") == new_anchor.get("rowId")
        and abs(old_anchor.get("offset", 0) - new_anchor.get("offset", 0)) <= tolerance
        and abs(before["scroll"]["top"] - after.get("scroll", {}).get("top", -1000)) <= tolerance
        and after.get("scroll", {}).get("visible")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--socket")
    parser.add_argument("--app-pid", type=int)
    parser.add_argument("--fake-agent", default=str(Path(__file__).resolve().parents[2] /
                                                   "cmux-tui/crates/acpmux/tests/fake_agent.py"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-seconds", type=float, default=540)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("run this check on a fleet Mac through cmux-ci")
    if bool(args.socket) != bool(args.app_pid):
        parser.error("--socket and --app-pid must be supplied together")

    import bench_memory as bm

    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    report: dict = {"passed": False, "app": str(Path(args.app).resolve()), "phases": {}}
    scratch = None
    workspace = None
    app = None
    end = time.monotonic() + args.max_seconds

    def remaining() -> float:
        left = end - time.monotonic()
        if left <= 0:
            raise RuntimeError("hidden-chat-wake exceeded its bounded run time")
        return left

    def checked(answer: dict) -> dict:
        if not isinstance(answer, dict) or answer.get("error") or answer.get("code"):
            raise RuntimeError(str(answer))
        return answer

    def pane(action: str, **params) -> dict:
        remaining()
        return checked(app.rpc("debug.agent_pane", {"action": action, "pane": pane_id, **params}))

    def wait_for(read, accept, seconds=30):
        # Test-only condition wait; it reads this exact tab and never drives a hidden page.
        deadline = min(end, time.monotonic() + seconds)
        last = None
        while time.monotonic() < deadline:
            last = read()
            if accept(last):
                return last
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        raise RuntimeError(f"condition did not hold: {last}")

    try:
        with tempfile.TemporaryDirectory(prefix="hidden-chat-wake-") as launch_files:
            if args.socket:
                pid, sock = args.app_pid, args.socket
            else:
                # Exercise local WebKit's production path; residency settings remain entirely unset.
                tunables = Path(launch_files) / "tunables.json"
                tunables.write_text(json.dumps({"version": 1, "values": {"agent.chromium": False}}))
                pid, sock, scratch = bm.launch(args.app, {"browser": {"defaultEngine": "webkit"}},
                                              {"CMUX_NEXT_DEBUG_TUNABLES_FILE": str(tunables)}, direct=True)
            report.update({"pid": pid, "socket": sock})
            app = bm.App(args.app, sock)
            chats = bm.FakeChats(app, args.app, args.fake_agent, pid)
            workspace = chats.open(0)
            if not workspace:
                raise RuntimeError("the persisted fake-agent chat did not open")
            selected = app.action("goToWorkspace", workspace=workspace)
            if selected.get("error") or selected.get("code"):
                raise RuntimeError(f"cannot show chat workspace {workspace}: {selected}")
            chats.observe(workspace)
            observed = chats.pages[workspace]
            pane_id = observed["pane"]
            session = observed["session"]
            if not observed["engine"].startswith("webkit:"):
                raise RuntimeError(f"expected local WebKit, got {observed['engine']}")
            topology = checked(app.rpc("snapshot.get", {}))
            topology = topology.get("topology", topology)
            tab = (topology.get("focus") or {}).get("tab")
            if not tab:
                raise RuntimeError(f"no exact focused chat tab in {topology.get('focus')}")
            report.update({"workspace": workspace, "pane": pane_id, "tab": tab, "session": session})
            # The real agent echoes a tall persisted turn, long enough to require scrolling.
            marker = "HIDDEN_CHAT_WAKE_TRANSCRIPT"
            prompt = marker + "\n\n" + "\n\n".join(
                f"Paragraph {index}: " + "This persisted message must survive page release. " * 4
                for index in range(32)
            )
            pane("send_prompt", text=prompt)
            wait_for(lambda: pane("chat_state"),
                     lambda state: marker in (state.get("lastAssistant") or {}).get("text", "")
                     and not state.get("isWorking"))
            expected_draft = "Keep this unsent draft after the hidden page is released."
            wait_for(lambda: pane("compose_draft", text=expected_draft),
                     lambda state: state.get("text") == state.get("durableText") == expected_draft)
            scroll = pane("scroll_state", fraction=0.35)
            if scroll.get("scrollHeight", 0) - scroll.get("height", 0) < 200:
                raise RuntimeError(f"the persisted transcript is not scrollable: {scroll}")
            # Settle the ordinary anchor report before preserving the observed state.
            time.sleep(1)
            before = {"draft": pane("compose_draft"), "scroll": pane("scroll_state"), "chat": pane("chat_state")}
            report["phases"]["before"] = before
            surface_before = checked(app.rpc("debug.surfaces", {}))
            chat_pages_before = (surface_before.get("hibernation") or {}).get("chat_pages") or []
            if tab not in chat_pages_before:
                raise RuntimeError(f"chat tab was not live before hiding: {tab} not in {chat_pages_before}")
            if not (before["scroll"].get("anchor") or {}).get("rowId"):
                raise RuntimeError(f"no real non-latest scroll anchor was observed: {before['scroll']}")
            pane("snapshot", path=str(out / "before.png"))
            checked(app.rpc("action.run", {"action": "newSurface", "target": f"pane:{pane_id}",
                                           "focus": True, "wait": True, "origin": "script"}))
            # Explicit focus selects the terminal in this same pane; no workspace hibernation shortcut.
            terminals = checked(app.rpc("snapshot.get", {}))
            terminals = terminals.get("topology", terminals)
            terminal = (terminals.get("focus") or {}).get("tab")
            if not terminal or terminal == tab:
                raise RuntimeError("the chat never hid behind its own pane's terminal")
            checked(app.run("tab.focus", target=terminal))
            seconds = 300
            if remaining() < seconds + 30:
                raise RuntimeError(f"not enough time to wait for the full default ({seconds}s)")
            print(f"HIDDEN-CHAT-WAKE hiding tab={tab} session={session} default_seconds={seconds}", flush=True)
            hidden_at = time.monotonic()
            # One idle window, then a bounded native-state condition wait. No hidden page script runs.
            time.sleep(seconds + 5)
            def release_state():
                value = checked(app.rpc("debug.surfaces", {}))
                chat_pages = (value.get("hibernation") or {}).get("chat_pages") or []
                return {"page_live": tab in chat_pages, "chat_pages": chat_pages}
            released = wait_for(release_state, lambda state: state.get("page_live") is False, seconds=20)
            report["phases"]["released"] = {**released, "hidden_seconds": time.monotonic() - hidden_at}
            # The existing recorder follows the real tab reveal, keeping the first saved-cover frame.
            strip = checked(app.rpc("debug.new_tab", {"action": "frame_strip", "key": "[",
                                                      "modifiers": ["command", "shift"], "repeat": 1,
                                                      "duration_ms": 1800, "scale": 1,
                                                      "dir": str(out / "wake-frames")}))
            report["wake_frames"] = strip

            def read_after():
                return {"draft": pane("compose_draft"), "scroll": pane("scroll_state"), "chat": pane("chat_state")}

            after = wait_for(read_after, lambda state: matching_restore(before, state)
                             and state["chat"].get("sessionId") == session, seconds=30)
            report["phases"]["after"] = after
            pane("snapshot", path=str(out / "after.png"))
            report["passed"] = True
            print(f"HIDDEN-CHAT-WAKE PASS tab={tab} draft={len(expected_draft)} "
                  f"scroll_before={before['scroll']['top']} scroll_after={after['scroll']['top']} "
                  f"released=true saved_cover_frames={bool(strip)}", flush=True)
    except Exception as error:
        report["error"] = str(error)
        print(f"HIDDEN-CHAT-WAKE FAIL {error}", file=sys.stderr, flush=True)
    finally:
        if app and workspace:
            bm.close_workspace(app, workspace)
        if scratch:
            if app:
                app.run("quitKeepSessions")
            bm.end_bundle(args.app)
            shutil.rmtree(scratch, ignore_errors=True)
        (out / "report.json").write_text(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
