// Leo, 2026-11-12: his steer into a turn a background-task notice started drew AFTER the agent's
// answer to it, with the later turns under it too. The replayed log draws it right; this drives the
// LIVE path: the pane sends the steer itself, and its echo, steer_read and the turn end arrive live.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { AcpmuxRow } from "./model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

type Daemon = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
};
type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

const STEER = 'should this really be labelled as "cmux"?';
const NOTICE =
  "[notice from acpmux] Background command finished: post #41694 SHIP (exit 0)\nTask bg-7e: post\nLast 1 lines of its output:\nok\n(bg_output reads all of it.)";
const INBOX =
  "[inbox] New messages from other agents in 1 thread.\n- 1 new in #41780 from lane: Pushed. (thread from:lane/pr:41780)";
const ANSWER = "No, it shouldn't say cmux. The label should name the background task.";
const LATER = "Your top-four priority list got split.";
const person = { origin: { actor: "person", verified: true } };
const inboxMeta = (id: string) => ({
  provenance: {
    kind: "inbox_notice",
    noticeId: id,
    threads: [
      {
        threadId: "from:lane/pr:41780",
        label: "#41780",
        new: 1,
        from: ["lane"],
        promptIds: ["x"],
        blocker: false,
        preview: "Pushed.",
      },
    ],
  },
});

const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Variant = {
  /// When the pane's session/prompt RPC answers: before the echo, after it, after steer_read, at turn end, never.
  answer: "beforeEcho" | "afterEcho" | "afterRead" | "afterEnd" | "never";
  /// The echo's promptId: the pane's, or none (an older acpmux, a capped record).
  echoPromptId?: boolean;
  /// steer_read before or after the first tool call after the echo.
  readFirst?: boolean;
  /// The turn ends before the echo arrives.
  endBeforeEcho?: boolean;
  /// acpmux logs a `queued` record for the steer.
  queued?: boolean;
  /// The RPC answers with stopReason "steered".
  steered?: boolean;
  /// No echo arrives live at all (the pane's stream lost it).
  noEcho?: boolean;
  /// acpmux logs the echo but this pane's stream drops it (a slow client): the turn's re-read finds it.
  dropEcho?: boolean;
  /// The steer carries an image, as Leo's did.
  image?: boolean;
  /// The pane sends it as a plain prompt (it did not see the turn running); acpmux makes it a steer.
  plain?: boolean;
  /// A rebuild (reconnect / lag resync) mid-turn, after the steer was sent.
  rebuildMidTurn?: "beforeEcho" | "afterEcho";
};

