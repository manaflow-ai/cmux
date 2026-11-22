// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A reloaded chat draws its first frame as it will settle (Leo, 2026-11-22: "wtf? i just saw the
// entire thing flash and then re-render and then shift as it loaded in and expanded then collapsed
// tool calls"). The host reloads every chat page when a webviews dev server comes or goes
// (WebDevOverrideWatcher); the new document draws the chat from its kept tail (tailCache.ts) before
// acpmux answers, and that first frame folded the running turn's calls under "Worked for" (the tail
// says nothing of what the chat is doing now, #32735) and dropped the folds the reader had opened.
// The attach then opened the calls again: a frame expanded, collapsed, expanded.
//
// The detector: the real pane (AcpmuxApp, jsdom) shows a running chat, the reader opens a fold, and
// the page goes away (`pagehide`, which hands the host its tail). A second document mounts on the
// host's tail, in each way a reload reaches it: acpmux's socket slow to open (the tail drawn while
// connecting) and the host's handshake withheld (the retained tail drawn before `ready`). Every
// transcript frame is recorded at every DOM change, from the first that draws rows: each row's id
// and each fold's state. No frame may differ from the settled one, and the settled one is the first
// document's.
//
// Also here, Leo's hypothesis (06:46Z: "maybe it was some conflict with the ask thing?"): a
// permission card mounting while the chat streams under CPU load never blanks or remounts the
// transcript.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { settleReact, teardownDom } from "./support/domTeardown";

setDefaultTimeout(60_000);

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "https://cmux.test/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  localStorage: dom.window.localStorage,
  sessionStorage: dom.window.sessionStorage,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
const savedSocket = { had: "WebSocket" in scope, value: scope.WebSocket };

beforeAll(() => {
  Object.assign(scope, replacements);
  (dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
  // jsdom has no layout. A tall viewport mounts every row of this small chat.
  Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
  Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  scope.WebSocket = Daemon;
  (dom.window as unknown as { WebSocket: unknown }).WebSocket = Daemon;
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
  if (savedSocket.had) scope.WebSocket = savedSocket.value;
  else delete scope.WebSocket;
});

const CHAT = "chat-reload-folds";
const START = Date.UTC(2026, 10, 22, 6, 40, 0);
const FIRST_REPLY = "The first retry loop is fixed.";
const LIVE_TEXT = "Looking at the upload path now.";
const SECOND_PROMPT = "Now fix the upload path";

const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: CHAT, update: body },
});
const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const ran = (id: string, status = "completed") =>
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: `rg retry ${id}`,
    kind: "execute",
    status,
    rawInput: { command: `rg retry ${id}` },
  });

type Record_ = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
/// A finished turn of two commands and a reply, then a turn still running: a note, a command done
/// and one still running.
const STEPS: [string, string, Record<string, unknown>][] = [
  ["mux", "user_message", { text: "Find the retry bug", promptId: "p-1" }],
  ["mux", "turn_started", {}],
  ["in", "tool_call", ran("t1")],
  ["in", "tool_call", ran("t2")],
  ["in", "agent_message_chunk", chunk(FIRST_REPLY)],
  ["mux", "turn_result", { status: "completed" }],
  ["mux", "user_message", { text: SECOND_PROMPT, promptId: "p-2" }],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", chunk(`${LIVE_TEXT}\n\n`)],
  ["in", "tool_call", ran("t3")],
  ["in", "tool_call", ran("t4", "in_progress")],
];
const RECORDS: Record_[] = STEPS.map(([dir, kind, msg], at) => ({
  sessionId: CHAT,
  seq: at + 1,
  at: START + (at + 1) * 1000,
  dir,
  kind,
  msg,
}));

const SUMMARY = {
  sessionId: CHAT,
  cwd: "/home/dev/project",
  title: "Retry loops",
  harness: "claude",
  family: "claude",
  model: "claude-sonnet-4-5",
  status: "running",
  turnCount: 2,
  createdAt: START,
  updatedAt: START + 11_000,
};

