// l10n-allow-file: test fixture prompts, not shipped UI.
// A chat on a Cloud machine sends each prompt that starts a turn under the hand-off turn the app
// opened for it (`handoff-<turn>-<id>`, cloudHandoffTurn.ts), so acpmux on the machine reports that
// turn (cmux-tui acpmux daemon/cloud_handoff.rs). A steer into a running turn, a prompt that already
// names a turn (a Retry) and a page with no hand-off ask go under their own id, and nothing is asked
// for them.
import { expect, setSystemTime, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e1";
const START = Date.UTC(2026, 9, 28, 10, 0, 0);

/// A daemon with one idle chat that records every prompt it gets.
function fakeDaemon(prompts: Record<string, unknown>[], refuse = 0, refusal?: string) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/cmux/work/paint-33f597",
    title: "paint",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: Record<string, unknown>) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        prompts.push(params);
        // A steer went into a turn already running on the machine (one the page had not seen).
        return {
          stopReason: (params._meta as { acpmux?: { steer?: boolean } } | undefined)?.acpmux?.steer
            ? "steered"
            : "end_turn",
        };
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
        if (message.method === "session/prompt" && refuse > 0) {
          refuse -= 1;
          prompts.push(message.params);
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                error: refusal
                  ? { code: -32000, message: refusal, data: { code: refusal, origin: "native" } }
                  : { code: -32603, message: "refused" },
              }),
            }),
          );
          return;
        }
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

async function client(prompts: Record<string, unknown>[], refuse = 0, refusal?: string) {
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => undefined,
    undefined,
    fakeDaemon(prompts, refuse, refusal),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return connected;
}

const promptIdOf = (params: Record<string, unknown> | undefined) =>
  (params?._meta as { acpmux?: { promptId?: string } } | undefined)?.acpmux?.promptId;

test("a prompt that starts a turn goes under the hand-off turn the app opened, for this chat", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  const asked: string[] = [];
  chat.handoffTurn = async (sessionId) => (asked.push(sessionId), 3);
  await chat.send("fix the build", [], "p-1");
  expect(asked).toEqual([CHAT]);
  expect(promptIdOf(prompts[0])).toBe("handoff-3-p-1");
});

test("no turn from the app: the prompt goes under its own id", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  chat.handoffTurn = async () => undefined;
  await chat.send("fix the build", [], "p-2");
  expect(promptIdOf(prompts[0])).toBe("p-2");
});

test("a page with no hand-off ask and a Retry's id that names a turn ask nothing", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  await chat.send("plain", [], "p-3");
  let asks = 0;
  chat.handoffTurn = async () => (asks++, 9);
  await chat.send("again", [], "handoff-2-p-5");
  expect(asks).toBe(0);
  expect(prompts.map(promptIdOf)).toEqual(["p-3", "handoff-2-p-5"]);
});

// The composer sends Return as a steer to an agent that steers even while the chat shows no turn
// (Composer.tsx `steersUnseen`). With none running that steer starts a turn, so it asks like any.
test("a steer while the chat shows no turn goes under the hand-off turn", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  chat.handoffTurn = async () => 6;
  await chat.send("steer it", [], "p-4", undefined, undefined, true);
  expect(promptIdOf(prompts[0])).toBe("handoff-6-p-4");
});

test("an id that only starts with the prefix names no turn: its send asks for one", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  let turn = 4;
  chat.handoffTurn = async () => turn++;
  await chat.send("note", [], "handoff-note");
  await chat.send("zero", [], "handoff-0-p-6");
  expect(prompts.map(promptIdOf)).toEqual(["handoff-4-handoff-note", "handoff-5-handoff-0-p-6"]);
});

test("a send while the chat's ask is out asks nothing, goes behind it and under its own id", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  let asks = 0;
  let answer: (turn: number) => void = () => undefined;
  chat.handoffTurn = () => (asks++, new Promise<number>((resolve) => (answer = resolve)));
  const first = chat.send("first", [], "p-7");
  const second = chat.send("second", [], "p-8");
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(asks).toBe(1);
  expect(prompts).toEqual([]);
  answer(5);
  await Promise.all([first, second]);
  expect(prompts.map(promptIdOf)).toEqual(["handoff-5-p-7", "p-8"]);
});

test("the chat changing while the ask is out hands the prompt back: nothing is sent or drawn", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  let answer: (turn: number) => void = () => undefined;
  chat.handoffTurn = () => new Promise<number>((resolve) => (answer = resolve));
  const sent = chat.send("moved", [], "p-9", () => undefined);
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  (chat as unknown as { selectionGeneration: number }).selectionGeneration += 1;
  answer(6);
  await expect(sent).rejects.toThrow();
  expect(prompts).toEqual([]);
  expect((chat as unknown as { rows: Map<string, unknown> }).rows.has("local-p-9")).toBe(false);
});

