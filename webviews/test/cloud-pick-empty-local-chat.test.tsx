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
  await until(() => actions() !== undefined && promptField() !== undefined, "the new chat connects");
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

test("an empty chat whose local session opened first picks Cloud in place, and its Send starts Cloud", async () => {
  const pane = await mount();
  const session = await openEmptyLocalChat();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is offered and picked in the empty chat");
  // Cloud alone: the empty chat is no place for a Sandboxed run's result.
  expect(debug().runMode("sandboxed").error).toBe("the composer offers no run place now");
  const prompts = daemonCalls.filter((method) => method === "session/prompt").length;
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  expect(pane.starts[0]!.task).toBe(PROMPT);
  expect(pane.starts[0]!.replacesChat).toBe(session);
  for (let step = 0; step < 10; step += 1) await tick();
  // The empty local chat never got the prompt.
  expect(daemonCalls.filter((method) => method === "session/prompt").length).toBe(prompts);
  expect(debug().chatState().rows).toBe(0);
  // The chat view shows the start as the no-session path does: the sent prompt and its card, not the hero.
  await until(() => startCard()?.dataset.state === "starting", "the start card shows while the start is out");
  expect(bubbles().some((text) => text.includes(PROMPT))).toBe(true);
  expect(host.querySelector(".acpmux-home-area")).toBeNull();
  // A failure says why and offers Retry, which sends the start again for the same empty chat.
  await pane.fail();
  await until(() => startCard()?.dataset.state === "failed", "the card shows the failure");
  expect(startCard()!.textContent).toContain("The machine stopped answering.");
  const retry = () => host.querySelector<HTMLButtonElement>(".acpmux-cloud-start__retry");
  await until(() => retry() !== null, "the failure offers Retry");
  await act(async () => retry()!.click());
  await until(() => pane.starts.length === 2, "Retry starts again");
  expect(pane.starts[1]!.task).toBe(PROMPT);
  expect(pane.starts[1]!.replacesChat).toBe(session);
  await until(() => startCard()?.dataset.state === "starting", "the card shows the retried start");
}, 60_000);

// New Cloud Chat beside a chat lands here: a pick of Cloud reserves the machine ahead of Send, as a page with
// no session does, naming the empty chat the start replaces, and the Send starts on that reserved machine.
test("Cloud picked in an empty local chat reserves a machine ahead, and its Send starts on it", async () => {
  const pane = await mount();
  const session = await openEmptyLocalChat();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked in the empty chat");
  await until(() => pane.reservations.length > 0, "picking Cloud reserves a machine");
  const [method, reserved] = pane.reservations[0]!;
  expect(method).toBe("cloud.reserve");
  expect(reserved.replacesChat).toBe(session);
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  expect(pane.starts[0]!.reservationKey).toBe(reserved.composeKey);
  expect(pane.starts[0]!.replacesChat).toBe(session);
  expect(pane.reservations.some(([call]) => call === "cloud.releaseReservation")).toBe(false);
}, 60_000);

test("leaving Cloud in an empty local chat gives its reserved machine back", async () => {
  const pane = await mount();
  await openEmptyLocalChat();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked in the empty chat");
  await until(() => pane.reservations.length > 0, "picking Cloud reserves a machine");
  const key = pane.reservations[0]![1].composeKey;
  expect(debug().runMode("persistent").runMode).toBe("persistent");
  await until(
    () => pane.reservations.some(([call, params]) => call === "cloud.releaseReservation" && params.composeKey === key),
    "leaving Cloud releases the compose's machine",
  );
}, 60_000);

test("another chat in the pane after the reserve releases it, and the new chat's Send reserves and starts afresh", async () => {
  const pane = await mount();
  const first = await openEmptyLocalChat();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked in the empty chat");
  await until(() => pane.reservations.length > 0, "picking Cloud reserves a machine");
  const firstKey = pane.reservations[0]![1].composeKey;
  // The harness switch: the inherited agent's empty chat is replaced by another agent's.
  await act(async () => void (await debug().newChat("codex", FOLDER)));
  await until(
    () => Boolean(debug().chatState().sessionId) && debug().chatState().sessionId !== first,
    "the chat changed",
  );
  for (let step = 0; step < 10; step += 1) await tick();
  const second = debug().chatState().sessionId!;
  await until(
    () =>
      pane.reservations.some(([call, params]) => call === "cloud.releaseReservation" && params.composeKey === firstKey),
    "the first chat's machine is released",
  );
  if (debug().runMode().runMode !== "cloud")
    await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked again");
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  expect(pane.starts[0]!.replacesChat).toBe(second);
  // Never the released machine: a new reservation for the new chat, or the ordinary create.
  expect(pane.starts[0]!.reservationKey).not.toBe(firstKey);
  const named = pane.starts[0]!.reservationKey;
  if (named !== undefined)
    expect(pane.reservations).toContainEqual(["cloud.reserve", { composeKey: named, replacesChat: second }]);
}, 60_000);

test("New Cloud Chat's pick is taken once Cloud is offered, also after the empty local chat opened", async () => {
  const pane = await mount({ pickCloud: true }, true);
  await openEmptyLocalChat();
  expect(debug().runMode().runMode).toBe("persistent");
  await pane.check();
  await until(() => debug().runMode().runMode === "cloud", "the pending New Cloud Chat pick took Cloud");
}, 60_000);

test("a chat that said something offers no Cloud run place", async () => {
  await mount();
  await openEmptyLocalChat();
  await act(async () => void (await debug().sendPrompt("hello")));
  await until(() => (debug().chatState().rows ?? 0) > 0, "the local chat has its first turn");
  for (let step = 0; step < 10; step += 1) await tick();
  expect(debug().runMode("cloud").error).toBe("the composer offers no run place now");
}, 60_000);
