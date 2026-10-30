// A Codex chat's native root changes live (a harness restart, a new conversation): acpmux sends a
// `session_changed` with the new `agentSessionId` and the pane does not rebuild. The subagent fold
// must still learn that id as a root (SubagentFold.setRoot), so a record naming it as a parent
// repairs a child the older records nested wrongly, and an echo of it never becomes a subagent.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type EventRecord = { msg: { params: Record<string, unknown> } };
type Daemon = {
  record: (target: string, step: unknown, at?: number) => EventRecord;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  deliver: (message: unknown) => void;
};
type Row = { subagents?: { id: string; parent: string | null }[] };
type Shown = { summary?: unknown; rows?: Row[] };

/// A pane on the mock daemon, with the helpers each case drives it through.
async function openPane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const id = mockHost.sessionId!;
  const view = { shown: {} as Shown };
  const snapshots: Array<() => void> = [];
  const next = () => new Promise<void>((resolve) => snapshots.push(resolve));
  const until = async (check: () => boolean) => {
    while (!check()) await next();
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot as unknown as Shown;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  // Subagent changes as acpmux annotates them, without Codex sender metadata (older records).
  const changes = (subagents: unknown[]) => {
    const event = daemon.record(id, { update: { sessionUpdate: "subagent_spawned" } });
    event.msg.params._meta = { acpmux: { subagents } };
    daemon.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
  };
  // The snapshot's summary is a projection without the native id: read the pane's own summary.
  const root = () => (client as unknown as { summary?: { agentSessionId?: string } }).summary?.agentSessionId;
  const topLevel = () =>
    (view.shown.rows ?? [])
      .flatMap((row) => row.subagents ?? [])
      .map(({ id: agent, parent }) => [agent, parent])
      .sort(([a], [b]) => String(a).localeCompare(String(b)));
  await until(() => view.shown.summary !== undefined);
  return { client, daemon, id, next, until, changes, root, topLevel };
}

test("a root learned from a live session_changed repairs and never folds as a subagent", async () => {
  const { client, daemon, id, until, changes, root, topLevel } = await openPane();
  try {
    daemon.touch(id, { harness: "codex", agentSessionId: "root-1" });
    await until(() => root() === "root-1");
    changes([{ id: "child", parent: null }]);
    // A malformed record nested the helper under the child.
    changes([{ id: "helper", parent: "child" }]);
    await until(() => topLevel().some(([agent]) => agent === "child"));

    // The harness restarts: a new native root, never named by a record yet, so no rebuild.
    daemon.touch(id, { agentSessionId: "root-2" });
    await until(() => root() === "root-2");
    // The new root echoed as the child's subagent, then a record naming it as the helper's parent.
    changes([{ id: "root-2", parent: "child" }]);
    changes([{ id: "helper", parent: "root-2" }]);
    changes([{ id: "marker", parent: null }]);
    await until(() => topLevel().some(([agent]) => agent === "marker"));

    expect(topLevel()).toEqual([
      ["child", null],
      ["helper", null],
      ["marker", null],
    ]);
  } finally {
    client.close?.();
  }
});

// Reopening a chat (or any rebuild) makes a new fold, which knows only the roots the session
// summary names. A Codex chat's earlier native roots are in `retiredAgentSessionIds`: records from
// before a restart that echoed an earlier root are folded with that root known, not as a subagent.
test("a rebuild keeps every earlier native root the summary names a root", async () => {
  const { client, daemon, id, until, changes, root, topLevel } = await openPane();
  try {
    // Written before acpmux knew either root: the first root echoed as a subagent, then the
    // second as the child's.
    changes([{ id: "root-1", parent: null }]);
    changes([{ id: "child", parent: null }]);
    changes([{ id: "root-2", parent: "child" }]);
    await until(() => topLevel().some(([agent]) => agent === "child"));

    // The summary names the current root and the earlier one; a record named the current root,
    // so the pane folds its records again.
    daemon.touch(id, { harness: "codex", agentSessionId: "root-2", retiredAgentSessionIds: ["root-1"] });
    await until(() => root() === "root-2");
    changes([{ id: "marker", parent: null }]);
    await until(() => topLevel().some(([agent]) => agent === "marker"));

    expect(topLevel()).toEqual([
      ["child", null],
      ["marker", null],
    ]);
  } finally {
    client.close?.();
  }
});

// A session_changed can name an earlier root as retired while the current root is already known:
// learnChatThread has nothing to learn, so the pane must fold again by itself. No later update
// comes to flush the fold's rows, so the phantom group must be gone from that change alone.
test("a retired root learned live leaves the transcript with no later update", async () => {
  const { client, daemon, id, next, until, changes, root, topLevel } = await openPane();
  try {
    daemon.touch(id, { harness: "codex", agentSessionId: "root-2" });
    await until(() => root() === "root-2");
    // Records written before acpmux knew root-1: it drew as a subagent with a worker under it.
    changes([{ id: "root-1", parent: null }]);
    changes([{ id: "helper", parent: "root-1" }]);
    await until(() => topLevel().some(([agent]) => agent === "root-1"));

    // The change's own snapshot is the next one: nothing else is sent.
    const drawn = next();
    daemon.touch(id, { retiredAgentSessionIds: ["root-1"] });
    await drawn;
    const retired = (client as unknown as { summary?: { retiredAgentSessionIds?: string[] } }).summary;
    expect(retired?.retiredAgentSessionIds).toEqual(["root-1"]);

    expect(topLevel()).toEqual([["helper", null]]);
  } finally {
    client.close?.();
  }
});
