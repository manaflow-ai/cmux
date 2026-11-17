// A message the person sent as a steer into a turn that ended without reading it is carried into
// the next turn (acpmux `turn_started.carried.promptIds`). It draws where that turn starts, never
// above the ended turn's reply, which answered something else (Leo, 2026-11-12, on a "No change."
// to a background notice drawn under his "hm? what happened here").
// l10n-allow-file: synthetic prompts and replies used by a behavioral regression.
import { afterAll, beforeAll, expect, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = { id: string; kind: string; text?: string; steer?: string; turnId?: string };

test("a steer the turn never read draws after that turn's reply, opening the turn it was carried to", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    // A background notice opens a turn of its own.
    { mux: "user_message", msg: { text: "[notice from acpmux] Background command finished", promptId: "p-notice" } },
    { mux: "turn_started", msg: { promptId: "p-notice", turnId: "t-notice" } },
    // The person writes while it runs: a steer into that turn.
    {
      mux: "user_message",
      msg: { text: "hm? what happened here", promptId: "p-person", steer: true, turnId: "t-notice" },
    },
    // The notice turn's reply, which never read the steer.
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-1",
        content: { type: "text", text: "No change." },
      },
    },
    { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-notice" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-notice" } },
    // acpmux carries the unread steer into the next turn.
    {
      mux: "turn_started",
      msg: { promptId: "p-person", turnId: "t-person", carried: { fromTurnId: "t-notice", promptIds: ["p-person"] } },
    },
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-2",
        content: { type: "text", text: "Here is what happened." },
      },
    },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-person" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const drawn = () => rows.filter((row) => row.kind === "user" || row.kind === "assistant");
    while (!drawn().some((row) => row.text?.includes("Here is what happened")))
      await new Promise<void>((resolve) => wakes.push(resolve));
    const order = drawn().map((row) => row.text ?? "");
    const person = order.findIndex((text) => text === "hm? what happened here");
    const noChange = order.findIndex((text) => text === "No change.");
    const answer = order.findIndex((text) => text === "Here is what happened.");
    expect(person).toBeGreaterThan(-1);
    expect(noChange).toBeGreaterThan(-1);
    // The ended turn's reply comes first; the carried message opens the turn that answers it.
    expect(noChange).toBeLessThan(person);
    expect(person).toBeLessThan(answer);
    const row = drawn()[person]!;
    expect(row.steer).toBeUndefined();
    expect(row.turnId).toBe("t-person");
  } finally {
    client.close?.();
  }
});

test("a steer the turn read stays where it was sent", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    { mux: "user_message", msg: { text: "Fix the build", promptId: "p-1" } },
    { mux: "turn_started", msg: { promptId: "p-1", turnId: "t-1" } },
    { mux: "user_message", msg: { text: "Use the cache too", promptId: "p-2", steer: true, turnId: "t-1" } },
    { mux: "steer_read", msg: { promptId: "p-2" } },
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-1",
        content: { type: "text", text: "Done, cached." },
      },
    },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-1" } },
    { mux: "turn_started", msg: { promptId: "p-3", turnId: "t-2" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-2" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const drawn = () => rows.filter((row) => row.kind === "user" || row.kind === "assistant");
    while (!drawn().some((row) => row.text === "Done, cached."))
      await new Promise<void>((resolve) => wakes.push(resolve));
    const order = drawn().map((row) => row.text ?? "");
    expect(order.indexOf("Use the cache too")).toBeLessThan(order.indexOf("Done, cached."));
    expect(drawn().find((row) => row.text === "Use the cache too")?.turnId).toBe("t-1");
  } finally {
    client.close?.();
  }
});

