// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Leo, 2026-11-22: "FUCKING RECONNECTING JUST LET ME SEND WHY WOULD IT FUCKING BLOCK SENDS IN THE
// FIRST PLACE STUPID STUPID FUCKING DESIGN".
//
// Send never waits for the link to acpmux (offlineSends.ts). The whole pane (AcpmuxApp, jsdom) runs
// against a fake acpmux over the page's own socket: the chat connects, the socket drops and acpmux
// refuses the page's reconnects, and the person types and sends three prompts through the real
// composer meanwhile. After every act() the composer is read: its field must stay editable, its box
// never inert and Send never disabled while it holds text. Each prompt must leave the composer and
// show as its own pending `local-<promptId>` row at once. Once acpmux answers again, it must get
// exactly three `session/prompt` requests, in the order sent, under the three rows' prompt ids, and
// a second reconnect must send none of them again.
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

const CHAT = "0190a000-0000-7000-8000-00000000d0d0";
const START = Date.UTC(2026, 10, 22, 23, 0, 0);
const FIRST_PROMPT = "Look at the retry path";
const FIRST_REPLY = "Retry added to the upload path.";
const SENT = ["first while reconnecting", "second while reconnecting", "third while reconnecting"];

type Recorded = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };

/// acpmux as the page's sockets reach it. While `refusing`, every connect fails (acpmux gone or
/// restarting); otherwise a socket answers the chat. `drop()` closes every open socket under the page.
/// A prompt is recorded and logged into the chat as acpmux logs it, so a later attach has it.
class Daemon {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static refusing = false;
  static refused = 0;
  static open = new Set<Daemon>();
  /// Every request answered, by method, in order.
  static answered: string[] = [];
  /// Every `session/prompt` acpmux got, in order: its prompt id and its text.
  static prompts: { promptId: string; text: string }[] = [];
  static history: Recorded[] = [];

  static reset(): void {
    Daemon.refusing = false;
    Daemon.refused = 0;
    Daemon.open.clear();
    Daemon.answered = [];
    Daemon.prompts = [];
    Daemon.history = [
      record("mux", "user_message", { text: FIRST_PROMPT, promptId: "p-0", turnId: "turn-0" }),
      record("mux", "turn_started", { promptId: "p-0", turnId: "turn-0" }),
      record("in", "agent_message_chunk", say(FIRST_REPLY)),
      record("mux", "turn_result", { status: "completed", turnId: "turn-0" }),
    ];
  }

  static drop(): void {
    for (const socket of Daemon.open) {
      socket.readyState = 3;
      socket.onclose?.({ code: 1006, reason: "", wasClean: false });
    }
    Daemon.open.clear();
  }

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
        this.onclose?.({ code: 1006, reason: "", wasClean: false });
        return;
      }
      this.readyState = 1;
      Daemon.open.add(this);
      this.onopen?.();
    }, 5);
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (message.id === undefined) return;
    const lastSeq = Daemon.history.at(-1)?.seq ?? 0;
    let result: unknown = {};
    let after: (() => void) | undefined;
    switch (message.method) {
      case "initialize":
        result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
        break;
      case "_acpmux/watch":
        result = { sessions: [summary()] };
        break;
      case "_acpmux/attach": {
        const from = typeof message.params?.afterSeq === "number" ? message.params.afterSeq : 0;
        result = {
          session: summary(),
          lastSeq,
          events: Daemon.history.filter((event) => event.seq > from),
          hasMore: false,
        };
        break;
      }
      case "_acpmux/events": {
        const from = Number(message.params?.afterSeq ?? 0);
        const before = Number(message.params?.beforeSeq ?? Infinity);
        result = {
          events: Daemon.history.filter((event) => event.seq > from && event.seq < before),
          hasMore: false,
          lastSeq,
        };
        break;
      }
      case "_acpmux/draft_get":
        result = { draft: "" };
        break;
      case "acp.trust.get":
        result = { cwd: summary().cwd, level: "trusted", harnesses: { claude: "trusted" } };
        break;
      case "session/prompt": {
        const promptId = String(message.params?._meta?.acpmux?.promptId ?? "");
        const blocks = (message.params?.prompt ?? []) as { type?: string; text?: string }[];
        const text = blocks
          .filter((block) => block.type === "text")
          .map((block) => block.text ?? "")
          .join("");
        Daemon.prompts.push({ promptId, text });
        const turnId = `turn-${Daemon.prompts.length}`;
        const logged = [
          record("mux", "user_message", { text, promptId, turnId }),
          record("mux", "turn_started", { promptId, turnId }),
          record("in", "agent_message_chunk", say(`Reply ${Daemon.prompts.length}.`)),
          record("mux", "turn_result", { status: "completed", turnId }),
        ];
        after = () => {
          this.notify("_acpmux/prompt_accepted", { sessionId: CHAT, promptId });
          for (const event of logged) this.notify("_acpmux/event", event);
        };
        result = { stopReason: "end_turn" };
        break;
      }
    }
    setTimeout(() => {
      if (this.readyState !== 1) return;
      Daemon.answered.push(message.method);
      after?.();
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
    }, 1);
  }

  close(): void {
    Daemon.open.delete(this);
    this.readyState = 3;
  }

  private notify(method: string, params: unknown): void {
    if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }
}

