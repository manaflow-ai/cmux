// l10n-allow-file: test fixture subagent names and text, not shipped UI.
// Leo, 2026-10-22, on a Codex chat's running tray: "why is it like... staggered? were they created
// by another subagent?" They were not. A child (needs_you_review) reported the chat's own thread as
// running, an older acpmux recorded the chat as that child's subagent, and from then on tagged the
// chat's own words and spawns with the chat's thread. The pane reads such records by lineage: the
// chat's thread (its summary's `agentSessionId`) is never a subagent, a parent or an owner, also
// when the pane learns that thread only after it folded the records.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";

const CHAT = "01a1658b-c23e-7bc1-b98e-c27c7ff0eace";
const THREAD = "01a1658b-c32f-72b1-ab04-d5444235a91c";
const REVIEW = "01a16655-c696-7982-9c38-9ededd986f9b";
const PRIOR_ART = "01a16656-bb2d-7513-b459-4a893451d37a";
const START = Date.UTC(2026, 9, 22, 9, 0, 0);

const update = (sessionId: string, update: Record<string, unknown>, acpmux: Record<string, unknown> = {}) => ({
  method: "session/update",
  params: { sessionId, update, _meta: { acpmux } },
});
const say = (text: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });

/// The chat's records as the older acpmux wrote them.
const history = [
  ["mux", "user_message", { text: "Review the Needs you work" }],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", update(THREAD, say("Starting the reviews."))],
  [
    "in",
    "subagent_spawned",
    update(
      THREAD,
      { sessionUpdate: "subagent_spawned", subagentSessionId: REVIEW, name: "needs_you_review" },
      { subagents: [{ id: REVIEW, parent: null, name: "needs_you_review", state: "running" }] },
    ),
  ],
  [
    "in",
    "subagent_state_update",
    update(
      REVIEW,
      { sessionUpdate: "subagent_state_update", subagentSessionId: THREAD, state: "running" },
      { subagent: REVIEW, subagents: [{ id: THREAD, parent: REVIEW, state: "running" }] },
    ),
  ],
  [
    "in",
    "subagent_spawned",
    update(
      THREAD,
      { sessionUpdate: "subagent_spawned", subagentSessionId: PRIOR_ART, name: "needs_you_prior_art" },
      { subagent: THREAD, subagents: [{ id: PRIOR_ART, parent: THREAD, name: "needs_you_prior_art" }] },
    ),
  ],
  ["in", "agent_message_chunk", update(THREAD, say("Both reviewers are running."), { subagent: THREAD })],
].map(([dir, kind, msg], index) => ({
  sessionId: CHAT,
  seq: index + 1,
  at: START + (index + 1) * 1000,
  dir,
  kind,
  msg,
}));

/// A daemon over a fake socket: attach answers with the history from `from` on (a page that starts
/// mid-history), and the chat's summary names its thread only when `thread` is given.
function fakeDaemon(thread: string | undefined, from = 1) {
  let socket: any;
  const session: Record<string, unknown> = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "helo",
    harness: "codex",
    family: "codex",
    status: "running",
    turnCount: 1,
    updatedAt: START,
    ...(thread && { agentSessionId: thread }),
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.length, events: history.filter((event) => event.seq >= from) };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: history.length };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  /// acpmux tells its watchers the chat's summary changed.
  const changed = (fields: Record<string, unknown>) => {
    Object.assign(session, fields);
    socket.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: CHAT, session, kind: "updated" },
      }),
    });
  };
  /// The watch lagged: the pane reads the session list again, which now names the thread.
  const lagged = (fields: Record<string, unknown>) => {
    Object.assign(session, fields);
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { watch: true, sessionIds: [] } }),
    });
  };
  return { open, changed, lagged };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const waiters = new Set<() => void>();
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => {
      rows = snapshot.rows;
      for (const wake of waiters) wake();
    },
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  /// Resolves on the first snapshot (or the current one) whose rows satisfy `holds`.
  const until = (holds: (rows: AcpmuxRow[]) => boolean) =>
    new Promise<void>((resolve) => {
      const wake = () => {
        if (!holds(rows)) return;
        waiters.delete(wake);
        resolve();
      };
      waiters.add(wake);
      wake();
    });
  return { client, rows: () => rows, until };
}

const lineage = (rows: AcpmuxRow[]) =>
  rows
    .filter((row) => row.kind === SUBAGENTS)
    .flatMap((row) => row.subagents!.map((agent) => [agent.name, agent.parent]));
/// The prior_art subagent reads as the chat's own, not nested under the chat.
const sideBySide = (rows: AcpmuxRow[]) =>
  lineage(rows).some(([name, parent]) => name === "needs_you_prior_art" && parent === null);
const said = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "assistant").map((row) => row.text);

test("the chat's thread is never its own subagent: its children sit side by side and its words stay", async () => {
  const { client, rows } = await connect(fakeDaemon(THREAD));
  expect(lineage(rows())).toEqual([
    ["needs_you_review", null],
    ["needs_you_prior_art", null],
  ]);
  expect(said(rows()).join(" ")).toContain("Both reviewers are running.");
  client.close?.();
});

test("a thread learned after the fold folds the records again by lineage", async () => {
  const daemon = fakeDaemon(undefined);
  const { client, rows, until } = await connect(daemon);
  // Not yet known: the records read as the older acpmux wrote them.
  expect(lineage(rows()).map(([name]) => name)).toEqual(["needs_you_review"]);
  daemon.changed({ agentSessionId: THREAD });
  await until(sideBySide);
  expect(lineage(rows())).toEqual([
    ["needs_you_review", null],
    ["needs_you_prior_art", null],
  ]);
  expect(said(rows()).join(" ")).toContain("Both reviewers are running.");
  client.close?.();
});

test("a page that starts after the record that made the chat a subagent folds again too", async () => {
  // From the prior_art spawn on: the chat is named only as that spawn's parent and as an owner.
  const daemon = fakeDaemon(undefined, 6);
  const { client, rows, until } = await connect(daemon);
  daemon.changed({ agentSessionId: THREAD });
  await until(sideBySide);
  expect(lineage(rows())).toEqual([["needs_you_prior_art", null]]);
  expect(said(rows()).join(" ")).toContain("Both reviewers are running.");
  client.close?.();
});

test("a thread learned from a reread of the session list folds the records again", async () => {
  const daemon = fakeDaemon(undefined);
  const { client, rows, until } = await connect(daemon);
  daemon.lagged({ agentSessionId: THREAD });
  await until(sideBySide);
  expect(lineage(rows())).toEqual([
    ["needs_you_review", null],
    ["needs_you_prior_art", null],
  ]);
  client.close?.();
});