/// acpmux as the page's sockets reach it. `openDelayMs` holds each socket's open that long (a busy
/// daemon after the page reloads), and `live` is the open socket the test streams records into.
class Daemon {
  static openDelayMs = 5;
  static records: Record_[] = RECORDS;
  static answered: string[] = [];
  static live: Daemon | undefined;
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: unknown) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;

  constructor() {
    setTimeout(() => {
      this.readyState = 1;
      Daemon.live = this;
      this.onopen?.();
    }, Daemon.openDelayMs);
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    if (message.id === undefined) return;
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: [SUMMARY] };
    else if (message.method === "_acpmux/attach")
      result = { session: SUMMARY, lastSeq: Daemon.records.length, events: Daemon.records, hasMore: false };
    else if (message.method === "_acpmux/draft_get") result = { draft: "" };
    else if (message.method === "_acpmux/events")
      result = { events: [], hasMore: false, lastSeq: Daemon.records.length };
    setTimeout(() => {
      if (this.readyState !== 1) return;
      Daemon.answered.push(message.method);
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
    }, 1);
  }

  /// A record acpmux journals and streams to the attached page now.
  push(dir: string, kind: string, msg: Record<string, unknown>): void {
    const record = { sessionId: CHAT, seq: Daemon.records.length + 1, at: START + 60_000, dir, kind, msg };
    Daemon.records = [...Daemon.records, record];
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record }) });
  }

  close(): void {
    if (Daemon.live === this) Daemon.live = undefined;
    this.readyState = 3;
  }
}

const doc = () => dom.window.document;
const root_ = () => doc().getElementById("root")!;

/// The transcript as drawn: each row's id and the state of each fold in it, in order.
function frame(): string {
  const rows = [...root_().querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
  return rows
    .map((row) => {
      const folds = [...row.querySelectorAll("[aria-expanded]")].map((fold) => fold.getAttribute("aria-expanded"));
      return folds.length ? `${row.dataset.rowId}[${folds.join(",")}]` : row.dataset.rowId!;
    })
    .join("\n");
}

/// Every distinct transcript frame, one entry per change, from the first that draws a row.
function recorder() {
  const frames: string[] = [];
  const sample = () => {
    const now = frame();
    if (!now && frames.length === 0) return;
    if (frames.at(-1) !== now) frames.push(now);
  };
  const observer = new dom.window.MutationObserver(sample);
  observer.observe(doc(), { subtree: true, childList: true, characterData: true, attributes: true });
  sample();
  return { frames, sample, stop: () => observer.disconnect() };
}

let root: import("react-dom/client").Root | undefined;
const { act } = await import("react");

/// One macrotask, inside act: timers, socket answers and React commits due now run.
const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });

async function until(check: () => boolean, what: string, within = 20_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

/// A few more turns of the loop, sampling: whatever the page still had to draw is drawn.
async function settle(sample?: () => void, passes = 30) {
  for (let pass = 0; pass < passes; pass += 1) {
    await tick();
    sample?.();
  }
}

/// The app host: its handshake (`ready`, held back until `release` when `holdReady`), and the
/// chat tails pages hand it (`chat.tail`) and ask it for (`chat.tail.get`).
function installHost(tails: Map<string, unknown>, options: { holdReady?: boolean; restored?: boolean } = {}) {
  let release = () => {};
  const ready = new Promise<void>((done) => {
    release = done;
  });
  if (!options.holdReady) release();
  Object.assign(dom.window, {
    ...(options.restored ? { __cmuxRestoredChat: CHAT } : {}),
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: async (message: { method: string; params?: Record<string, unknown> }) => {
            if (message.method === "ready") {
              await ready;
              return {
                ok: true,
                value: {
                  protocolVersion: 1,
                  transport: "acpmux-websocket",
                  endpoint: "ws://acpmux.test/",
                  token: "t",
                  sessionId: CHAT,
                  machineName: "Mac",
                },
              };
            }
            if (message.method === "chat.tail") {
              const session = String(message.params?.sessionId);
              if (message.params?.tail) tails.set(session, JSON.parse(JSON.stringify(message.params.tail)));
              else tails.delete(session);
              return { ok: true, value: null };
            }
            if (message.method === "chat.tail.get")
              return { ok: true, value: tails.get(String(message.params?.sessionId)) ?? null };
            return { ok: true, value: null };
          },
        },
      },
    },
  });
  return { release };
}

