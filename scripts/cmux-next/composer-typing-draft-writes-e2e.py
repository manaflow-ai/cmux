#!/usr/bin/env python3
"""Typing in an agent chat sends acpmux one draft write per pause, not one per key (issue #48612).

  composer-typing-draft-writes-e2e.py --socket SOCKET --fake-agent PATH [--keys N] [--expect fixed|base]

Runs against a running no-activate tagged build (its control socket). An agent chat gets a
session from acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py, harness `fake`).
Keys go to the chat's own page window (`debug.key target: page`), back to back, as a person
types. The page's wire log to acpmux (`debug.agent_pane acp_log`) counts `_acpmux/draft_set`
during the burst and after typing pauses; `typing_stats` gives key to paint.

Before the fix every key was a `_acpmux/draft_set` (acpmux saved meta, journaled and re-dated the
chat's row for each). With it: the draft's first key, at most one per second while typing goes
on, and one once typing pauses, holding the whole text. Checks (`--expect fixed`): the composer
holds every key, the burst sends at most 1 + its seconds writes and fewer than a quarter of the
keys, and the last write after the pause holds the full text. `--expect base` only reports.
Quits nothing: the caller ends the build.
"""
import argparse, json, math, os, shlex, socket, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the build's control socket")
parser.add_argument("--fake-agent", required=True, help="path of acpmux's tests/fake_agent.py")
parser.add_argument("--keys", type=int, default=60)
parser.add_argument("--expect", choices=["fixed", "base"], default="fixed")
opts = parser.parse_args()
failures = []


def rpc(method, params=None, timeout=30):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(opts.socket)
    conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    conn.close()
    reply = json.loads(buf)
    return reply.get("result", reply)


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test script: polls the app's state
    return predicate()


def check(ok, what):
    print(("ok   " if ok else ("FAIL " if opts.expect == "fixed" else "info ")) + what, flush=True)
    if not ok and opts.expect == "fixed":
        failures.append(what)


def focus():
    window = (rpc("debug.focus").get("windows") or [{}])[0]
    return window.get("model") or {}


def pane_action(pane, action, **extra):
    return rpc("debug.agent_pane", {"action": action, "pane": pane, **extra}, timeout=60)


def draft_sets(pane):
    entries = pane_action(pane, "acp_log").get("entries") or []
    return [e for e in entries if e.get("dir") == "out" and e.get("method") == "_acpmux/draft_set"]


def main():
    folder = tempfile.mkdtemp(prefix="composer-draft-writes-")
    rpc("action.run", {"action": "agent.harness.add", "args": {"id": "fake", "name": "Fake", "command": sys.executable,
                                                               "args": shlex.quote(os.path.abspath(opts.fake_agent)),
                                                               "protocol": "acp", "replace": "true"}})
    rpc("debug.key", {"key": "t", "modifiers": ["cmd"]})
    chat = wait(lambda: focus().get("resolved") == "agentPage" and focus().get("resolved_pane"), 30)
    if not chat:
        sys.exit(f"no agent page took the focus: {focus()}")
    made = pane_action(chat, "new_chat", harness="fake", cwd=folder)
    # The reply can come before the chat has its session: read it from the chat's state.
    session = made.get("sessionId") or wait(lambda: pane_action(chat, "chat_state").get("sessionId"), 30)
    if not session:
        sys.exit(f"new_chat made no session: {made}")
    made["sessionId"] = session
    wait(lambda: pane_action(chat, "chat_state").get("connection") == "attached", 30)
    print(f"chat pane {chat}, session {made.get('sessionId')}, load average {os.getloadavg()[0]:.1f} "
          f"on {os.cpu_count()} cores", flush=True)

    text = ("buy bread and milk then ship the release notes " * 4)[: opts.keys]
    # Escape ends a type-ahead queue held for a page the app never saw ready (an app not active):
    # keys after it go to the chat's page. Then the composer takes the focus, as after a click.
    rpc("debug.key", {"key": "escape", "target": "page", "pane": chat})
    pane_action(chat, "focus_composer")
    prior = pane_action(chat, "typing_stats").get("composer_text") or ""
    text = prior + text
    pane_action(chat, "reset_typing")
    before = len(draft_sets(chat))
    start = time.monotonic()
    routed = [rpc("debug.key", {"key": "space" if key == " " else key, "target": "page", "pane": chat}).get("handled_by")
              for key in text[len(prior):]]
    typing_s = time.monotonic() - start
    check(routed == ["page"] * len(routed), f"every key reached the chat's page ({sorted(set(routed))})")
    burst = draft_sets(chat)[before:]
    stats = pane_action(chat, "typing_stats")
    held = wait(lambda: (stats_text := (pane_action(chat, "typing_stats").get("composer_text") or "")) == text and stats_text, 5)
    # Typing pauses: the waiting write goes (draftWriteLimits.typedIdleMs, 400 ms).
    wait(lambda: len(draft_sets(chat)) - before > len(burst), 3)
    time.sleep(1.0)  # test script: lets any late write land before counting
    after = draft_sets(chat)[before:]
    last = after[-1] if after else {}

    summary = {key: stats.get(key) for key in stats if key not in ("composer_text", "native_posts", "samples")}
    print(f"keys {len(routed)} in {typing_s:.2f} s; draft_set during burst {len(burst)}, after pause {len(after)}",
          flush=True)
    print("typing_stats " + json.dumps(summary, default=str)[:600], flush=True)
    check(bool(held), f"the composer holds every key ({len(stats.get('composer_text') or '')}/{len(text)})")
    bound = 1 + math.ceil(typing_s)
    check(len(burst) <= bound and len(burst) < len(routed) / 4,
          f"the burst sent {len(burst)} draft writes for {len(routed)} keys (at most {bound})")
    check(text in (last.get("text") or "") or last.get("size", 0) >= len(text),
          f"the last draft write holds the whole text (size {last.get('size')})")
    print("RESULT " + ("FAIL: " + "; ".join(failures) if failures else "PASS"), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
