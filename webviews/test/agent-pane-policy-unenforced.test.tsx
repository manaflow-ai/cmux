// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A chat with a permission policy narrower than approve-all on a harness that has no mode that asks
// (OpenCode, whose own settings decide what it asks; pi; an ACP agent with no modes) cannot keep the
// policy: acpmux logs `policy_unenforced` (hub/policy_mode.rs). No client drew it, so the chat
// said "Approve reads" while its agent edited and ran commands without asking.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d3";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// A daemon over a fake socket for a chat on `harness`: attach answers with `history`; `push`
/// sends live events.
function fakeDaemon(history: Recorded[], harness: string, family: string) {
  let socket: any;
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness, family, status: "idle" };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: lastSeq(), events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: lastSeq() };
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
  const push = (events: Recorded[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await until(() => snapshot?.connection === "connected", "the attach");
  const notes = () =>
    (snapshot.rows as AcpmuxRow[]).filter((row) => row.kind === "policyUnenforced").map((row) => row.policyUnenforced);
  return { client, notes };
}

// acpmux's reasons (web_modes.rs OPENCODE_REFUSAL, NO_ASKING_MODE): a hint, never shown.
const OPENCODE_REFUSAL = "opencode's own settings on this Mac can let it edit and run commands without asking";
const NO_ASKING_MODE = "this agent has no mode that asks before each change";

test("a policy OpenCode cannot keep is noted where acpmux logged it", async () => {
  const daemon = fakeDaemon(
    record([["mux", "policy_unenforced", { policy: "approve-reads", modeId: "build", reason: OPENCODE_REFUSAL }]]),
    "opencode",
    "opencode",
  );
  const { client, notes } = await connect(daemon);
  try {
    expect(notes()).toEqual([{ policy: "approve-reads", why: "ownSettings" }]);
    // A narrower policy set later that it cannot keep either gets its own note.
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "fix the build" }],
          ["mux", "policy_unenforced", { policy: "deny-all", modeId: "build", reason: OPENCODE_REFUSAL }],
        ],
        2,
      ),
    );
    await until(() => notes().length === 2, "the second note");
    expect(notes()[1]).toEqual({ policy: "deny-all", why: "ownSettings" });
  } finally {
    client.close();
  }
});

test("a policy a harness with no mode that asks cannot keep is noted", async () => {
  const daemon = fakeDaemon(
    record([["mux", "policy_unenforced", { policy: "ask", modeId: null, reason: NO_ASKING_MODE }]]),
    "pi",
    "pi",
  );
  const { client, notes } = await connect(daemon);
  try {
    expect(notes()).toEqual([{ policy: "ask", why: "noAskingMode" }]);
  } finally {
    client.close();
  }
});

// A chat the pane read before is drawn from its kept tail before its summary is back: the note comes
// from the record alone, so it says the same thing either way.
test("the note comes from the record, not the chat's summary", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "policy_unenforced", { policy: "approve-reads", modeId: "build", reason: OPENCODE_REFUSAL }],
      ["mux", "policy_unenforced", { policy: "deny-all", modeId: null, reason: NO_ASKING_MODE }],
    ]),
    "",
    "",
  );
  const { client, notes } = await connect(daemon);
  try {
    expect(notes()).toEqual([
      { policy: "approve-reads", why: "ownSettings" },
      { policy: "deny-all", why: "noAskingMode" },
    ]);
  } finally {
    client.close();
  }
});

test("the note names the policy and why, never acpmux's reason", async () => {
  const { PolicyUnenforcedNote } = await import("../src/agent-session/acpmux/conversation/CompactionNote");
  const drawn = (note: Parameters<typeof PolicyUnenforcedNote>[0]["note"]) =>
    renderToStaticMarkup(<PolicyUnenforcedNote note={note} />)
      .replace(/<[^>]+>/g, " ")
      .replace(/&#x27;/g, "'")
      .replace(/\s+/g, " ")
      .trim();
  expect(drawn({ policy: "approve-reads", why: "ownSettings" })).toBe(
    "OpenCode can't keep this chat's permission policy (Approve reads): its own settings decide what it asks",
  );
  expect(drawn({ policy: "deny-all", why: "noAskingMode" })).toBe(
    "This chat's agent has no mode that asks before each change, so it can't keep the permission policy (Deny all)",
  );
});
