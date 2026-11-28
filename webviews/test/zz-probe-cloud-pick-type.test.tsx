// "I just want to select Cloud and I expect everything to work": New Agent Chat or New Cloud Chat
// beside a chat starts its inherited agent at once, so the new chat has an idle local session before
// anything is said in it. Cloud stayed offered only to a chat with no session, so Environment > Cloud
// fell back to the old New Cloud Workspace dialog and New Cloud Chat's pick was dropped. An empty
// local chat now still picks Cloud in place, and its first Send starts the chat on a Cloud machine,
// naming the empty chat the start replaces (the host closes this tab with it); the empty local chat
// never gets the prompt. A chat that has said something offers no Cloud run place.
//
// The pane runs its real client against the in-page mock daemon; the native host is a stub.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
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
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;
/// The daemon methods the page sent, in order.
let daemonCalls: string[] = [];

const FOLDER = "/tmp/cloud-empty-chat";
const PROMPT = "Run the sidebar tests and fix what fails";

/// The project folder is trusted on the mock daemon, and every method it gets is recorded.
async function trustFolder() {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    daemonCalls.push(method);
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return Promise.resolve({ cwd: FOLDER, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } });
    return answer.call(this, method, params);
  };
}

afterEach(async () => {
  restoreAnswer?.();
  restoreAnswer = undefined;
  daemonCalls = [];
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
async function until(check: () => boolean, what: string, within = 15_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { value(): string; type(text: string): unknown } };
const promptElement = () =>
  host.querySelector<FieldElement>(".nt-composer") ?? host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};

type Debug = {
  runMode(mode?: string): { runMode?: string | null; error?: string };
  chatState(): { sessionId?: string | null; rows?: number };
  newChat(harness?: string, cwd?: string): Promise<{ sessionId?: string | null; error?: string }>;
  sendPrompt(text: string): Promise<unknown>;
};
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

/// A new chat on the mock daemon whose host offers Cloud. `cloud.startChat` waits until `fail` (the start
/// is out); `holdCheck` keeps the tab's `sandbox.state` read unanswered until `check()`.
async function mount(ready: Record<string, unknown> = {}, holdCheck = false) {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  /// The compose reservation calls the page made (`cloud.reserve`, `cloud.releaseReservation`), in order.
  const reservations: [string, Record<string, unknown>][] = [];
  let answerCheck: (() => void) | undefined;
  let settle: ((reply: unknown) => void) | undefined;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            if (message.method === "cloud.reserve" || message.method === "cloud.releaseReservation")
              reservations.push([message.method, { ...message.params }]);
            if (message.method === "cloud.startChat") {
              starts.push({ ...message.params });
              return new Promise((done) => (settle = done));
            }
            if (message.method === "sandbox.state" && holdCheck && !answerCheck)
              return new Promise((done) => (answerCheck = () => done({ ok: true, value: {} })));
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      sandboxState: true,
                      cwd: FOLDER,
                      ...ready,
                    }
                  : message.method === "sandbox.state"
                    ? {}
                    : message.method === "transport.gesture"
                      ? { ticket: "ticket-1" }
                      : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(
    () => actions() !== undefined && (promptField() !== undefined || host.querySelector(".nt-composer") !== null),
    "the new chat connects",
  );
  return {
    starts,
    reservations,
    check: () => act(async () => answerCheck?.()),
    fail: () =>
      act(async () =>
        settle?.({
          ok: false,
          error: { code: "cloud_start_failed", userMessage: "The machine stopped answering.", retryable: true },
        }),
      ),
  };
}

/// The inherited agent starts at once, as New Agent Chat beside a chat does: an idle local chat shows.
async function openEmptyLocalChat(): Promise<string> {
  await act(async () => void (await debug().newChat("claude", FOLDER)));
  await until(() => Boolean(debug().chatState().sessionId), "the empty local chat opened");
  // Its summary comes with the session's first frame.
  for (let step = 0; step < 10; step += 1) await tick();
  return debug().chatState().sessionId!;
}

const startCard = () => host.querySelector<HTMLElement>(".acpmux-cloud-start");
const bubbles = () => [...host.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? "");

async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

const whereButton = () => [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")];
const menuRows = () => [
  ...dom.window.document.querySelectorAll<HTMLElement>(
    ".acpmux-env-popover .acpmux-menu-item, .acpmux-env-popover [role=option]",
  ),
];
function state(label: string) {
  const d = dom.window.document;
  const a = d.activeElement as HTMLElement | null;
  const inert = [...d.querySelectorAll("[inert]")].map((e) => e.className.toString().slice(0, 60));
  console.log(
    label,
    JSON.stringify({
      active: a ? `${a.tagName}.${a.className.toString().slice(0, 60)}` : null,
      inPrompt: Boolean(promptElement()?.contains(a)),
      promptInert: Boolean(promptElement()?.closest("[inert]")),
      inert,
      popover: Boolean(d.querySelector(".acpmux-env-popover")),
      buttons: whereButton().map((b) => b.getAttribute("aria-label")),
      session: debug().chatState().sessionId ?? null,
      mode: debug().runMode().runMode,
      nt: Boolean(d.querySelector(".nt-composer")),
      dockInert: Boolean(d.querySelector(".acpmux-dock[inert]")),
    }),
  );
}
for (const variant of ["auto-newtab", "plain-newtab"]) {
  test(`probe ${variant}`, async () => {
    if (variant.startsWith("auto"))
      dom.window.localStorage.setItem("cmux.agentPane.lastNewChatPlace", JSON.stringify({ kind: "auto" }));
    await mount(
      variant.endsWith("newtab")
        ? { newTab: { template: "default", layout: "b", lastAgent: "claude", cwd: FOLDER } }
        : {},
    );
    if (variant.endsWith("empty")) await openEmptyLocalChat();
    for (let i = 0; i < 20; i += 1) await tick();
    state("before");
    const button = whereButton().find((b) => /Where|Computer|Auto|Mac/i.test(b.getAttribute("aria-label") ?? ""));
    if (!button) return console.log("no where button");
    await act(async () => {
      button.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
      button.click();
    });
    for (let i = 0; i < 5; i += 1) await tick();
    console.log("rows", JSON.stringify(menuRows().map((r) => r.textContent?.replace(/\s+/g, " ").slice(0, 50))));
    const cloud = menuRows().find((r) => (r.textContent ?? "").trim().startsWith("Cloud"));
    if (!cloud) return console.log("no cloud row");
    await act(async () => {
      cloud.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
      cloud.click();
    });
    state("after0");
    for (let i = 0; i < 30; i += 1) await tick();
    state("after30");
  }, 60_000);
}