function record(dir: string, kind: string, msg: unknown): Recorded {
  const seq = (Daemon.history?.at(-1)?.seq ?? 0) + 1;
  const event = { sessionId: CHAT, seq, at: START + seq * 1000, dir, kind, msg };
  Daemon.history = [...(Daemon.history ?? []), event];
  return event;
}

function say(text: string) {
  return {
    method: "session/update",
    params: { sessionId: CHAT, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  };
}

function summary() {
  return {
    sessionId: CHAT,
    cwd: "/home/dev/project",
    title: "Retry path",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1 + Daemon.prompts.length,
    createdAt: START,
    updatedAt: Daemon.history.at(-1)?.at ?? START,
  };
}

beforeAll(() => {
  Object.assign(scope, replacements);
  (dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
  // jsdom has no layout. A tall viewport mounts every row of this small chat.
  Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
  Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
  // ProseMirror measures a Range to scroll; jsdom's has no rects.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  scope.WebSocket = Daemon;
  (dom.window as unknown as { WebSocket: unknown }).WebSocket = Daemon;
});

const { act } = await import("react");
let root: import("react-dom/client").Root | undefined;

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  Daemon.drop();
  doc().getElementById("root")!.replaceChildren();
  await settleReact();
  const globals = dom.window as unknown as Record<string, unknown>;
  for (const key of ["cmuxAcpmuxActions", "webkit"]) delete globals[key];
  dom.window.sessionStorage.clear();
  dom.window.localStorage.clear();
  (await import("../src/agent-session/acpmux/tailCache")).resetKeptTailsForTests();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
  if (savedSocket.had) scope.WebSocket = savedSocket.value;
  else delete scope.WebSocket;
});

const doc = () => dom.window.document;
const host = () => doc().getElementById("root")!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { value(): string; type(text: string): unknown } };
const promptElement = () => host().querySelector<FieldElement>(".acpmux-composer-prompt");
const editable = () => promptElement()?.querySelector<HTMLElement>("[contenteditable]") ?? undefined;
const promptField = () => (editable() ? promptElement()?.acpmuxMarkdownField : undefined);
const composerText = () => promptField()?.value() ?? "";
/// The composer's Send (not its Stop or Resume).
const sendButton = () =>
  host().querySelector<HTMLButtonElement>("button.acpmux-send:not(.acpmux-cancel):not(.acpmux-resume)") ?? undefined;
/// The transcript's prompts drawn before the chat's client draws them: `local-<promptId>` rows.
const localRows = () =>
  [...host().querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="local-"]')].map((row) => ({
    promptId: row.getAttribute("data-row-id")!.slice("local-".length),
    text: row.textContent ?? "",
  }));

/// What blocked the composer in a frame, if anything: an uneditable field, an inert or disabled
/// box, a disabled textarea, or a Send that is disabled; and, once React has committed (after an
/// act()), a Send that is missing or not ready while the composer holds text. A DOM change mid-commit
/// can show the field's new text a moment before React draws the Send beside it.
function blockedNow(committed: boolean): string[] {
  const out: string[] = [];
  const prompt = promptElement();
  if (!prompt) return ["no composer"];
  const field = editable();
  if (!field) out.push("no editable field");
  else if (field.getAttribute("contenteditable") === "false") out.push("field not editable");
  if (prompt.closest("[inert]")) out.push("composer inert");
  if (prompt.closest("[aria-disabled='true']")) out.push("composer aria-disabled");
  for (const area of host().querySelectorAll<HTMLTextAreaElement>(".acpmux-composer-box textarea"))
    if (area.disabled) out.push("textarea disabled");
  const send = sendButton();
  if (send?.disabled) out.push("send disabled");
  if (committed && composerText().trim()) {
    if (!send) out.push("no send with text");
    else if (!send.classList.contains("acpmux-send-ready")) out.push("send not ready with text");
  }
  return out;
}