test("an ask from before the chat was shown again is not waited on: the new send asks again", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  const answers: ((turn: number) => void)[] = [];
  chat.handoffTurn = () => new Promise<number>((resolve) => answers.push(resolve));
  const first = chat.send("first", [], "p-10", () => undefined);
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  (chat as unknown as { selectionGeneration: number }).selectionGeneration += 1;
  const second = chat.send("second", [], "p-11");
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(answers).toHaveLength(2);
  answers[0]?.(7);
  answers[1]?.(7);
  await expect(first).rejects.toThrow();
  await second;
  expect(prompts.map(promptIdOf)).toEqual(["handoff-7-p-11"]);
});

test("a Retry goes under the id its prompt first went with, even when a turn is open now", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts, 1);
  chat.handoffTurn = async () => undefined;
  await chat.send("first", [], "p-12").catch(() => undefined);
  chat.handoffTurn = async () => 8;
  await chat.retryPrompt("local-p-12").catch(() => undefined);
  expect(prompts.map(promptIdOf)).toEqual(["p-12", "p-12"]);
});

test("a turn this page already sent a prompt under is never named for another prompt", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  // The store still says turn 2 is starting: the machine's reports of the first prompt are on their way.
  chat.handoffTurn = async () => 2;
  await chat.send("first", [], "p-13");
  await chat.send("second", [], "p-14");
  chat.handoffTurn = async () => 3;
  await chat.send("third", [], "p-15");
  expect(prompts.map(promptIdOf)).toEqual(["handoff-2-p-13", "p-14", "handoff-3-p-15"]);
});

test("a prompt refused before acpmux took it, back in the composer, frees its turn for the next Send", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts, 1, "transport.gesture_required");
  chat.handoffTurn = async () => 4;
  await chat.send("first", [], "p-16", () => undefined).catch(() => undefined);
  await chat.send("first", [], "p-17", () => undefined);
  expect(prompts.map(promptIdOf)).toEqual(["handoff-4-p-16", "handoff-4-p-17"]);
});

// That steer can go into a turn already running on the machine, which the page had not seen: it
// starts no turn, so the hand-off turn it claimed is the next prompt's (review follow-up F1).
test("a steer that went into a running turn leaves its hand-off turn to the next prompt", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  chat.handoffTurn = async () => 6;
  await chat.send("steer it", [], "p-7", undefined, undefined, true);
  await chat.send("next", [], "p-8");
  expect(prompts.map(promptIdOf)).toEqual(["handoff-6-p-7", "handoff-6-p-8"]);
});

// A chat on a Cloud machine starts with its first send. Its hand-off turn was asked only after the
// page had attached to the new chat (0.7 to 1.6 s of a start, then the ask's own 1.5 to 1.9 s,
// 2026-11-21): the ask now goes out as soon as the session is known, beside the attach, and the
// send that started the chat takes it.

/// A Cloud machine's acpmux (`origin: "remote"`) with no chat yet: `session/new` makes one, and
/// `wire` records the order of what the page did (the app's hand-off ask included).
async function cloudStart(options: { attachHeld?: Promise<void> } = {}) {
  let socket: any;
  let session: any;
  const wire: string[] = [];
  const prompts: Record<string, unknown>[] = [];
  const other = { sessionId: "other-chat", harness: "claude", status: "ready", turnCount: 3 };
  const answer = async (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "remote", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: session ? [session, other] : [other] };
      case "session/new":
        wire.push("session/new");
        session = { sessionId: "cloud-1", harness: "claude", status: "ready", turnCount: 0 };
        return { sessionId: session.sessionId };
      case "_acpmux/attach":
        wire.push(`attach ${params.sessionId}`);
        if (params.sessionId === "cloud-1") await options.attachHeld;
        wire.push(`attached ${params.sessionId}`);
        return { session: params.sessionId === other.sessionId ? other : session, events: [], lastSeq: 0 };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        wire.push("session/prompt");
        prompts.push(params);
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  };
  const chat = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", newSession: true },
    () => undefined,
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id === undefined) return;
          void answer(message.method, message.params).then((result) =>
            socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }),
          );
        },
        close() {},
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return { chat, wire, prompts };
}

test("a Cloud chat's first send asks its hand-off turn once, before the page has attached to the new chat", async () => {
  let attach!: () => void;
  const run = await cloudStart({ attachHeld: new Promise<void>((resolve) => (attach = resolve)) });
  try {
    expect(run.chat.startsOnSend).toBe(true);
    run.chat.handoffTurn = async (sessionId) => (run.wire.push(`ask ${sessionId}`), 1);
    const sent = run.chat.send("fix the build", [], "p-1");
    for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
    // The ask is out while the attach still waits: it does not come after it.
    expect(run.wire).toEqual(["session/new", "ask cloud-1", "attach cloud-1"]);
    attach();
    await sent;
    expect(run.wire.filter((step) => step.startsWith("ask "))).toEqual(["ask cloud-1"]);
    expect(run.wire.at(-1)).toBe("session/prompt");
    expect(promptIdOf(run.prompts[0])).toBe("handoff-1-p-1");
    // The chat's next prompt asks for itself: the ask made at the start was the first send's.
    run.chat.handoffTurn = async (sessionId) => (run.wire.push(`ask ${sessionId}`), 2);
    await run.chat.send("and the tests", [], "p-2");
    expect(run.wire.filter((step) => step.startsWith("ask "))).toEqual(["ask cloud-1", "ask cloud-1"]);
    expect(promptIdOf(run.prompts[1])).toBe("handoff-2-p-2");
  } finally {
    run.chat.close();
  }
});

