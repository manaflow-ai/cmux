// l10n-allow-file: test fixture prompts, not shipped UI.
// The person's steer sent while another prompt holds the turn and has not shown it yet: acpmux
// queues it until that turn shows, then steers it in (hub/queue.rs `QueuedPrompt::steer_on_start`).
// Its `queued` record says so (`steerOnStart`), and the pane keeps its bubble in the transcript: it
// never moves into a queued row over the composer and back a moment later (Leo, 2026-11-24: "my
// message passes through the composer hat/composer area and it looks like it goes through the queue
// and THEN goes properly"). A steer a failed turn holds waits for the person: a queued row then.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key] === undefined) delete scope[key];
    else scope[key] = had[key];
});

const CHAT = "0190a000-0000-7000-8000-0000000000f4";
const START = Date.UTC(2026, 10, 24, 9, 0, 0);
const STEER = "and keep the tests green";

type Snapshot = { rows: { kind: string; text?: string; failed?: boolean }[]; queue: { id: string; prompt: string }[] };

/// What follows the held steer: it steers in, a failed turn holds it, acpmux refuses it, or it is
/// withdrawn.
type Then = "steers" | "held" | "refused" | "withdrawn";

/// A chat whose first prompt holds the turn and has not shown it. A steer sent now is queued with
/// `steerOnStart` (or without it, `marked: false`, as an older acpmux sends it); `then` says what
/// follows: the turn shows and the steer goes in, or the turn fails and the queue holds it.
function daemon(then: Then, marked = true) {
  let seq = 2;
  const history = [
    { kind: "user_message", msg: { text: "Fix the layout", promptId: "p-first", turnId: "turn-1" } },
    { kind: "turn_started", msg: { promptId: "p-first", turnId: "turn-1" } },
  ].map((step, index) => ({ sessionId: CHAT, seq: index + 1, at: START + index, dir: "mux", ...step }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: true,
    turnCount: 1,
    updatedAt: START,
    queue: [],
  };
  let socket: any;
  const event = (kind: string, msg: Record<string, unknown>) =>
    socket.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: CHAT, seq: ++seq, at: START + seq, dir: "mux", kind, msg },
      }),
    });
  const reply = (id: unknown, result: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, result }) });
  const steps = {
    /// acpmux queued the steer behind the turn that has not shown.
    queue(promptId: string) {
      event("queued", {
        promptId,
        text: STEER,
        turnId: "turn-1",
        client: "pane",
        position: 1,
        ...(marked ? { steerOnStart: true } : {}),
      });
    },
    /// What came after it.
    finish(promptId: string, id: unknown) {
      if (then === "steers") {
        event("user_message", { promptId, text: STEER, turnId: "turn-1", steer: true });
        reply(id, { stopReason: "steered" });
      } else if (then === "held") event("queue_paused", { turnId: "turn-1", held: [promptId], retrying: [] });
      else if (then === "refused") event("prompt_refused", { promptId, error: "the turn ended first" });
      else event("queue_removed", { promptId });
    },
  };
  let pending: { promptId: string; id: unknown } | undefined;
  const make = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        if (message.method === "session/prompt") {
          const promptId = message.params?._meta?.acpmux?.promptId;
          pending = { promptId, id: message.id };
          queueMicrotask(() => steps.queue(promptId));
          return;
        }
        const result = (() => {
          switch (message.method) {
            case "initialize":
              return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
            case "_acpmux/watch":
              return { sessions: [session] };
            case "_acpmux/attach":
              return { session, lastSeq: history.length, events: history, hasMore: false };
            case "_acpmux/events":
              return { events: [], hasMore: false, lastSeq: seq };
            default:
              return null;
          }
        })();
        queueMicrotask(() => reply(message.id, result));
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { make, finish: () => pending && steps.finish(pending.promptId, pending.id) };
}

const settle = async () => {
  for (let i = 0; i < 12; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

/// Sends the steer and returns every snapshot the pane published from then on.
async function sendSteer(then: Then, marked = true) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const host = daemon(then, marked);
  const seen: Snapshot[] = [];
  let recording = false;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => recording && seen.push({ rows: snapshot.rows, queue: snapshot.queue }),
    undefined,
    host.make,
  );
  await settle();
  recording = true;
  void client.send(STEER, [], "p-steer", undefined, undefined, true).catch(() => undefined);
  await settle();
  const queued = seen.at(-1)!;
  host.finish();
  await settle();
  client.close?.();
  return { seen, queued, last: seen.at(-1)! };
}

const bubbles = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.kind === "user" && row.text === STEER);

test("a steer acpmux holds until the turn shows keeps its bubble and never draws a queued row", async () => {
  const { seen, queued, last } = await sendSteer("steers");
  expect(seen.length).toBeGreaterThan(0);
  // Waiting for the turn to show: still the transcript's bubble, no queued row.
  expect(bubbles(queued)).toHaveLength(1);
  expect(queued.queue).toEqual([]);
  // In no snapshot did it pass through the queue.
  expect(seen.filter((snapshot) => snapshot.queue.some((entry) => entry.prompt === STEER))).toEqual([]);
  // Steered in: one bubble, as a steer sent a moment later lands.
  expect(bubbles(last)).toHaveLength(1);
  expect(last.queue).toEqual([]);
});

test("a steer a failed turn holds waits for the person as a queued row", async () => {
  const { queued, last } = await sendSteer("held");
  expect(queued.queue).toEqual([]);
  expect(last.queue.map((entry) => entry.prompt)).toEqual([STEER]);
  expect(bubbles(last)).toHaveLength(0);
});

test("a queued record without steerOnStart (an older acpmux) is still the queued row it was", async () => {
  const { queued } = await sendSteer("steers", false);
  expect(queued.queue.map((entry) => entry.prompt)).toEqual([STEER]);
  expect(bubbles(queued)).toHaveLength(0);
});

// A held steer acpmux then refuses never runs: its bubble, the only place it shows, fails with
// Retry instead of waiting as sent forever.
test("a held steer acpmux refuses fails in its bubble", async () => {
  const { last } = await sendSteer("refused");
  expect(last.queue).toEqual([]);
  expect(bubbles(last).map((row) => row.failed)).toEqual([true]);
});

// A held steer withdrawn (`queue_removed`) leaves no bubble that looks sent.
test("a held steer withdrawn leaves the transcript", async () => {
  const { queued, last } = await sendSteer("withdrawn");
  expect(bubbles(queued)).toHaveLength(1);
  expect(last.queue).toEqual([]);
  expect(bubbles(last)).toHaveLength(0);
});
