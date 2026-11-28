// Austin, 2026-11-27: "for cmux cloud chat we have some issues where the initial chat loads and then when we do a
// “transition” to a cloud chat it likes blinks out and then changes the chat… sometimes there is an error and the
// chat just goes blank and stuff or loads forever".
//
// A Cloud start in place keeps this page (cmux-cloud-start-core `one_pane`): the host re-homes it onto the Cloud
// machine, its reconnect starts the chat there, and `cloud.startChat` answers ok meanwhile. The page cleared its
// start card on that answer, so it drew an empty chat (no session, no rows) until the Cloud chat's first frame:
// the blink. A Cloud chat whose start then failed stayed that empty chat. Now the card, with the sent prompt, stays
// until the Cloud chat's first page is drawn, and a failure on the way shows on it, prompt kept.
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
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
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

/// A new chat with no session on the mock daemon whose host offers Cloud; `cloud.startChat` waits until `open`
/// answers it ok (the host opened the chat on its machine) or `fail` refuses it.
async function mount() {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  let settle: ((reply: unknown) => void) | undefined;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            if (message.method === "cloud.startChat") {
              starts.push({ ...message.params });
              return new Promise((done) => (settle = done));
            }
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
  await until(() => actions() !== undefined && promptField() !== undefined, "the new chat connects");
  return { starts, open: () => act(async () => settle?.({ ok: true, value: { machine: "Cloud machine" } })) };
}

const startCard = () => host.querySelector<HTMLElement>(".acpmux-cloud-start");
const bubbles = () => [...host.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? "");

/// Sends PROMPT with Cloud picked, and waits for the start to be out with its card.
async function sendToCloud(pane: Awaited<ReturnType<typeof mount>>) {
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is offered and picked");
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  await until(() => startCard()?.dataset.state === "starting", "the start card shows while the start is out");
}

/// Each frame from now until `done`: whether the pane drew the sent prompt (the card's or the chat's) and no hero.
function watchFrames() {
  const blanks: string[] = [];
  const observer = new dom.window.MutationObserver(() => {
    const prompt = bubbles().some((text) => text.includes(PROMPT));
    if (!prompt) blanks.push(host.querySelector(".acpmux-home-area") ? "hero" : "empty chat");
  });
  observer.observe(host, { childList: true, subtree: true, characterData: true, attributes: true });
  return { blanks, done: () => observer.disconnect() };
}

test("an opened Cloud start keeps its card and prompt on screen until the Cloud chat's first page, never a blank", async () => {
  const pane = await mount();
  await sendToCloud(pane);
  const frames = watchFrames();
  // The host opened the chat on its machine; the page's reconnect has not drawn the Cloud chat yet.
  await pane.open();
  for (let step = 0; step < 20; step += 1) await tick();
  expect(startCard(), "the card stays once the host opened the chat").not.toBeNull();
  expect(bubbles().some((text) => text.includes(PROMPT))).toBe(true);
  expect(host.querySelector(".acpmux-home-area")).toBeNull();
  // The Cloud chat's session, before its first row: still the card.
  await act(async () => void (await debug().newChat("claude", FOLDER)));
  await until(() => Boolean(debug().chatState().sessionId), "the Cloud chat's session opened");
  for (let step = 0; step < 10; step += 1) await tick();
  expect(startCard(), "a session with no row yet keeps the card").not.toBeNull();
  // Its first page: the prompt's row. The card goes in the same frame the chat draws.
  await act(async () => void (await debug().sendPrompt(PROMPT)));
  await until(() => (debug().chatState().rows ?? 0) > 0, "the Cloud chat's first page arrived");
  await until(() => startCard() === null, "the card gives way to the Cloud chat");
  expect(bubbles().some((text) => text.includes(PROMPT))).toBe(true);
  frames.done();
  expect(frames.blanks, "no frame between the start and the Cloud chat drew a pane without the prompt").toEqual([]);
}, 60_000);
