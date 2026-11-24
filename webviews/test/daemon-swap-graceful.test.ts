// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A daemon swap is invisible in the chat (Leo, 2026-11-22: "we need to have far more graceful reloads
// that appear to just be instantly gracefully transitioned. my composer is ideally untouched as much
// as possible. likewise with my drafts. ... no shift, no anything, just... ok now it changed." and
// "likewise with daemon stuff").
//
// The old acpmux closes the pane's socket (1012, or 1006 for a crash) and a new one answers a moment
// later with the same chats and the same records. The pane goes the way App.tsx does: the lost client
// hands its chat on (`takeCarried`), a fresh client connects with it after the App's retry waits
// (`lostRetryDelay`, `jitteredDelay`), and a prompt the old connection lost goes again on the new one
// once (the host's prompt journal), held meanwhile as its own row (lostPrompt.ts `keepLostPrompt`).
//
// Every snapshot either client draws across the swap is read, as the pane draws each one:
// - the reply that was streaming: no frame with fewer of its words than an earlier one, none with a
//   word twice, and at the end every word once, in order;
// - the pending permission ask: on its card in every frame (App.tsx `individualPermission`);
// - a prompt sent just before the drop: delivered to the new daemon once, one row in every frame.
// The summary (DAEMON_SWAP_SUMMARY on stdout, or the file CMUX_DAEMON_SWAP_OUT names) carries the
// fields scripts/measure/graceful-swap.py reads. Composer value, caret and focus and layout px need a
// real engine: agent-pane-inbound-keeps-caret.test.ts measures them there (browser lane).
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";
import type { AcpmuxDirectClient as DirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

setDefaultTimeout(30_000);
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const SESSION = "0190a000-0000-7000-8000-00000000swap";
const START = Date.UTC(2026, 10, 22, 9, 0, 0);
/// How long the new daemon takes to answer after the old one closed (Leo: 0.5-3 s).
const SWAP_GAP_MS = 900;
const STREAM_MS = 15;
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: any };
type Message = { id?: number | string; method: string; params?: Record<string, any> };

const chunk = (text: string, messageId: string) => ({
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: {
      sessionId: SESSION,
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
    },
  },
});
const mux = (kind: string, msg: Record<string, unknown> = {}) => ({ dir: "mux", kind, msg });

/// One acpmux store, which the old and the new daemon serve alike: the swap keeps every record.
class Store {
  events: Rec[] = [];
  up = true;
  status = "running";
  sockets = new Set<Daemon>();
  /// Every `session/prompt` a daemon received, by promptId.
  prompts = new Map<string, number>();
  /// The old daemon goes before it answers a prompt (the swap lands right after the send).
  swallowPrompts = false;
  attaches = 0;
  add(step: { dir: string; kind: string; msg: any }): Rec {
    const seq = this.events.length + 1;
    const record = { sessionId: SESSION, seq, at: START + seq * 100, ...step };
    this.events.push(record);
    if (record.kind === "turn_result") this.status = "idle";
    if (record.kind === "turn_started") this.status = "running";
    return record;
  }
  /// A record the agent makes: live to every attached connection, kept for any later one.
  emit(step: { dir: string; kind: string; msg: any }): void {
    const record = this.add(step);
    for (const socket of this.sockets) socket.note("_acpmux/event", record);
  }
  summary() {
    return {
      sessionId: SESSION,
      cwd: "/home/dev/project",
      title: "Daemon swap",
      harness: "claude",
      status: this.status,
      steering: true,
      queuePaused: false,
      queued: 0,
      queue: [],
      turnCount: 4,
      createdAt: START,
      updatedAt: this.events.at(-1)?.at ?? START,
    };
  }
  /// The old daemon closes every socket (`code` 1012 for a restart, 1006 for a crash).
  drop(code: number): void {
    this.up = false;
    for (const socket of [...this.sockets]) socket.closeFromDaemon(code);
  }
}

