// l10n-allow-file: test fixture prompts, not shipped UI.
// The owner's own `acpmux send` from a plain terminal is recorded as their prompt (acpmux
// server/requests.rs `owner_terminal`, manaflow-ai/cmux#38260): no provenance, `_meta.origin`
// person, and a CLI client. The pane reads that mark before any legacy reading of CLI text, so
// `[P1] fix the race` is the owner's bubble, as the composer's identical text is, and not a
// received card from "P1" (#38260 F2). A queued one stays the owner's row too. A CLI record from
// before the mark, and one acpmux marks unverified, still read their sender label.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "01a15779-206b-72b0-96af-bdbe4868e19c";
const START = Date.UTC(2026, 10, 8, 6, 0, 0);
const TEXT = "[P1] fix the race";
const OWNER = { origin: { actor: "person", verified: true } };
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[]) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
type Rec = ReturnType<typeof record>[number];

const base = { cwd: "/home/dev/x", harness: "claude", family: "claude", updatedAt: START };

function fakeDaemon(history: Rec[], chat: object = {}) {
  let socket: any;
  const session = { ...base, status: "idle", sessionId: CHAT, name: "lane", turnCount: 2, ...chat };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: history.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  };
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
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
}

async function snapshotOf(history: Rec[], chat: object = {}): Promise<{ rows: AcpmuxRow[]; queue: any[] }> {
  let shown: any = { rows: [], queue: [] };
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (shown = snapshot),
    undefined,
    fakeDaemon(history, chat),
  );
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return shown;
}

const turn = (promptId: string, msg: Record<string, unknown>): Step[] => [
  ["mux", "user_message", { text: TEXT, promptId, ...msg }],
  ["mux", "turn_started", { promptId }],
  ["mux", "turn_result", { stopReason: "end_turn" }],
];

test("the owner's terminal send of `[P1] fix the race` is their prompt, as the composer's is", async () => {
  const { rows } = await snapshotOf(
    record([
      ...turn("p-composer", { client: "cmux-next#0001", _meta: OWNER }),
      ...turn("p-terminal", { client: "acpmux-cli#01a2f3@my-mac", _meta: OWNER }),
      // A notice's head from the owner's terminal is their words too (agentNotice.ts `legacyNotice`).
      ...turn("p-notice", { client: "acpmux-cli#01a2f3@my-mac", _meta: OWNER, text: "[ci] PR #1 failed\nfix it" }),
    ]),
  );
  const prompts = rows.filter((row) => row.kind === "user");
  expect(prompts.map((row) => [row.text, row.incoming])).toEqual([
    [TEXT, undefined],
    [TEXT, undefined],
    ["[ci] PR #1 failed\nfix it", undefined],
  ]);
});

test("a CLI record from before the owner mark, or one acpmux marks unverified, still reads its label", async () => {
  const unverified = { provenance: { kind: "unverified", transport: "unix", verified: false } };
  const { rows } = await snapshotOf(
    record([
      ...turn("p-old", { client: "acpmux-cli#01a2f3@my-mac" }),
      ...turn("p-unverified", { client: "acpmux-cli#01a2f3@my-mac", _meta: unverified }),
    ]),
  );
  const prompts = rows.filter((row) => row.kind === "user");
  expect(
    prompts.map((row) => [row.incoming?.kind === "message" ? row.incoming.message.name : undefined, row.text]),
  ).toEqual([
    ["P1", "fix the race"],
    ["P1", "fix the race"],
  ]);
});

test("a queued owner's terminal send stays the owner's queue row", async () => {
  const history = record([
    [
      "mux",
      "user_message",
      { text: "Check it", client: "cmux-next#0001", promptId: "p-1", turnId: "t-1", _meta: OWNER },
    ],
    ["mux", "turn_started", { promptId: "p-1", turnId: "t-1" }],
    ["mux", "queued", { text: TEXT, promptId: "p-2", client: "acpmux-cli#01a2f3@my-mac", position: 1, _meta: OWNER }],
  ]);
  const queue = [{ promptId: "p-2", prompt: TEXT, turnId: "t-2", queuedAt: START, held: false }];
  const { queue: shown } = await snapshotOf(history, { status: "running", steering: true, queue });
  expect(shown.map((entry) => [entry.id, entry.prompt, entry.message])).toEqual([["p-2", TEXT, undefined]]);
});