test("a steer read mid-turn keeps its place in the turn, before the reply after it, with the real event shape", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  const { turnView } = await import("./conversation/turns");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const tool = (id: string, title: string) => [
    {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: id,
        title,
        kind: "execute",
        status: "in_progress",
        _meta: { claude: { tool: "Bash" } },
      },
    },
    { update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" } },
  ];
  const notice = (promptId: string, title: string) => ({
    mux: "user_message",
    msg: {
      text: `[notice from acpmux] ${title}\nTask bg-1: make\nLast 1 lines of its output:\nok`,
      promptId,
      _meta: {
        provenance: {
          kind: "notice",
          from: "fromAgent",
          fromName: "acpmux",
          to: "s",
          notice: { sender: "acpmux", severity: "info", title },
        },
      },
    },
  });
  const steps = [
    notice("p-notice", "Background command finished: make (exit 0)"),
    { mux: "turn_started", msg: { promptId: "p-notice", turnId: "t-1" } },
    ...tool("c1", "git status"),
    {
      mux: "user_message",
      msg: { text: 'should this really be labelled as "cmux"?', promptId: "p-person", steer: true, turnId: "t-1" },
    },
    { mux: "steer_read", msg: { promptId: "p-person", turnId: "t-1" } },
    ...tool("c2", "send a note"),
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-1",
        content: { type: "text", text: "No, the chip will name the source." },
      },
    },
    { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-1" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-1" } },
    notice("p-next", "Background command finished: ls (exit 0)"),
    { mux: "turn_started", msg: { promptId: "p-next", turnId: "t-2" } },
    {
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m-2",
        content: { type: "text", text: "Your priorities are unchanged." },
      },
    },
    { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-2" } },
    { mux: "turn_result", msg: { status: "completed", turnId: "t-2" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!rows.some((row) => row.text === "Your priorities are unchanged."))
      await new Promise<void>((resolve) => wakes.push(resolve));
    const steerRow = rows.find((row) => row.text?.startsWith("should this"))!;
    const view = turnView(rows as never, new Set()).map((entry) => entry.id);
    const answer = rows.find((row) => row.text === "No, the chip will name the source.")!;
    const next = rows.find((row) => row.text === "Your priorities are unchanged.")!;
    expect(steerRow.steer).toBe("landed");
    expect(steerRow.turnId).toBe("t-1");
    expect(view.indexOf(steerRow.id)).toBeGreaterThan(-1);
    expect(view.indexOf(steerRow.id)).toBeLessThan(view.indexOf(answer.id));
    expect(view.indexOf(answer.id)).toBeLessThan(view.indexOf(next.id));
  } finally {
    client.close?.();
  }
});