/// One connection of the pane to the daemon of the moment; refused while no daemon is up.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: unknown) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  private attached = false;
  constructor(readonly store: Store) {
    const up = store.up;
    setTimeout(() => {
      if (!up) {
        this.readyState = 3;
        this.onerror?.();
        this.onclose?.({ code: 1006, reason: "", wasClean: false });
        return;
      }
      this.readyState = 1;
      store.sockets.add(this);
      this.onopen?.();
    }, 0);
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.method === "session/prompt") {
      // The old daemon goes before it takes the prompt: only a daemon that runs it counts.
      if (this.store.swallowPrompts) return;
      const promptId = String(message.params?._meta?.acpmux?.promptId ?? "");
      this.store.prompts.set(promptId, (this.store.prompts.get(promptId) ?? 0) + 1);
    }
    if (message.id === undefined) return;
    const result = this.answer(message);
    queueMicrotask(() => this.deliver({ jsonrpc: "2.0", id: message.id, result }));
  }
  close(): void {
    this.readyState = 3;
    this.store.sockets.delete(this);
  }
  closeFromDaemon(code: number): void {
    this.readyState = 3;
    this.store.sockets.delete(this);
    this.onclose?.({ code, reason: code === 1012 ? "service restart" : "", wasClean: code === 1012 });
  }
  note(method: string, params: unknown): void {
    if (this.attached) this.deliver({ jsonrpc: "2.0", method, params });
  }
  private deliver(message: unknown): void {
    if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify(message) });
  }
  private answer(message: Message): unknown {
    const params = message.params ?? {};
    const events = this.store.events;
    switch (message.method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [this.store.summary()] };
      case "_acpmux/attach": {
        this.attached = true;
        this.store.attaches += 1;
        const last = events.at(-1)?.seq ?? 0;
        const after = params.afterSeq === undefined ? 0 : Number(params.afterSeq);
        return {
          session: this.store.summary(),
          events: events.filter((event) => event.seq > after),
          hasMore: false,
          lastSeq: last,
          pageThrough: last,
          turnOpener: null,
        };
      }
      case "_acpmux/events": {
        const after = Number(params.afterSeq ?? 0);
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        return {
          events: events.filter((event) => event.seq > after && event.seq < before),
          hasMore: false,
          lastSeq: events.at(-1)?.seq ?? 0,
        };
      }
      case "session/prompt": {
        const promptId = String(params._meta?.acpmux?.promptId ?? "");
        const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
        // The turn runs: the prompt queues behind it, as acpmux queues a prompt sent mid-turn.
        queueMicrotask(() => {
          this.store.emit(mux("queued", { promptId, text }));
          this.note("_acpmux/prompt_accepted", { sessionId: SESSION, promptId });
        });
        return { stopReason: "end_turn" };
      }
      default:
        return null;
    }
  }
}

/// The app host's tail store (AgentPaneTailCache), which a closing client hands its tail to.
function installHost(): void {
  const tails = new Map<string, unknown>();
  (
    dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
  ).cmuxAcpmuxActions = {
    "chat.tail.get": async (params: any) => tails.get(String(params.sessionId)) ?? null,
    "chat.tail": async (params: any) => {
      if (params.tail) tails.set(String(params.sessionId), params.tail);
      else tails.delete(String(params.sessionId));
      return null;
    },
  };
}

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean, ms = 10_000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (!check()) {
    if (Date.now() > deadline) return false;
    await wait(5);
  }
  return true;
}

/// The words of the streaming reply a snapshot draws (`w00 w01 ...`), in order.
function streamedWords(snapshot: AcpmuxSnapshot): string[] {
  const text = (snapshot.rows ?? [])
    .filter((row) => row.kind === "assistant")
    .map((row) => row.text ?? "")
    .join(" ");
  return text.match(/\bw\d{2}\b/g) ?? [];
}

type Frame = { at: number; client: number; connection: string; snapshot: AcpmuxSnapshot };

