// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A restored chat never steps back (Leo, 2026-11-09: "It shows me a glimpse of the past thing, and
// then it regresses into the skeletons and placeholders, and then it gets back to the true thing.
// So I feel like the intermediate steps, we can just, like, not bother trying to show them").
//
// The detector for that class: a relaunch of the real pane (AcpmuxApp, jsdom) is played through its
// stages, the last launch's copy on screen (chatSnapshot/boot.ts), the cold mount, the host's
// handshake, acpmux restoring (its socket refused, as after Restart to Update) and acpmux live,
// and each surface the person sees is recorded at every DOM change: the transcript, the composer's
// unsent draft, its model pill and its context ring. A surface is `snapshot` while the copy covers it, `real` once the
// live page draws the chat's own value, and `placeholder` for a stand-in (an empty transcript, a
// pill that reads "Model", an empty ring). The trace may go placeholder → snapshot → real, never
// from snapshot or real back down to placeholder.
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

const CHAT = "chat-restore";
const START = Date.UTC(2026, 10, 9, 21, 0, 0);
const PROMPT = "Look at the retry path";
const REPLY = "Retry added to the upload path.";
const MODEL = "claude-sonnet-4-5";
/// What the person had typed and not sent, which acpmux keeps (`_acpmux/draft_get`).
const DRAFT = "and the download path too";

/// The chat's records as acpmux stores them: a prompt, the reply, and a usage report (the ring).
const RECORDS = [
  { dir: "mux", kind: "user_message", msg: { text: PROMPT } },
  {
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: {
        sessionId: CHAT,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
      },
    },
  },
  {
    dir: "in",
    kind: "usage_update",
    msg: {
      method: "session/update",
      params: { sessionId: CHAT, update: { sessionUpdate: "usage_update", used: 52_000, size: 200_000 } },
    },
  },
].map((record, at) => ({ sessionId: CHAT, seq: at + 1, at: START + (at + 1) * 1000, ...record }));

const SUMMARY = {
  sessionId: CHAT,
  cwd: "/home/dev/project",
  title: "Retry path",
  harness: "claude",
  family: "claude",
  model: MODEL,
  status: "idle",
  turnCount: 1,
  createdAt: START,
  updatedAt: START + 3000,
};

/// acpmux as the page's sockets reach it. `refusing` refuses every connect (acpmux restoring after
/// an update); once it is false each socket answers the chat. `attachDelayMs` answers the chat's
/// attach that much later (a busy daemon still reading its sessions back), and `drop()` closes every
/// open socket, as a daemon that restarts does.
class Daemon {
  static attachDelayMs = 0;
  /// False: acpmux lists no such chat (it was deleted while the app was closed).
  static listsChat = true;
  /// Every request answered, in order, by method.
  static answered: string[] = [];
  static open = new Set<Daemon>();
  static drop(): void {
    for (const socket of Daemon.open) {
      socket.readyState = 3;
      socket.onclose?.({ code: 1006, wasClean: false });
    }
    Daemon.open.clear();
  }
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static refusing = true;
  /// Connects refused since `refusing` was last set.
  static refused = 0;
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: unknown) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;

  constructor() {
    setTimeout(() => {
      if (Daemon.refusing) {
        Daemon.refused += 1;
        this.readyState = 3;
        this.onerror?.();
        this.onclose?.({ code: 1006, wasClean: false });
        return;
      }
      this.readyState = 1;
      Daemon.open.add(this);
      this.onopen?.();
    }, 5);
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    if (message.id === undefined) return;
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: Daemon.listsChat ? [SUMMARY] : [] };
    else if (message.method === "_acpmux/attach")
      result = { session: SUMMARY, lastSeq: RECORDS.length, events: RECORDS, hasMore: false };
    else if (message.method === "_acpmux/draft_get") result = { draft: DRAFT };
    else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: RECORDS.length };
    const delay = message.method === "_acpmux/attach" ? Daemon.attachDelayMs : 1;
    setTimeout(() => {
      if (this.readyState !== 1) return;
      Daemon.answered.push(message.method);
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
    }, delay);
  }

  close(): void {
    Daemon.open.delete(this);
    this.readyState = 3;
  }
}

type Surface = "transcript" | "draft" | "model" | "ring";
type State = "placeholder" | "snapshot" | "real";
const SURFACES: Surface[] = ["transcript", "draft", "model", "ring"];
const RANK: Record<State, number> = { placeholder: 0, snapshot: 1, real: 2 };