test("an ask made at the start that names no turn is asked again by the send, after the attach", async () => {
  const run = await cloudStart();
  try {
    const turns = [undefined, 2];
    let asks = 0;
    run.chat.handoffTurn = async (sessionId) => (run.wire.push(`ask ${sessionId}`), turns[asks++]);
    await run.chat.send("fix the build", [], "p-1");
    expect(run.wire).toEqual([
      "session/new",
      "ask cloud-1",
      "attach cloud-1",
      "attached cloud-1",
      "ask cloud-1",
      "session/prompt",
    ]);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-2-p-1");
  } finally {
    run.chat.close();
  }
});

test("no turn from either ask: the first prompt goes under its own id", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = async () => ((asks += 1), undefined);
    await run.chat.send("fix the build", [], "p-1");
    expect(asks).toBe(2);
    expect(promptIdOf(run.prompts[0])).toBe("p-1");
  } finally {
    run.chat.close();
  }
});

test("an ask at the start that fails is asked again by the send, which goes on as its own ask does", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = () =>
      (asks += 1) === 1 ? Promise.reject(new Error("the app is gone")) : Promise.resolve(3);
    await run.chat.send("fix the build", [], "p-1");
    expect(asks).toBe(2);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-3-p-1");
  } finally {
    run.chat.close();
  }
});

test("an ask at the start that ran out its wait is not asked again: the app is not waited on twice", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = async () => {
      asks += 1;
      setSystemTime(new Date(Date.now() + 2_500));
      return undefined;
    };
    await run.chat.send("fix the build", [], "p-1");
    expect(asks).toBe(1);
    expect(promptIdOf(run.prompts[0])).toBe("p-1");
  } finally {
    setSystemTime();
    run.chat.close();
  }
});

test("two sends while the chat starts: the first takes the ask made at the start, the second goes under its own id", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = async () => ((asks += 1), 1);
    await Promise.all([run.chat.send("fix the build", [], "p-1"), run.chat.send("and the tests", [], "p-2")]);
    expect(asks).toBe(1);
    expect(new Set(run.prompts.map(promptIdOf))).toEqual(new Set(["handoff-1-p-1", "p-2"]));
  } finally {
    run.chat.close();
  }
});

test("a page with no hand-off ask starts a Cloud chat as before", async () => {
  const run = await cloudStart();
  try {
    await run.chat.send("fix the build", [], "p-1");
    expect(run.wire).toEqual(["session/new", "attach cloud-1", "attached cloud-1", "session/prompt"]);
    expect(promptIdOf(run.prompts[0])).toBe("p-1");
  } finally {
    run.chat.close();
  }
});

test("the send's own start (ensureSession, then send, as the page's Send does) uses the one ask", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = async () => ((asks += 1), 4);
    expect(await run.chat.ensureSession()).toBe("cloud-1");
    expect(asks).toBe(1);
    await run.chat.send("fix the build", [], "p-1");
    expect(asks).toBe(1);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-4-p-1");
  } finally {
    run.chat.close();
  }
});

test("an ask whose send never came is not used by a much later one: that send asks again", async () => {
  const run = await cloudStart();
  try {
    const turns = [4, 5];
    let asks = 0;
    run.chat.handoffTurn = async () => turns[asks++];
    expect(await run.chat.ensureSession()).toBe("cloud-1");
    setSystemTime(new Date(Date.now() + 60_000));
    await run.chat.send("fix the build", [], "p-1");
    expect(asks).toBe(2);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-5-p-1");
  } finally {
    setSystemTime();
    run.chat.close();
  }
});

test("a chat started by no send (New Tab's start) asks nothing ahead: its first send asks for itself", async () => {
  const run = await cloudStart();
  try {
    let asks = 0;
    run.chat.handoffTurn = async (sessionId) => (run.wire.push(`ask ${sessionId}`), (asks += 1), 7);
    expect(await run.chat.create()).toBe("cloud-1");
    expect(asks).toBe(0);
    await run.chat.send("fix the build", [], "p-1");
    expect(run.wire).toEqual(["session/new", "attach cloud-1", "attached cloud-1", "ask cloud-1", "session/prompt"]);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-7-p-1");
  } finally {
    run.chat.close();
  }
});

test("an ask made at the start is not used once another chat was shown: the send asks again", async () => {
  const run = await cloudStart();
  try {
    const turns = [5, 6];
    let asks = 0;
    run.chat.handoffTurn = async () => turns[asks++];
    expect(await run.chat.ensureSession()).toBe("cloud-1");
    await run.chat.select("other-chat");
    await run.chat.select("cloud-1");
    await run.chat.send("fix the build", [], "p-1");
    // The app names the turn that first ask opened again (a turn not run yet), here as the second answer.
    expect(asks).toBe(2);
    expect(promptIdOf(run.prompts[0])).toBe("handoff-6-p-1");
  } finally {
    run.chat.close();
  }
});