/// The pane over the store, as App.tsx connects it: one listener for every client; a lost client
/// hands its chat to the next, which connects after the App's waits, again until a daemon answers.
async function pane(store: Store) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { lostRetryDelay, jitteredDelay, RETRY_FIRST_MS } = await import("../src/agent-session/acpmux/hostRetry");
  const { clientWaiter } = await import("../src/agent-session/acpmux/lostPrompt");
  const { resetKeptTailsForTests } = await import("../src/agent-session/acpmux/tailCache");
  resetKeptTailsForTests();
  installHost();
  type Client = DirectClient;
  const frames: Frame[] = [];
  const clients: Client[] = [];
  const connected = clientWaiter<Client>();
  let current: Client | undefined;
  let generation = 0;
  let lostAt: number | undefined;
  let retryDelay = RETRY_FIRST_MS;
  let connectedAt = 0;
  let closed = false;
  const lost: number[] = [];
  const connect = async (carried?: ReturnType<Client["takeCarried"]>): Promise<void> => {
    const mine = ++generation;
    try {
      const client = await AcpmuxDirectClient.connect(
        {
          protocolVersion: 1,
          transport: "acpmux-websocket",
          endpoint: "ws://swap.invalid/",
          token: "t",
          sessionId: SESSION,
        },
        (snapshot) => {
          if (snapshot.type !== "snapshot") return;
          frames.push({ at: performance.now(), client: mine, connection: snapshot.connection, snapshot });
        },
        () => {
          if (closed) return;
          lostAt = performance.now();
          lost.push(lostAt);
          const carry = current?.takeCarried();
          current = undefined;
          const next = lostRetryDelay(retryDelay, Date.now() - connectedAt);
          retryDelay = next.next;
          setTimeout(() => void connect(carry), jitteredDelay(next.wait));
        },
        () => new Daemon(store) as unknown as WebSocket,
        undefined,
        undefined,
        carried,
      );
      if (closed) return client.close();
      clients.push(client);
      current = client;
      connectedAt = Date.now();
      retryDelay = RETRY_FIRST_MS;
      connected.connected(client);
    } catch {
      // No daemon yet: the App's handshake loop asks again after its backoff.
      if (closed) return;
      const delay = jitteredDelay(retryDelay);
      retryDelay = Math.min(retryDelay * 2, 8_000);
      setTimeout(() => void connect(carried), delay);
    }
  };
  await connect();
  return {
    frames,
    connected,
    lost,
    current: () => current,
    close() {
      closed = true;
      for (const client of clients) client.close();
    },
  };
}

const summary: Record<string, unknown> = { swapGapMs: SWAP_GAP_MS };
let open: { close(): void } | undefined;
afterEach(() => {
  open?.close();
  open = undefined;
});
afterAll(() => {
  const line = JSON.stringify(summary);
  console.log(`DAEMON_SWAP_SUMMARY ${line}`);
  if (process.env.CMUX_DAEMON_SWAP_OUT) writeFileSync(process.env.CMUX_DAEMON_SWAP_OUT, `${line}\n`);
});

/// What an earlier chat holds: three finished turns.
function history(store: Store): void {
  for (let turn = 0; turn < 3; turn += 1) {
    store.add(mux("user_message", { text: `Earlier ask ${turn}`, promptId: `p-old-${turn}`, turnId: `t-old-${turn}` }));
    store.add(mux("turn_started", { turnId: `t-old-${turn}`, promptId: `p-old-${turn}` }));
    store.add(chunk(`Earlier answer ${turn}.`, `msg-old-${turn}`));
    store.add(mux("turn_result", { turnId: `t-old-${turn}`, status: "completed" }));
  }
}