test("a steer the person sends from the pane and the agent reads mid-turn stays above the reply, live", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  const { turnView } = await import("./conversation/turns");
  forgetTail(mockHost.sessionId!);
  const id = mockHost.sessionId!;
  type Live = {
    emit: (target: string, step: unknown) => void;
    touch: (target: string, fields: Record<string, unknown>) => void;
  };
  let live: Live | undefined;
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      live = this as unknown as Live;
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        // acpmux's steer into the running turn: its user_message, marked a steer, and no turn of its own.
        if (method === "session/prompt" && params._meta?.acpmux?.steer === true) {
          const text = (params.prompt as { type: string; text?: string }[]).map((block) => block.text ?? "").join("");
          live!.emit(id, {
            mux: "user_message",
            msg: { text, promptId: params._meta.acpmux.promptId, steer: true, turnId: "t-1" },
          });
          return Promise.resolve({});
        }
        return answer(method, params);
      };
    }
  }
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  const text = (messageId: string, words: string) => ({
    update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text: words } },
  });
  const tool = (callId: string, title: string) => [
    { update: { sessionUpdate: "tool_call", toolCallId: callId, title, kind: "execute", status: "in_progress" } },
    { update: { sessionUpdate: "tool_call_update", toolCallId: callId, status: "completed" } },
  ];
  try {
    await until(() => live !== undefined);
    live!.touch(id, { status: "running" });
    live!.emit(id, {
      mux: "user_message",
      msg: { text: "[notice from acpmux] Background command finished: make (exit 0)", promptId: "p-notice" },
    });
    live!.emit(id, { mux: "turn_started", msg: { promptId: "p-notice", turnId: "t-1" } });
    for (const step of tool("c1", "git status")) live!.emit(id, step);
    void client.send(`should this really be labelled as "cmux"?`, [], "p-person", undefined, "ticket-p-person", true);
    await until(() => rows.some((row) => row.text?.startsWith("should this") && row.steer === "waiting"));
    live!.emit(id, { mux: "steer_read", msg: { promptId: "p-person", turnId: "t-1" } });
    for (const step of tool("c2", "send a note")) live!.emit(id, step);
    live!.emit(id, text("m-1", "No, the chip will name the source."));
    live!.emit(id, { mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-1" } });
    live!.emit(id, { mux: "turn_result", msg: { status: "completed", turnId: "t-1" } });
    live!.emit(id, {
      mux: "user_message",
      msg: { text: "[notice from acpmux] Background command finished: ls (exit 0)", promptId: "p-next" },
    });
    live!.emit(id, { mux: "turn_started", msg: { promptId: "p-next", turnId: "t-2" } });
    live!.emit(id, text("m-2", "Your priorities are unchanged."));
    live!.emit(id, { mux: "turn_result", msg: { status: "completed", turnId: "t-2" } });
    live!.touch(id, { status: "ready" });
    await until(() => rows.some((row) => row.text === "Your priorities are unchanged."));
    const view = turnView(rows as never, new Set()).map((entry) => entry.id);
    const steerRow = rows.find((row) => row.text?.startsWith("should this"))!;
    const answer = rows.find((row) => row.text === "No, the chip will name the source.")!;
    const next = rows.find((row) => row.text === "Your priorities are unchanged.")!;
    expect(steerRow.steer).toBe("landed");
    expect(view.indexOf(steerRow.id)).toBeGreaterThan(-1);
    expect(view.indexOf(steerRow.id)).toBeLessThan(view.indexOf(answer.id));
    expect(view.indexOf(answer.id)).toBeLessThan(view.indexOf(next.id));
  } finally {
    client.close?.();
  }
});

// Leo, 2026-11-17: "and the message you sent after my steer... shot up. instead of landing after my
// steer prompt". A reply that was streaming when the person steered keeps its words above the
// steer, but once the agent reads the steer (`steer_read`) what it writes next answers it and draws
// below, even when its chunks carry no message id (or the same one) to say a new message began.
async function liveSteer() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  const { turnView } = await import("./conversation/turns");
  forgetTail(mockHost.sessionId!);
  const id = mockHost.sessionId!;
  type Live = {
    emit: (target: string, step: unknown) => void;
    touch: (target: string, fields: Record<string, unknown>) => void;
  };
  let live: Live | undefined;
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      live = this as unknown as Live;
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt" && params._meta?.acpmux?.steer === true) {
          const text = (params.prompt as { type: string; text?: string }[]).map((block) => block.text ?? "").join("");
          live!.emit(id, {
            mux: "user_message",
            msg: { text, promptId: params._meta.acpmux.promptId, steer: true, turnId: "t-1" },
          });
          return Promise.resolve({});
        }
        return answer(method, params);
      };
    }
  }
  let rows: Row[] = [];
  const wakes: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  await until(() => live !== undefined);
  live!.touch(id, { status: "running" });
  const emit = (step: unknown) => live!.emit(id, step);
  const say = (words: string, messageId?: string) =>
    emit({
      update: {
        sessionUpdate: "agent_message_chunk",
        ...(messageId && { messageId }),
        content: { type: "text", text: words },
      },
    });
  const steer = async (words: string, promptId: string) => {
    void client.send(words, [], promptId, undefined, `ticket-${promptId}`, true);
    await until(() => rows.some((row) => row.text === words && row.steer === "waiting"));
  };
  const finish = async () => {
    emit({ mux: "turn_end", msg: { stopReason: "end_turn", turnId: "t-1" } });
    emit({ mux: "turn_result", msg: { status: "completed", turnId: "t-1" } });
    live!.touch(id, { status: "ready" });
    await until(() => rows.some((row) => row.kind === "turnSummary"));
  };
  const view = (open: string[] = []) => turnView(rows as never, new Set(open)).map((entry) => entry.id);
  return { client, emit, say, steer, finish, view, rows: () => rows, until };
}