const doc = () => dom.window.document;
const copyShown = () => doc().querySelector("cmux-chat-snapshot") !== null;

/// What the person sees of each surface now.
function look(): Record<Surface, State> {
  if (copyShown()) return { transcript: "snapshot", draft: "snapshot", model: "snapshot", ring: "snapshot" };
  const root = doc().getElementById("root")!;
  const transcript: State = (root.textContent ?? "").includes(REPLY) ? "real" : "placeholder";
  const prompt = root.querySelector(".acpmux-composer-prompt")?.textContent ?? "";
  const draft: State = prompt.includes(DRAFT) ? "real" : "placeholder";
  const chips = root.querySelector(".acpmux-chips")?.textContent ?? "";
  const model: State = chips.includes("Sonnet 4.5") ? "real" : "placeholder";
  const ringButton = root.querySelector(".acpmux-context-ring");
  const ring: State = ringButton && ringButton.getAttribute("aria-disabled") !== "true" ? "real" : "placeholder";
  return { transcript, draft, model, ring };
}

/// Every surface's states in order, one entry per change.
function recorder() {
  const trace: Record<Surface, State[]> = { transcript: [], draft: [], model: [], ring: [] };
  const sample = () => {
    const now = look();
    for (const surface of SURFACES) if (trace[surface].at(-1) !== now[surface]) trace[surface].push(now[surface]);
  };
  const observer = new dom.window.MutationObserver(sample);
  observer.observe(doc(), { subtree: true, childList: true, characterData: true, attributes: true });
  sample();
  return { trace, sample, stop: () => observer.disconnect() };
}

/// The steps down in `states`: content (a copy or the chat's own value) followed by a stand-in.
function stepsDown(states: State[]): string[] {
  const out: string[] = [];
  let best: State = "placeholder";
  for (const state of states) {
    if (RANK[state] < RANK[best] && state === "placeholder") out.push(`${best} → ${state}`);
    if (RANK[state] > RANK[best]) best = state;
  }
  return out;
}

/// The copy the last launch's boot script drew (boot.ts / paint.ts), as the live page finds it.
function drawCopy(): void {
  const host = doc().createElement("cmux-chat-snapshot");
  host.attachShadow({ mode: "open" }).innerHTML = `<div>${REPLY}</div>`;
  doc().body.appendChild(host);
  (dom.window as unknown as Record<string, unknown>).__cmuxChatSnapshotShown = { at: 1 };
}

/// The tail the app host kept on disk at the last launch (AgentPaneTailDisk), or none.
const keptTail = () => ({
  events: RECORDS,
  summary: SUMMARY,
  historyExhausted: true,
  queue: [],
  configSeq: 0,
  usageFromSeq: 0,
});

let root: import("react-dom/client").Root | undefined;
const { act } = await import("react");

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  doc().getElementById("root")!.replaceChildren();
  doc().querySelector("cmux-chat-snapshot")?.remove();
  const globals = dom.window as unknown as Record<string, unknown>;
  await settleReact();
  for (const key of ["__cmuxChatSnapshotShown", "__cmuxChatSnapshotLive", "cmuxAcpmuxActions", "webkit"])
    delete globals[key];
  dom.window.sessionStorage.clear();
  (await import("../src/agent-session/acpmux/tailCache")).resetKeptTailsForTests();
});

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

/// A relaunch: the copy is up, the page mounts, the host answers its handshake at once, acpmux
/// refuses the page's first `refusals` connects (it restores), then answers. Returns each surface's
/// trace.
async function relaunch(options: { tail: boolean; refusals: number; attachDelayMs?: number }) {
  Daemon.refusing = options.refusals > 0;
  Daemon.refused = 0;
  Daemon.attachDelayMs = options.attachDelayMs ?? 0;
  drawCopy();
  const tail = options.tail ? keptTail() : null;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            let value: unknown;
            if (message.method === "ready")
              value = {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: "ws://acpmux.test/",
                token: "t",
                sessionId: CHAT,
                machineName: "Mac",
              };
            else if (message.method === "chat.tail.get") value = tail;
            else value = null;
            return Promise.resolve({ ok: true, value });
          },
        },
      },
    },
  });
  const record = recorder();
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(doc().getElementById("root")!);
  await act(async () => root!.render(<AcpmuxApp />));
  // acpmux restoring: the page's connects are refused, and it retries quietly (hostRetry.ts).
  await until(() => {
    record.sample();
    return Daemon.refused >= options.refusals;
  }, "the page tried acpmux while it restored");
  // acpmux is live: the next retry connects and attaches the chat.
  Daemon.refusing = false;
  await until(
    () => {
      record.sample();
      const now = look();
      return SURFACES.every((surface) => now[surface] === "real");
    },
    "every surface ends on the chat's own value",
    20_000 + (options.attachDelayMs ?? 0),
  );
  return { trace: record.trace, record };
}