/// `behind`: the follow-up is sent behind the streaming turn (it waits in the queue); otherwise the
/// turn ended first and it is sent into an idle chat (its own row in the transcript).
for (const [code, behind] of [
  [1012, true],
  [1006, true],
  [1012, false],
] as const)
  test(`a daemon swap (close ${code}) ${behind ? "mid-stream" : "after the turn"} keeps every word and delivers a prompt sent before it once`, async () => {
    const store = new Store();
    history(store);
    store.add(mux("user_message", { text: "Explain the swap", promptId: "p-live", turnId: "t-live" }));
    store.add(mux("turn_started", { turnId: "t-live", promptId: "p-live" }));
    const run = await pane(store);
    open = run;
    expect(await until(() => run.frames.some((frame) => frame.snapshot.rows?.length > 0))).toBe(true);
    const WORDS = 40;
    const word = (i: number) => `w${String(i).padStart(2, "0")} `;
    // The reply streams; the old daemon goes after word 15 (after the whole turn, idle).
    const beforeDrop = behind ? 15 : WORDS;
    for (let i = 0; i < beforeDrop; i += 1) {
      store.emit(chunk(word(i), "msg-live"));
      await wait(STREAM_MS);
    }
    if (!behind) store.emit(mux("turn_result", { turnId: "t-live", status: "completed" }));
    expect(await until(() => streamedWords(run.frames.at(-1)!.snapshot).length === beforeDrop)).toBe(true);
    if (!behind) expect(await until(() => run.frames.at(-1)!.snapshot.isWorking !== true)).toBe(true);
    // The person sends a follow-up; the swap lands before the daemon answers it.
    const sentOn = run.current()!;
    const { keepLostPrompt } = await import("../src/agent-session/acpmux/lostPrompt");
    const FOLLOW_UP = "Follow-up sent across the swap";
    store.swallowPrompts = true;
    const sendPromptId = "p-follow-up";
    const send = sentOn.send(FOLLOW_UP, [], sendPromptId).then(
      () => "taken" as const,
      (error: unknown) => keepLostPrompt(error, run.connected, sentOn, { input: FOLLOW_UP, attachments: [] }),
    );
    await wait(5);
    const framesBefore = run.frames.length;
    const droppedAt = performance.now();
    store.drop(code);
    // The agent goes on while no daemon answers: the new daemon keeps what it said meanwhile.
    if (behind) for (let i = 15; i < 25; i += 1) store.add(chunk(word(i), "msg-live"));
    await wait(SWAP_GAP_MS);
    store.up = true;
    store.swallowPrompts = false;
    // The host's prompt journal sends the lost prompt again once the new daemon answers (Swift
    // AgentPanePromptRelay), under its own promptId.
    let journalSent = false;
    const journal = setInterval(() => {
      if (journalSent || store.sockets.size === 0) return;
      journalSent = true;
      store.prompts.set(sendPromptId, (store.prompts.get(sendPromptId) ?? 0) + 1);
      if (behind) store.emit(mux("queued", { promptId: sendPromptId, text: FOLLOW_UP }));
      else {
        store.emit(mux("user_message", { text: FOLLOW_UP, promptId: sendPromptId, turnId: "t-follow" }));
        store.emit(mux("turn_started", { turnId: "t-follow", promptId: sendPromptId }));
      }
    }, 5);
    const back = await until(() => store.attaches >= 2 && run.current() !== undefined);
    const swappedAt = performance.now();
    // The new daemon streams the rest live.
    if (behind) {
      for (let i = 25; i < WORDS; i += 1) {
        store.emit(chunk(word(i), "msg-live"));
        await wait(STREAM_MS);
      }
      store.emit(mux("turn_result", { turnId: "t-live", status: "completed" }));
    }
    await until(() => streamedWords(run.frames.at(-1)!.snapshot).length >= WORDS);
    const outcome = await Promise.race([send, wait(12_000).then(() => "timeout" as const)]);
    await wait(100);
    clearInterval(journal);

    // Every frame from just before the drop on.
    const swap = run.frames.slice(Math.max(0, framesBefore - 1));
    let most = 0;
    let vanish = 0;
    let duplicated = 0;
    let blank = 0;
    let promptRowMissing = 0;
    let promptRowsMost = 0;
    let promptShownOnce = false;
    const states = new Set<string>();
    const trace: string[] = [];
    for (const frame of swap) {
      states.add(frame.connection);
      const words = streamedWords(frame.snapshot);
      if ((frame.snapshot.rows?.length ?? 0) === 0) blank += 1;
      if (words.length < most) vanish += 1;
      if (new Set(words).size !== words.length) duplicated += 1;
      most = Math.max(most, words.length);
      // The follow-up is one row: its own row in the transcript, or its queue row (QueuedPrompt).
      const queued = (frame.snapshot.queue ?? []).filter(
        (entry) => entry.id === sendPromptId || entry.prompt?.includes(FOLLOW_UP),
      ).length;
      const drawn = (frame.snapshot.rows ?? []).filter((row) => (row.text ?? "").includes(FOLLOW_UP)).length + queued;
      trace.push(`${frame.client}:${frame.connection}:w${words.length}:p${drawn}`);
      promptRowsMost = Math.max(promptRowsMost, drawn);
      if (drawn > 0) promptShownOnce = true;
      else if (promptShownOnce) promptRowMissing += 1;
    }
    const final = streamedWords(run.frames.at(-1)!.snapshot);
    const expected = Array.from({ length: WORDS }, (_, i) => word(i).trim());
    const lostWords = expected.filter((w) => !final.includes(w)).length;
    const dupWords = final.length - new Set(final).size;
    const delivered = store.prompts.get(sendPromptId) ?? 0;
    const result = {
      closeCode: code,
      frames: swap.length,
      blankFrames: blank,
      vanishFrames: vanish,
      duplicateFrames: duplicated,
      tokensLost: lostWords,
      tokensDuplicated: dupWords,
      reconnectMs: Math.round(swappedAt - droppedAt),
      reconnectAfterDaemonUpMs: Math.round(swappedAt - droppedAt - SWAP_GAP_MS),
      connectionStates: [...states],
      sendOutcome: outcome,
      sendsDelivered: delivered,
      sendsLost: delivered === 0 ? 1 : 0,
      sendsDuplicated: Math.max(0, delivered - 1),
      promptRowsMost,
      promptRowBlinkFrames: promptRowMissing,
      reconnected: back,
      /// Each frame: client:emit reason:streamed words:follow-up rows.
      trace,
    };
    summary[`${behind ? "midStream" : "idle"}_${code}`] = result;
    expect(result).toMatchObject({
      blankFrames: 0,
      vanishFrames: 0,
      duplicateFrames: 0,
      tokensLost: 0,
      tokensDuplicated: 0,
      sendsDelivered: 1,
      promptRowsMost: 1,
      promptRowBlinkFrames: 0,
    });
    expect(final).toEqual(expected);
  });

