// Auto as the new chat's Where: Send asks this Mac's daemon (`_acpmux/place_chat`) where the chat runs, and the
// chat then starts through the same code as the explicit picks. A Cloud answer starts it on a Cloud machine
// (`cloud.startChat`, as Cloud picked does) and the local chat never gets the prompt; a here answer sends it
// to the local chat and starts nothing in Cloud.
//
// The pane runs its real client against the in-page mock daemon, which here also serves `_acpmux/place_chat`
// with a fixed decision; the native host is a stub.
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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
    matchMedia: () => ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }),
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
  const box = () => ({
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    width: 0,
    height: 0,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;
/// The daemon calls the page made, in order.
let daemonCalls: [string, Record<string, unknown>][] = [];

const FOLDER = "/tmp/auto-where-chat";
const PROMPT = "Run the sidebar tests and fix what fails";
const PLACE_CHAT = "_acpmux/place_chat";

/// The mock daemon trusts the folder, advertises `_acpmux/place_chat` and answers it with `decision`.
async function daemonDecides(decision: Record<string, unknown>) {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = async function (this: unknown, method, params) {
    daemonCalls.push([method, params]);
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return {
        cwd: FOLDER,
        level: "trusted",
        harnesses: { claude: "trusted", codex: "trusted" },
      };
    if (method === PLACE_CHAT) return decision;
    const reply = await answer.call(this, method, params);
    if (method !== "initialize") return reply;
    const init = reply as { _meta: { acpmux: Record<string, unknown> } };
    return {
      ...init,
      _meta: {
        ...init._meta,
        acpmux: { ...init._meta.acpmux, extensions: [PLACE_CHAT] },
      },
    };
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

type FieldElement = HTMLElement & {
  acpmuxMarkdownField?: { value(): string; type(text: string): unknown };
};
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

async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        key: "Enter",
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  await tick();
}

/// A new chat whose host offers Cloud, with Auto the remembered Where (lastNewChatPlace.ts). Every
/// `cloud.startChat` is recorded and left out until `fail` answers the newest with a failure.
async function mount() {
  dom.window.localStorage.setItem("cmux.agentPane.lastNewChatPlace", JSON.stringify({ kind: "auto" }));
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
  return {
    starts,
    fail: () =>
      act(async () =>
        settle?.({
          ok: false,
          error: { code: "cloud_start_failed", userMessage: "The machine stopped answering.", retryable: true },
        }),
      ),
  };
}

/// The empty local chat New Agent Chat opens, in which Cloud (and so Auto) is offered.
async function openEmptyLocalChat(): Promise<string> {
  await act(async () => void (await debug().newChat("claude", FOLDER)));
  await until(() => Boolean(debug().chatState().sessionId), "the empty local chat opened");
  for (let step = 0; step < 10; step += 1) await tick();
  return debug().chatState().sessionId!;
}

const prompts = () => daemonCalls.filter(([method]) => method === "session/prompt");
const placeCalls = () => daemonCalls.filter(([method]) => method === PLACE_CHAT);
const arrival = () => host.querySelector<HTMLElement>(".acpmux-auto-arrival");

async function sendWithAutoPicked() {
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
}

test("Auto picked + Send: the daemon's Cloud answer starts the chat on a Cloud machine", async () => {
  await daemonDecides({
    placement: { at: "there", place: "cloud" },
    reason: { code: "over_budget", over: ["load1 9.0 >= 8 (8 cores)"] },
    why: "This Mac is over budget (load1 9.0 >= 8 (8 cores)); cloud has room.",
  });
  const pane = await mount();
  const session = await openEmptyLocalChat();
  const before = prompts().length;
  await sendWithAutoPicked();
  await until(() => placeCalls().length === 1, "Send asks the daemon where the chat runs");
  expect(placeCalls()[0]![1]).toEqual({
    where: "auto",
    targets: [{ place: "cloud", headroom: "room" }],
  });
  await until(() => pane.starts.length === 1, "the Cloud answer starts the chat in Cloud");
  expect(pane.starts[0]!.task).toBe(PROMPT);
  expect(pane.starts[0]!.replacesChat).toBe(session);
  for (let step = 0; step < 10; step += 1) await tick();
  // One decision per Send, and the local chat never got the prompt.
  expect(placeCalls().length).toBe(1);
  expect(pane.starts.length).toBe(1);
  expect(prompts().length).toBe(before);
}, 60_000);

test("Auto picked + Send: the daemon's here answer sends the prompt to this Mac's chat, no Cloud start", async () => {
  await daemonDecides({
    placement: { at: "here" },
    reason: { code: "within_budget" },
    why: "This Mac is within budget.",
  });
  const pane = await mount();
  const session = await openEmptyLocalChat();
  const before = prompts().length;
  await sendWithAutoPicked();
  await until(() => placeCalls().length === 1, "Send asks the daemon where the chat runs");
  await until(() => prompts().length === before + 1, "the here answer sends the prompt locally");
  expect(prompts().at(-1)![1].sessionId).toBe(session);
  expect(JSON.stringify(prompts().at(-1)![1].prompt)).toContain(PROMPT);
  await until(() => arrival() !== null, "the arrival line says where the chat went");
  for (let step = 0; step < 10; step += 1) await tick();
  expect(pane.starts.length).toBe(0);
  expect(placeCalls().length).toBe(1);
}, 60_000);

test("Auto picked + Send: a decided send that does not go is not decided for the next Send, which asks the daemon again", async () => {
  await daemonDecides({
    placement: { at: "there", place: "cloud" },
    reason: { code: "over_budget", over: ["load1 9.0 >= 8 (8 cores)"] },
    why: "This Mac is over budget (load1 9.0 >= 8 (8 cores)); cloud has room.",
  });
  const pane = await mount();
  await openEmptyLocalChat();
  await sendWithAutoPicked();
  await until(() => pane.starts.length === 1, "the first Send starts the chat in Cloud");
  expect(placeCalls().length).toBe(1);
  // The Cloud start fails: the prompt comes back to the composer, and the decision with it goes.
  await pane.fail();
  await until(
    () => host.querySelector<HTMLElement>(".acpmux-cloud-start")?.dataset.state === "failed",
    "the start failed",
  );
  if (promptField()?.value() !== PROMPT) await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer holds the prompt again");
  await pressSend();
  await until(() => placeCalls().length === 2, "the second Send asks the daemon where the chat runs again");
  await until(() => pane.starts.length === 2, "and starts it where the new answer says");
  expect(pane.starts[1]!.task).toBe(PROMPT);
}, 60_000);