/// Every frame's blocks, after every act() and every DOM change.
const frames: { at: string; committed: boolean; blocked: string[] }[] = [];
let phase = "mount";
const sample = (committed = true) => {
  if (!promptElement()) return;
  frames.push({ at: phase, committed, blocked: blockedNow(committed) });
};
const step = async (body: () => unknown) => {
  await act(async () => void (await body()));
  sample();
};
const tick = () => step(() => new Promise((done) => setTimeout(done, 0)));
async function until(check: () => boolean, what: string, within = 20_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

/// The pane on the chat, connected: its composer up and its actions installed.
async function mount() {
  Daemon.reset();
  frames.length = 0;
  phase = "mount";
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
                      machineName: "Mac",
                    }
                  : message.method === "transport.gesture"
                    ? { ticket: "ticket-1" }
                    : null,
            }),
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host());
  await step(() => root!.render(<AcpmuxApp />));
  await until(
    () => Boolean(actions()?.["chat.send"]) && promptField() !== undefined && host().textContent!.includes(FIRST_REPLY),
    "the pane connects to the chat",
  );
}

/// The socket drops and acpmux refuses the page's reconnects until `restore`.
async function dropLink() {
  Daemon.refusing = true;
  Daemon.refused = 0;
  await step(() => Daemon.drop());
  await until(() => !actions()?.["chat.send"] && Daemon.refused >= 1, "the link is down and the page reconnects");
}

async function restoreLink() {
  Daemon.refusing = false;
  const before = Daemon.answered.length;
  await until(() => Boolean(actions()?.["chat.send"]), "a new connection is up");
  await until(() => Daemon.answered.slice(before).includes("_acpmux/attach"), "the chat is attached again");
}

/// The person types `text` and sends it: Return in the field, or a click on Send.
async function typeAndSend(text: string, by: "enter" | "click") {
  await step(() => void promptField()!.type(text));
  await until(() => composerText() === text, "the composer takes what is typed");
  if (by === "enter")
    await step(() =>
      editable()!.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
      ),
    );
  else {
    const send = sendButton();
    expect(send, "Send shows while the composer holds text").toBeDefined();
    await step(() => send!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true })));
  }
  // At once: the very next frame has it out of the composer and in the transcript as its own row.
  const left = composerText();
  const shown = localRows().some((row) => row.text.includes(text));
  return { left, shown };
}

test("Send never blocks while the link to acpmux is down; the prompts go once, in order, when it is back", async () => {
  await mount();
  const observer = new dom.window.MutationObserver(() => sample(false));
  observer.observe(doc(), { subtree: true, childList: true, characterData: true, attributes: true });
  try {
    phase = "link down";
    await dropLink();
    const atSend: { text: string; left: string; shown: boolean }[] = [];
    for (const [index, text] of SENT.entries()) {
      phase = `send ${index + 1}`;
      atSend.push({ text, ...(await typeAndSend(text, index === 1 ? "click" : "enter")) });
    }
    // Each left the composer and showed as its own row at once.
    expect(atSend).toEqual(SENT.map((text) => ({ text, left: "", shown: true })));
    // Nothing reached acpmux while it was gone; three pending rows, in the order sent.
    expect(Daemon.prompts).toEqual([]);
    const rows = localRows();
    expect(rows.map((row) => SENT.findIndex((text) => row.text.includes(text)))).toEqual([0, 1, 2]);
    const promptIds = rows.map((row) => row.promptId);
    expect(new Set(promptIds).size).toBe(3);

    phase = "link back";
    await restoreLink();
    await until(() => Daemon.prompts.length >= 3, "the three prompts reach acpmux");
    for (let pass = 0; pass < 30; pass += 1) await tick();
    expect(Daemon.prompts).toEqual(SENT.map((text, index) => ({ promptId: promptIds[index]!, text })));

    // A second drop and reconnect sends none of them again.
    phase = "second drop";
    await dropLink();
    phase = "second link back";
    await restoreLink();
    for (let pass = 0; pass < 60; pass += 1) await tick();
    expect(Daemon.prompts.map((prompt) => prompt.promptId)).toEqual(promptIds);
    // Each prompt shows once in the chat.
    const text = host().textContent ?? "";
    for (const sent of SENT) expect(text.split(sent).length - 1, `"${sent}" shows once`).toBe(1);
  } finally {
    observer.disconnect();
  }
  // No frame, from the connect through both reconnects, had the composer blocked.
  const blocked = frames.filter((frame) => frame.blocked.length > 0);
  expect({
    acts: frames.some((frame) => frame.committed),
    mutations: frames.some((frame) => !frame.committed),
    blocked: blocked.slice(0, 10),
  }).toEqual({ acts: true, mutations: true, blocked: [] });
});