async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(root_());
  await act(async () => root!.render(<AcpmuxApp />));
}

/// The page goes away as a reload takes it: `pagehide` (the client hands the host its tail), then
/// the document's state with it. The host's tails stay.
async function reloadPage() {
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  });
  await act(async () => root?.unmount());
  root = undefined;
  root_().replaceChildren();
  await settleReact();
  const globals = dom.window as unknown as Record<string, unknown>;
  for (const key of ["__cmuxRestoredChat", "__cmuxChatSnapshotShown", "__cmuxChatSnapshotLive", "cmuxAcpmuxActions"])
    delete globals[key];
  dom.window.sessionStorage.clear();
  (await import("../src/agent-session/acpmux/tailCache")).resetKeptTailsForTests();
  Daemon.live?.close();
  Daemon.answered = [];
}

const attached = () => Daemon.answered.includes("_acpmux/attach");
const drawsChat = () => (root_().textContent ?? "").includes(SECOND_PROMPT);

/// The first document: the running chat, attached; the reader opens the first fold of the finished
/// turn. Returns the settled frame and the host's tails.
async function firstDocument() {
  const tails = new Map<string, unknown>();
  installHost(tails);
  await mount();
  await until(() => attached() && drawsChat(), "the first document draws the chat");
  await settle();
  const before = frame();
  // The finished turn's first fold (its "Worked for" or its run of commands), above the second prompt.
  const rows = [...root_().querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
  const second = rows.findIndex((row) => (row.textContent ?? "").includes(SECOND_PROMPT));
  expect(second).toBeGreaterThan(0);
  const toggle = rows
    .slice(0, second)
    .map((row) => row.querySelector<HTMLElement>("[aria-expanded='false']"))
    .find((found) => found !== null);
  expect(toggle, "the finished turn has a closed fold to open").toBeTruthy();
  await act(async () => toggle!.click());
  await settle();
  const opened = frame();
  expect(opened).not.toBe(before);
  return { tails, opened };
}

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  root_().replaceChildren();
  await settleReact();
  const globals = dom.window as unknown as Record<string, unknown>;
  for (const key of [
    "__cmuxRestoredChat",
    "__cmuxChatSnapshotShown",
    "__cmuxChatSnapshotLive",
    "cmuxAcpmuxActions",
    "webkit",
  ])
    delete globals[key];
  dom.window.sessionStorage.clear();
  (await import("../src/agent-session/acpmux/tailCache")).resetKeptTailsForTests();
  Daemon.live?.close();
  Daemon.openDelayMs = 5;
  Daemon.records = RECORDS;
  Daemon.answered = [];
});

/// Every frame of `frames` that differs from the last, with its index.
const offFrames = (frames: string[]) => frames.flatMap((drawn, at) => (drawn === frames.at(-1) ? [] : [{ at, drawn }]));

test("a reload whose acpmux socket is slow draws the kept tail as it will settle, folds and all", async () => {
  const { tails, opened } = await firstDocument();
  await reloadPage();
  expect((tails.get(CHAT) as { folds?: unknown } | undefined)?.folds, "the tail carries the open folds").toBeTruthy();
  // The new document: its handshake answers at once, acpmux's socket opens 400 ms later, so the
  // kept tail draws while it connects (direct.ts `drawTailWhileConnecting`).
  Daemon.openDelayMs = 400;
  installHost(tails);
  const record = recorder();
  await mount();
  await until(() => {
    record.sample();
    return attached() && drawsChat();
  }, "the reloaded document attaches the chat");
  await settle(record.sample);
  record.stop();
  expect(record.frames.length).toBeGreaterThan(0);
  expect({ off: offFrames(record.frames), final: record.frames.at(-1) }).toEqual({ off: [], final: opened });
});