async function drive(v: Variant) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { turnView, turnViewFrom } = await import("./conversation/turns");
  const folds = new Set<string>();
  let live: ReturnType<typeof turnViewFrom> | undefined;
  const rpc: { params?: any; resolve?: (value: unknown) => void } = {};
  let socket!: InstanceType<typeof MockAcpmuxSocket>;
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        rpc.params = params;
        return new Promise((resolve) => (rpc.resolve = resolve));
      };
    }
  }
  let rows: readonly AcpmuxRow[] = [];
  let shown: any;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot;
      rows = snapshot.rows;
      // As App.tsx draws it: each snapshot's turns built on the last one's.
      live = turnViewFrom(
        snapshot.rows,
        folds as never,
        {
          working: snapshot.isWorking,
          clockOffset: snapshot.clockOffsetMs,
          turnStartedAtMs: snapshot.turnStartedAtMs,
          agentFamily: "claude",
          waitingSteers: snapshot.waitingSteers,
        } as never,
        live,
      );
    },
    undefined,
    () => (socket = new Held()) as unknown as WebSocket,
  );
  const id = mockHost.sessionId!;
  const daemon = socket as unknown as Daemon;
  await settle(() => shown?.summary !== undefined);
  const mux = (kind: string, msg: unknown) => daemon.emit(id, { mux: kind, msg });
  const update = (sessionUpdate: string, rest: unknown) =>
    daemon.emit(id, { update: { sessionUpdate, ...(rest as object) } });
  const say = (text: string, messageId: string) =>
    update("agent_message_chunk", { messageId, content: { type: "text", text } });
  const call = (toolCallId: string, title: string) => {
    update("tool_call", { toolCallId, title, kind: "execute", status: "in_progress" });
    update("tool_call_update", { toolCallId, status: "completed" });
  };
  const has = (text: string) => rows.some((row) => (row.text ?? "").includes(text));
  const answerRpc = () => rpc.resolve?.({ stopReason: v.steered ? "steered" : "end_turn" });

  // t1: a background task's notice opens the turn.
  mux("queued", { text: NOTICE, promptId: "bg-done-1", client: "acpmux" });
  mux("dequeued", { promptId: "bg-done-1" });
  daemon.touch(id, { status: "running", turn: { turnId: "t1" } });
  mux("user_message", { text: NOTICE, promptId: "bg-done-1", client: "acpmux", turnId: "t1" });
  mux("turn_started", { promptId: "bg-done-1", turnId: "t1" });
  call("c1", "gh pr view 41694");
  say("Checking the post. ", "m0");
  await settle(() => has("Checking the post."));

  // The person steers from the pane.
  const image = {
    id: "image-1",
    kind: "image" as const,
    name: "shot.png",
    mimeType: "image/png",
    size: 12,
    data: "aGVsbG8=",
  };
  const sent = client.send(STEER, v.image ? [image] : [], "s1", undefined, undefined, !v.plain).catch(() => undefined);
  await settle(() => rpc.params !== undefined && (has(STEER) || (shown.queue ?? []).length > 0));
  if (v.queued) mux("queued", { text: STEER, promptId: "s1", client: "cmux-react-agent-pane#01a1ce" });
  if (v.answer === "beforeEcho") answerRpc();
  const rebuild = () => (client as unknown as { rebuild(): void }).rebuild();
  if (v.rebuildMidTurn === "beforeEcho") rebuild();
  const echo = () =>
    (v.dropEcho ? (step: unknown) => (socket as any).record(id, step) : (step: unknown) => daemon.emit(id, step))({
      mux: "user_message",
      msg: {
        text: STEER,
        ...(v.echoPromptId === false ? {} : { promptId: "s1" }),
        steer: true,
        turnId: "t1",
        client: "cmux-react-agent-pane#01a1ce",
        _meta: person,
        ...(v.image ? { images: [{ id: "image-1", mimeType: "image/png", name: "shot.png" }] } : {}),
      },
    });
  const end1 = () => {
    mux("turn_end", { turnId: "t1", stopReason: "end_turn" });
    mux("turn_result", { status: "completed", promptId: "bg-done-1", turnId: "t1" });
  };
  if (!v.endBeforeEcho && !v.noEcho) echo();
  if (v.answer === "afterEcho") answerRpc();
  if (v.rebuildMidTurn === "afterEcho") rebuild();
  if (v.readFirst) mux("steer_read", { promptId: "s1", turnId: "t1" });
  call("c2", "glaeda-gh status");
  if (!v.readFirst) mux("steer_read", { promptId: "s1", turnId: "t1" });
  if (v.answer === "afterRead") answerRpc();
  call("c3", "SendMessage");
  say(ANSWER, "m1");
  end1();
  if (v.endBeforeEcho) echo();
  if (v.answer === "afterEnd") answerRpc();

  // t2: an inbox notice opens the next turn, another arrives as a steer into it.
  mux("user_message", {
    text: INBOX,
    promptId: "inbox-1",
    client: "acpmux",
    turnId: "t2",
    _meta: inboxMeta("inbox-1"),
  });
  mux("turn_started", { promptId: "inbox-1", turnId: "t2" });
  call("c4", "SendMessage");
  say(LATER, "m2");
  mux("turn_end", { turnId: "t2" });
  mux("turn_result", { status: "completed", promptId: "inbox-1", turnId: "t2" });
  daemon.touch(id, { status: "idle", turn: undefined });
  await settle(() => has(LATER));
  // A dropped echo: the turn's re-read (checkFinishedTurn) brings it back.
  if (v.dropEcho) await settle(() => rows.some((row) => row.kind === "user" && row.promptId === "s1"));
  void sent;
  const drawn = turnView(rows, new Set(), { agentFamily: "claude" });
  client.close?.();
  return { rows, drawn, live: live!.rows };
}

const where = (list: readonly AcpmuxRow[], text: string) =>
  list.findIndex((row) => JSON.stringify(row).includes(JSON.stringify(text).slice(1, -1)));

