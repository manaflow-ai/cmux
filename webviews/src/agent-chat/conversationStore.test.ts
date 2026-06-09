import { describe, expect, test } from "bun:test";
import {
  applyAgentEvent,
  initialConversationState,
  reduceConversation,
  type ConversationState,
} from "./conversationStore";
import type { AgentSessionRef, ConversationItem } from "./protocol";

const session: AgentSessionRef = {
  provider: "claude",
  session_id: "abc-123",
  transcript_path: "/tmp/abc-123.jsonl",
  cwd: "/Users/dev/project",
};

function item(id: string, overrides: Partial<ConversationItem> = {}): ConversationItem {
  return { id, type: "assistant_message", status: "completed", text: id, ...overrides };
}

function snapshotted(items: ConversationItem[], seq = 1): ConversationState {
  return applyAgentEvent(initialConversationState(), {
    type: "snapshot",
    seq,
    session,
    items,
  });
}

describe("applyAgentEvent", () => {
  test("snapshot replaces items, sets session, and resets the cursor", () => {
    const state = snapshotted([item("a"), item("b")], 5);
    expect(state.items.map((entry) => entry.id)).toEqual(["a", "b"]);
    expect(state.session).toEqual(session);
    expect(state.lastSeq).toBe(5);
    expect(state.hasSnapshot).toBe(true);
  });

  test("a fresh snapshot applies even when its seq is lower (reconnect)", () => {
    const state = snapshotted([item("a")], 50);
    const next = applyAgentEvent(state, { type: "snapshot", seq: 1, session, items: [item("z")] });
    expect(next.items.map((entry) => entry.id)).toEqual(["z"]);
    expect(next.lastSeq).toBe(1);
  });

  test("item.started appends and item.completed updates in place", () => {
    const started = applyAgentEvent(snapshotted([item("a")]), {
      type: "item.started",
      seq: 2,
      item: item("tool-1", { type: "command_execution", status: "in_progress", title: "ls" }),
    });
    expect(started.items.map((entry) => entry.id)).toEqual(["a", "tool-1"]);

    const completed = applyAgentEvent(started, {
      type: "item.completed",
      seq: 3,
      item: item("tool-1", {
        type: "command_execution",
        status: "completed",
        title: "ls",
        output: { text: "README.md" },
      }),
    });
    expect(completed.items.map((entry) => entry.id)).toEqual(["a", "tool-1"]);
    expect(completed.items[1]?.status).toBe("completed");
    expect(completed.items[1]?.output?.text).toBe("README.md");
  });

  test("stale and duplicate seqs are dropped", () => {
    const state = snapshotted([item("a")], 4);
    const dup = applyAgentEvent(state, { type: "item.completed", seq: 4, item: item("late") });
    expect(dup).toBe(state);
    const stale = applyAgentEvent(state, { type: "item.completed", seq: 2, item: item("late") });
    expect(stale).toBe(state);
  });

  test("stream errors record and the next snapshot clears them", () => {
    const errored = applyAgentEvent(snapshotted([item("a")]), {
      type: "error",
      seq: 2,
      message: "transcript unreadable",
      recoverable: true,
    });
    expect(errored.streamError).toEqual({ message: "transcript unreadable", recoverable: true });
    const recovered = applyAgentEvent(errored, { type: "snapshot", seq: 3, session, items: [] });
    expect(recovered.streamError).toBeNull();
  });

  test("session.meta updates the session ref", () => {
    const renamed = { ...session, title: "Fix the parser" };
    const next = applyAgentEvent(snapshotted([item("a")]), {
      type: "session.meta",
      seq: 2,
      session: renamed,
    });
    expect(next.session?.title).toBe("Fix the parser");
  });
});

describe("reduceConversation", () => {
  test("init applies daemon status and optional session", () => {
    const next = reduceConversation(initialConversationState(), {
      type: "init",
      result: { session, daemon_status: "ready" },
    });
    expect(next.phase).toBe("ready");
    expect(next.session).toEqual(session);
    expect(next.daemonStatus).toBe("ready");
  });

  test("init-failed marks the daemon unavailable with detail", () => {
    const next = reduceConversation(initialConversationState(), {
      type: "init-failed",
      detail: "binary missing",
    });
    expect(next.phase).toBe("failed");
    expect(next.daemonStatus).toBe("unavailable");
    expect(next.daemonDetail).toBe("binary missing");
  });

  test("daemon.status frames update status without touching items", () => {
    const ready = reduceConversation(initialConversationState(), {
      type: "init",
      result: { session, daemon_status: "ready" },
    });
    const withItems = {
      ...ready,
      ...snapshotted([item("a")]),
    };
    const next = reduceConversation(withItems, {
      type: "inbound",
      message: { type: "daemon.status", status: "unavailable", detail: "daemon exited" },
    });
    expect(next.daemonStatus).toBe("unavailable");
    expect(next.daemonDetail).toBe("daemon exited");
    expect(next.items).toEqual(withItems.items);
  });
});
