#!/usr/bin/env python3
"""The ACP agent of chat-open-bench.py: acpmux's test agent (fake_agent.py) with two more prompts.

  "turn: N"       a realistic answered turn N: a thought, two tool calls with output, and a
                  few paragraphs of Markdown with a code block
  "bloat: C U K"  a turn of C running commands whose output acpmux receives as U tool_call_update
                  records each, every one re-sending the whole output so far (K KiB): the shape of
                  a long Codex exec in acpmux's log (27,564 updates for 223 calls, about 5 KB each)
  "subagents: K"  a turn that starts K subagents (subagent_spawned), each with a thought, eight
                  tool calls with output and a reply of its own, then ends them all (completed)

Every other prompt is fake_agent.py's. Nothing here waits on a timer: each turn answers as fast
as acpmux reads it, so seeding thousands of turns costs only acpmux's own time.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE = os.environ.get("CHAT_OPEN_FAKE_AGENT") or os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
if not os.path.exists(FAKE):
    FAKE = os.path.join(HERE, "fake_agent.py")  # a copy beside this file (a bench folder outside the repo)
spec = importlib.util.spec_from_file_location("fake_agent", FAKE)
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)
original = fake.handle_prompt

PARAGRAPH = ("The change keeps the reader's place while older history loads: the anchor row is "
             "measured before the prepend and the scroll offset moves by exactly the height that "
             "arrived above it, so nothing on screen shifts. ")


def text(sid, value, kind="agent_message_chunk"):
    fake.update(sid, {"sessionUpdate": kind, "content": {"type": "text", "text": value}})


def tool(sid, call_id, title, output):
    fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": call_id, "title": title, "kind": "execute",
                      "status": "in_progress", "rawInput": {"command": title}})
    fake.update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "completed",
                      "content": [{"type": "content", "content": {"type": "text", "text": output}}]})


def turn(sid, n):
    text(sid, f"Looking at step {n}: which files the change touches and what the tests cover.", "agent_thought_chunk")
    tool(sid, f"t{n}-a", f"rg -n 'anchor' webviews/src --glob '*.ts' | head -n 20",
         "\n".join(f"webviews/src/file{i}.ts:{40 + i}: const anchor = rows[{i}]" for i in range(12)))
    tool(sid, f"t{n}-b", "bun test test/agent-pane-history-paging.test.ts",
         "bun test v1.3\n\n 14 pass\n 0 fail\n 61 expect() calls\nRan 14 tests across 1 file. [412.00ms]")
    body = (f"## Step {n}\n\n" + PARAGRAPH * 3 + "\n\n" + PARAGRAPH * 2 +
            "\n\n```ts\nconst before = anchor.getBoundingClientRect().top;\nprepend(rows);\n"
            "scroller.scrollTop += anchor.getBoundingClientRect().top - before;\n```\n\n"
            "- the anchor is the first row in view\n- the offset moves once, in the same frame\n")
    text(sid, body)


def subagents(sid, count):
    text(sid, f"Splitting the audit across {count} subagents.")
    for k in range(count):
        child = f"{sid}-sub-{k}"
        fake.update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": child, "name": f"Auditor {k}",
                          "task": f"Audit area {k}: crashes, edge cases, slow paths", "capabilities": {}})
        text(child, f"Reading area {k} first.", "agent_thought_chunk")
        for c in range(8):
            tool(child, f"{child}-c{c}", f"rg -n 'TODO|FIXME' area{k}/part{c}",
                 "\n".join(f"area{k}/part{c}/f{i}.swift:{10 + i}: // TODO" for i in range(6)))
        text(child, f"Area {k}: " + PARAGRAPH * 2)
    for k in range(count):
        fake.update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": f"{sid}-sub-{k}",
                          "state": "completed"})
    text(sid, "Every subagent reported; the findings are above.")


def bloat(sid, calls, updates, kib):
    output = ("cargo build: compiling crate ... ok\n" * (kib * 32))[: kib * 1024]
    for c in range(calls):
        call_id = f"bloat-{c}"
        fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": call_id, "title": f"cargo test -p part{c}",
                          "kind": "execute", "status": "in_progress", "rawInput": {"command": f"cargo test -p part{c}"}})
        for _ in range(updates):
            fake.update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "in_progress",
                              "content": [{"type": "content", "content": {"type": "text", "text": output}}]})
        fake.update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "completed",
                          "content": [{"type": "content", "content": {"type": "text", "text": output}}]})
    text(sid, "Every command finished.")


def handle_prompt(rid, params):
    sid = params["sessionId"]
    said = "".join(block.get("text", "") for block in params.get("prompt", [])).strip()
    if said.startswith("turn:"):
        turn(sid, said[5:].strip())
    elif said.startswith("bloat:"):
        calls, updates, kib = (int(v) for v in said[6:].split())
        bloat(sid, calls, updates, kib)
    elif said.startswith("subagents:"):
        subagents(sid, int(said[10:].strip() or "3"))
    else:
        original(rid, params)
        return
    fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


fake.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.argv[0] = FAKE
    fake.main()