test("a pending permission ask stays on its card through a daemon swap", async () => {
  const { askOnSingleCard } = await import("../src/agent-session/acpmux/permissionKeys");
  const store = new Store();
  history(store);
  store.add(mux("user_message", { text: "Run the migration", promptId: "p-ask", turnId: "t-ask" }));
  store.add(mux("turn_started", { turnId: "t-ask", promptId: "p-ask" }));
  store.add(chunk("I will run the migration now.", "msg-ask"));
  store.add({
    dir: "in",
    kind: "tool_call",
    msg: {
      method: "session/update",
      params: {
        sessionId: SESSION,
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "call-ask",
          title: "bun run migrate",
          kind: "execute",
          status: "pending",
        },
      },
    },
  });
  store.add(
    mux("permission_request", {
      permissionId: "perm-ask",
      request: {
        toolCall: { toolCallId: "call-ask", title: "bun run migrate", kind: "execute" },
        options: [
          { optionId: "allow", name: "Allow", kind: "allow_once" },
          { optionId: "reject", name: "Reject", kind: "reject_once" },
        ],
      },
    }),
  );
  const run = await pane(store);
  open = run;
  const shows = (frame: Frame) =>
    askOnSingleCard(frame.snapshot.permission, frame.snapshot.permissionGroups) &&
    frame.snapshot.permission?.permissionId === "perm-ask";
  expect(await until(() => run.frames.some(shows))).toBe(true);
  await wait(50);
  const framesBefore = run.frames.length;
  const droppedAt = performance.now();
  store.drop(1012);
  await wait(SWAP_GAP_MS);
  store.up = true;
  await until(() => store.attaches >= 2 && run.current() !== undefined);
  const swappedAt = performance.now();
  await wait(200);
  const swap = run.frames.slice(Math.max(0, framesBefore - 1));
  const blinks = swap.filter((frame) => !shows(frame));
  const firstGone = blinks[0]?.at;
  const lastGone = blinks.at(-1)?.at;
  const result = {
    frames: swap.length,
    permissionBlinkFrames: blinks.length,
    permissionBlinkMs: firstGone === undefined ? 0 : Math.round(lastGone! - firstGone),
    permissionShownAtEnd: shows(run.frames.at(-1)!),
    reconnectMs: Math.round(swappedAt - droppedAt),
    blankFrames: swap.filter((frame) => (frame.snapshot.rows?.length ?? 0) === 0).length,
  };
  summary.permission = result;
  expect(result).toMatchObject({ permissionBlinkFrames: 0, permissionShownAtEnd: true, blankFrames: 0 });
});