test("a reload whose handshake is withheld draws the retained tail as it will settle, folds and all", async () => {
  const { tails, opened } = await firstDocument();
  await reloadPage();
  // The new document knows its chat before the host's handshake (`__cmuxRestoredChat`): it draws the
  // host's tail with no connection at all (restoredTail.ts), then the handshake comes.
  const host = installHost(tails, { holdReady: true, restored: true });
  const record = recorder();
  await mount();
  await until(() => {
    record.sample();
    return drawsChat();
  }, "the retained tail draws before the handshake");
  await settle(record.sample, 10);
  expect(attached()).toBe(false);
  host.release();
  await until(() => {
    record.sample();
    return attached() && drawsChat();
  }, "the reloaded document attaches the chat");
  await settle(record.sample);
  record.stop();
  expect({ off: offFrames(record.frames), final: record.frames.at(-1) }).toEqual({ off: [], final: opened });
});

test("a chat that ended while the page reloaded settles as ended", async () => {
  // The kept tail's turn was running; the attach says it ended. The settled frame is the ended
  // turn's, whatever the first frame drew (the reload's frames may change once, for the real end).
  const { tails } = await firstDocument();
  await reloadPage();
  Daemon.records = [...RECORDS, { ...RECORDS[5]!, seq: RECORDS.length + 1, at: START + 30_000 }];
  const ended = { ...SUMMARY, status: "idle" };
  const watch = SUMMARY.status;
  Object.assign(SUMMARY, ended);
  try {
    installHost(tails);
    await mount();
    await until(() => attached() && drawsChat(), "the reloaded document attaches the chat");
    await settle();
    // No running turn is drawn: no live line.
    expect(root_().querySelector(".acpmux-row[data-row-id='thinking-live']")).toBeNull();
  } finally {
    Object.assign(SUMMARY, { status: watch });
  }
});

test("a permission card mounting while the chat streams under load never blanks or remounts the transcript", async () => {
  const tails = new Map<string, unknown>();
  installHost(tails);
  await mount();
  await until(() => attached() && drawsChat(), "the chat draws");
  await settle();
  const thread = () => root_().querySelector<HTMLElement>(".acpmux-row[data-row-id]")?.parentElement ?? null;
  const shell = thread();
  expect(shell).not.toBeNull();
  // Every row node drawn now: a remount would replace them all.
  const nodes = new Map(
    [...root_().querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) => [row.dataset.rowId!, row]),
  );
  let blank = 0;
  let failed = 0;
  const observer = new dom.window.MutationObserver(() => {
    if (root_().querySelectorAll(".acpmux-row[data-row-id]").length === 0) blank += 1;
    if (root_().querySelector(".acpmux-pane-failed, [role='alert'] .acpmux-pane-failed")) failed += 1;
  });
  observer.observe(doc(), { subtree: true, childList: true });
  const live = Daemon.live!;
  // CPU load: each step burns 40 ms of the page's thread before the next record.
  const burn = () => {
    const until = performance.now() + 40;
    while (performance.now() < until) {}
  };
  for (let step = 0; step < 6; step += 1) {
    burn();
    await act(async () => live.push("in", "agent_message_chunk", chunk(`Streaming part ${step}. `)));
    await tick();
  }
  // The ask, as Leo saw it: an edit waiting on "Confirm base unchanged for edited files".
  await act(async () =>
    live.push(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "e1",
        title: "Edit upload.ts",
        kind: "edit",
        status: "pending",
      }),
    ),
  );
  await act(async () =>
    live.push("mux", "permission_request", {
      permissionId: "perm-1",
      request: {
        toolCall: { toolCallId: "e1", title: "Confirm base unchanged for edited files", kind: "edit" },
        options: [
          { optionId: "deny", name: "Deny", kind: "reject_once" },
          { optionId: "allow", name: "Allow once", kind: "allow_once" },
        ],
      },
    }),
  );
  for (let step = 0; step < 6; step += 1) {
    burn();
    await act(async () =>
      live.push(
        "in",
        "agent_thought_chunk",
        update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: `Thinking ${step}. ` } }),
      ),
    );
    await tick();
  }
  await settle();
  observer.disconnect();
  // The card is up.
  expect(root_().textContent ?? "").toContain("Allow once");
  // Nothing blanked, nothing failed, the transcript's container and its rows are the same nodes.
  expect({ blank, failed }).toEqual({ blank: 0, failed: 0 });
  expect(thread()).toBe(shell);
  for (const [id, node] of nodes) {
    const now = root_().querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`);
    if (now) expect(now, `row ${id} is the same node`).toBe(node);
  }
});
