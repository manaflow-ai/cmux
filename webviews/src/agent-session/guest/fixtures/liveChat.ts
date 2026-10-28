// l10n-allow-file: gallery and test fixtures (a made-up shared chat), not shipped UI.
// A shared chat as the room sends it to a guest (`cmux.share/1`): a snapshot of the daemon's
// transcript records (acpmux `_acpmux/event` params) in the middle of a turn: the owner's prompt,
// the agent's reasoning, a test run with its output, and a second run, either still going or
// waiting on the owner's answer. `fakeRoom` plays frames to the page as the room would.
import type { EventRecord } from "../../acpmux/direct";
import type { GuestPrompt } from "../guestPrompts";
import type { ShareSocketLike } from "../shareSocket";

const MINUTE = 60_000;
/** The gallery clock's now (gallery/clock.ts GALLERY_NOW), so "Working for" reads the same each run. */
const NOW = Date.UTC(2026, 9, 6, 9, 41, 0);

type Step = [agoMs: number, dir: string, kind: string, msg: Record<string, any>];

const update = (sessionUpdate: string, fields: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
});
const output = (text: string) => [{ type: "content", content: { type: "text", text } }];
const run = (toolCallId: string, command: string) => ({
  toolCallId,
  title: command,
  kind: "execute",
  status: "in_progress",
  rawInput: { command },
});

const WORKING: Step[] = [
  [3 * MINUTE, "mux", "user_message", { text: "The upload retry test is flaky on CI. Find out why and fix it." }],
  [3 * MINUTE - 500, "mux", "turn_started", {}],
  [
    3 * MINUTE - 4_000,
    "in",
    "agent_thought_chunk",
    update("agent_thought_chunk", {
      content: {
        type: "text",
        text: "The test fakes two timeouts but the retry waits on a real timer, so a slow runner can run out the test's own deadline. Run it a few times to confirm before changing anything.",
      },
    }),
  ],
  [2 * MINUTE, "in", "tool_call", update("tool_call", run("run-1", "bun test src/upload.test.ts --rerun-each 5"))],
  [
    MINUTE + 20_000,
    "in",
    "tool_call_update",
    update("tool_call_update", {
      toolCallId: "run-1",
      status: "failed",
      content: output(
        "src/upload.test.ts:\n✓ uploads in one part\n✗ retries twice after timeouts [5012ms]\n  error: Test timed out after 5000ms\n\n4 pass, 1 fail (5 runs)",
      ),
    }),
  ],
  [
    MINUTE,
    "in",
    "agent_message_chunk",
    update("agent_message_chunk", {
      content: {
        type: "text",
        text: "It fails one run in five: the backoff sleeps 2 s and 4 s on the real clock. I'll inject the clock so the test advances it instead.",
      },
    }),
  ],
];

const ASK = {
  sessionId: "agent-1",
  toolCall: run("run-2", "bun test src/upload.test.ts --rerun-each 20"),
  options: [
    { optionId: "allow_once", name: "Allow", kind: "allow_once" },
    { optionId: "reject_once", name: "Reject", kind: "reject_once" },
  ],
};

/** The turn still running its second test run. */
export const workingRecords = (): EventRecord[] =>
  records([
    ...WORKING,
    [20_000, "in", "tool_call", update("tool_call", run("run-2", "bun test src/upload.test.ts --rerun-each 20"))],
  ]);

/** The second run waits on the owner's answer to its permission ask. */
export const askingRecords = (): EventRecord[] =>
  records([
    ...WORKING,
    [20_000, "in", "tool_call", update("tool_call", { ...ASK.toolCall, status: "pending" })],
    [19_000, "mux", "permission_request", { permissionId: "perm-1", request: ASK }],
  ]);

function records(steps: Step[]): EventRecord[] {
  return steps.map(([ago, dir, kind, msg], index) => ({
    sessionId: "s",
    seq: index + 1,
    at: NOW - ago,
    dir,
    kind,
    msg,
  }));
}

export const OWNER = { id: "owner-1", name: "Sam Rivera", kind: "owner", viewing: true, typing: false };
export const GUEST = { id: "guest:share.g1", name: "Ana", kind: "guest", viewing: true, typing: false };

/** The frames a room sends a guest on connect: presence, then the snapshot. */
export const joinFrames = (
  snapshot: EventRecord[],
  title = "Fix the flaky upload retry test",
  prompts: { client_id: string; state: string; reason?: string }[] = [],
) => [
  { v: 1, t: "presence", to: ["g1"], participants: [OWNER, GUEST] },
  {
    v: 1,
    t: "snapshot",
    to: "g1",
    chat: { title, harness: "claude", status: "running" },
    records: snapshot,
    watermark: snapshot.at(-1)?.seq ?? 0,
    has_more: false,
    prompts,
  },
];

/** A room that answers every connect with `frames`, after the page has hooked the socket up. */
export function fakeRoom(frames: object[]): (url: string) => ShareSocketLike {
  return () => {
    const socket: ShareSocketLike = {
      send: () => undefined,
      close: () => undefined,
      onopen: null,
      onmessage: null,
      onclose: null,
    };
    queueMicrotask(() => {
      for (const frame of frames) socket.onmessage?.({ data: JSON.stringify(frame) });
    });
    return socket;
  };
}

/** A tab's sessionStorage, in memory: optionally holding this guest's own messages already. */
export function memoryStorage(shareId?: string, prompts?: GuestPrompt[]): Storage {
  const items = new Map<string, string>();
  if (shareId && prompts) items.set(`cmux.guest.${shareId}.prompts`, JSON.stringify(prompts));
  return {
    get length() {
      return items.size;
    },
    clear: () => items.clear(),
    key: (index: number) => [...items.keys()][index] ?? null,
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, String(value)),
    removeItem: (key: string) => void items.delete(key),
  };
}