for (const [name, messageIds] of [
  ["without message ids", [undefined, undefined]],
  ["under the message id the reply had", ["m-1", "m-1"]],
] as const)
  test(`a reply the agent writes after it read a steer draws below the steer, ${name}`, async () => {
    const live = await liveSteer();
    try {
      live.emit({ mux: "user_message", msg: { text: "Fix the list", promptId: "p-1" } });
      live.emit({ mux: "turn_started", msg: { promptId: "p-1", turnId: "t-1" } });
      live.say("Looking at the list now", messageIds[0]);
      await live.until(() => live.rows().some((row) => row.text === "Looking at the list now"));
      await live.steer("and the flicker?", "p-steer");
      // The reply that was streaming at the steer finishes in its row, above the steer.
      live.say(".", messageIds[0]);
      live.emit({ mux: "steer_read", msg: { promptId: "p-steer", turnId: "t-1" } });
      live.say("On the flicker: it comes from the remount.", messageIds[1]);
      await live.until(() => live.rows().some((row) => row.text?.includes("On the flicker")));
      const check = () => {
        const rows = live.rows();
        const pre = rows.find((row) => row.text?.startsWith("Looking at the list now"))!;
        const steered = rows.find((row) => row.text === "and the flicker?")!;
        const reply = rows.find((row) => row.text?.includes("On the flicker"))!;
        const order = live.view();
        expect(reply.id).not.toBe(pre.id);
        expect(pre.text).toBe("Looking at the list now.");
        expect(reply.text).toBe("On the flicker: it comes from the remount.");
        expect(steered.steer).toBe("landed");
        expect(order.indexOf(pre.id)).toBeGreaterThan(-1);
        expect(order.indexOf(pre.id)).toBeLessThan(order.indexOf(steered.id));
        expect(order.indexOf(steered.id)).toBeLessThan(order.indexOf(reply.id));
      };
      check();
      // The order stays once the turn ends.
      await live.finish();
      check();
    } finally {
      live.client.close?.();
    }
  });

test("a call still running at a steer stays below the steer once the turn ends, in its opened Worked for", async () => {
  const live = await liveSteer();
  try {
    live.emit({ mux: "user_message", msg: { text: "Fix the list", promptId: "p-1" } });
    live.emit({ mux: "turn_started", msg: { promptId: "p-1", turnId: "t-1" } });
    live.emit({
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "c1",
        title: "bun test",
        kind: "execute",
        status: "in_progress",
      },
    });
    await live.until(() => live.rows().some((row) => row.kind === "activity"));
    await live.steer("and the flicker?", "p-steer");
    // The call ends after the steer went: the clock moves on a second (no fixed wait).
    setSystemTime(new Date(Date.now() + 1000));
    live.emit({ mux: "steer_read", msg: { promptId: "p-steer", turnId: "t-1" } });
    live.emit({ update: { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed" } });
    live.say("On the flicker.");
    await live.finish();
    const prompt = live.rows().find((row) => row.text === "Fix the list")!;
    const steered = live.rows().find((row) => row.text === "and the flicker?")!;
    const order = live.view([`worked-${prompt.id}`]);
    const call = order.reduce((last, id, at) => (id.startsWith("activity-") ? at : last), -1);
    expect(call).toBeGreaterThan(-1);
    expect(order.indexOf(steered.id)).toBeGreaterThan(-1);
    expect(order.indexOf(steered.id)).toBeLessThan(call);
  } finally {
    setSystemTime();
    live.client.close?.();
  }
});