const variants: Record<string, Variant> = {
  "rpc answers before the echo": { answer: "beforeEcho" },
  "rpc answers after the echo": { answer: "afterEcho" },
  "rpc answers after steer_read": { answer: "afterRead" },
  "rpc answers at the turn end": { answer: "afterEnd" },
  "rpc answers steered after steer_read": { answer: "afterRead", steered: true },
  "rpc never answers": { answer: "never" },
  "echo without promptId": { answer: "afterRead", echoPromptId: false },
  "steer_read before the first tool call": { answer: "afterRead", readFirst: true },
  "queued record for the steer": { answer: "afterRead", queued: true },
  "turn ends before the echo": { answer: "afterEnd", endBeforeEcho: true },
  "no echo live": { answer: "afterRead", noEcho: true },
  "echo dropped live, the turn's re-read finds it": { answer: "afterRead", dropEcho: true },
  "echo dropped live, rpc never answers": { answer: "never", dropEcho: true },
  "with an image": { answer: "afterRead", image: true },
  "sent as a plain prompt, acpmux steers it": { answer: "afterRead", plain: true },
  "sent as a plain prompt, rpc answers at the end": { answer: "afterEnd", plain: true },
  "rebuild mid-turn before the echo": { answer: "afterRead", rebuildMidTurn: "beforeEcho" },
  "rebuild mid-turn after the echo": { answer: "afterRead", rebuildMidTurn: "afterEcho" },
};

for (const [name, variant] of Object.entries(variants))
  test(`a steer sent live into a notice-started turn draws above its answer: ${name}`, async () => {
    const { rows, drawn, live } = await drive(variant);
    const order = (list: readonly AcpmuxRow[]) => ({
      notice: where(list, "Background command finished"),
      steer: where(list, STEER),
      answer: where(list, ANSWER),
      inbox: where(list, "#41780"),
      later: where(list, LATER),
    });
    const r = order(rows);
    const d = order(drawn);
    const l = order(live);
    const dump = (list: readonly AcpmuxRow[]) =>
      list
        .map((row) => `${row.kind} ${row.id} ${JSON.stringify((row.text ?? "").slice(0, 40))} ${row.steer ?? ""}`)
        .join("\n");
    const ok = (o: typeof r) =>
      o.steer >= 0 && o.notice < o.steer && o.steer < o.answer && o.answer < o.later && o.steer < o.inbox;
    if (!ok(r) || !ok(d) || JSON.stringify(l) !== JSON.stringify(d))
      console.log(`--rows\n${dump(rows)}\n--drawn\n${dump(drawn)}\n--live\n${dump(live)}`);
    expect(r.steer).toBeGreaterThan(r.notice);
    expect(r.steer).toBeLessThan(r.answer);
    expect(r.steer).toBeLessThan(r.inbox);
    expect(d.steer).toBeGreaterThanOrEqual(0);
    expect(d.steer).toBeLessThan(d.later);
    expect(d.steer).toBeLessThan(d.inbox);
    // The pane's incremental view draws what a fresh one does.
    expect(l).toEqual(d);
  });

// The class: random combinations of when the pane's prompt call answers, whether the echo comes
// before or after the turn's end, where steer_read falls, a queued record, an image and a rebuild.
// The steer always draws inside its turn, above the answer and the next turn.
function pick(seed: number) {
  let state = seed >>> 0;
  return <T>(options: readonly T[]): T => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return options[state % options.length]!;
  };
}
const answers = ["beforeEcho", "afterEcho", "afterRead", "afterEnd", "never"] as const;
for (let seed = 1; seed <= 24; seed += 1) {
  const one = pick(seed);
  const endBeforeEcho = one([true, false]);
  const variant: Variant = {
    answer: one(answers),
    endBeforeEcho,
    readFirst: one([true, false]),
    queued: one([true, false]),
    image: one([true, false]),
    // A rebuild before an echo that comes after the turn's end is the other way a steer was placed last.
    rebuildMidTurn: one([undefined, "beforeEcho", ...(endBeforeEcho ? [] : (["afterEcho"] as const))]),
  };
  test(`a steer draws inside its turn for any live order (seed ${seed})`, async () => {
    const { rows, drawn, live } = await drive(variant);
    const steer = where(drawn, STEER);
    expect(where(rows, STEER), JSON.stringify(variant)).toBeLessThan(where(rows, ANSWER));
    expect(steer, JSON.stringify(variant)).toBeGreaterThanOrEqual(0);
    expect(steer, JSON.stringify(variant)).toBeLessThan(where(drawn, LATER));
    expect(steer, JSON.stringify(variant)).toBeLessThan(where(drawn, "#41780"));
    expect(where(live, STEER)).toBe(steer);
  });
}