/// A live chat whose acpmux restarts under it: the sockets drop, the page's next `refusals`
/// connects are refused, then acpmux answers again.
async function restart(record: Awaited<ReturnType<typeof relaunch>>["record"], refusals: number) {
  Daemon.refusing = true;
  Daemon.refused = 0;
  await act(async () => Daemon.drop());
  await until(() => {
    record.sample();
    return Daemon.refused >= refusals;
  }, "the page tried acpmux while it restarted");
  Daemon.refusing = false;
  const before = Daemon.answered.length;
  // Through the reattach: its attach and draft read answered and drawn, not only a socket open.
  await until(() => {
    record.sample();
    const since = Daemon.answered.slice(before);
    return since.includes("_acpmux/attach") && since.includes("_acpmux/draft_get");
  }, "the page reattaches the chat once acpmux answers");
  for (let pass = 0; pass < 10; pass += 1) {
    await tick();
    record.sample();
  }
}

function expectMonotonic(trace: Record<Surface, State[]>) {
  const down = Object.fromEntries(SURFACES.map((surface) => [surface, stepsDown(trace[surface])]));
  expect({ trace, down }).toEqual({ trace, down: { transcript: [], draft: [], model: [], ring: [] } });
}

afterEach(() => {
  Daemon.drop();
  Daemon.attachDelayMs = 0;
  Daemon.listsChat = true;
  Daemon.answered = [];
});

const finished = async (run: ReturnType<typeof relaunch>) => {
  const { trace, record } = await run;
  record.stop();
  return trace;
};

test("a relaunch while acpmux restores keeps the last frame until the chat is live (no tail kept)", async () => {
  expectMonotonic(await finished(relaunch({ tail: false, refusals: 3 })));
});

test("a relaunch while acpmux restores keeps the last frame until the chat is live (tail kept)", async () => {
  expectMonotonic(await finished(relaunch({ tail: true, refusals: 3 })));
});

test("a relaunch where acpmux answers at once swaps the copy for the chat in one step", async () => {
  expectMonotonic(await finished(relaunch({ tail: true, refusals: 0 })));
});

test("a relaunch whose attach outlasts the page's draw hold keeps the copy, not an empty chat", async () => {
  // App.tsx CHAT_DRAW_HOLD_MS is 10 s; acpmux reading its sessions back after an update takes longer.
  expectMonotonic(await finished(relaunch({ tail: false, refusals: 0, attachDelayMs: 11_000 })));
}, 60_000);

test("a live chat whose acpmux restarts keeps what it shows until the chat is back", async () => {
  const { trace, record } = await relaunch({ tail: false, refusals: 0 });
  await restart(record, 3);
  await until(() => {
    record.sample();
    const now = look();
    return SURFACES.every((surface) => now[surface] === "real");
  }, "every surface ends on the chat's own value after the restart");
  record.stop();
  expectMonotonic(trace);
}, 60_000);

test("a relaunched chat acpmux no longer lists gives the copy up for why, at once", async () => {
  // Not held until the copy's own 40 s bound: the unavailable state, with its way out, is the chat now.
  Daemon.refusing = false;
  Daemon.listsChat = false;
  drawCopy();
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) =>
            Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "acpmux-websocket",
                      endpoint: "ws://acpmux.test/",
                      token: "t",
                      sessionId: CHAT,
                      // A restored tab is bound to its chat: one acpmux lacks says why (direct.ts).
                      sessionMustExist: true,
                      machineName: "Mac",
                    }
                  : null,
            }),
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(doc().getElementById("root")!);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(
    () => !copyShown() && doc().querySelector(".acpmux-unavailable:not([data-unavailable='connecting'])") !== null,
    "the copy goes for the chat's unavailable state",
    10_000,
  );
});
