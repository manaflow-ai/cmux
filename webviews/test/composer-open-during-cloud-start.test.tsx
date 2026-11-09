// Leo, 2026-11-09: "And also, I can't click into the composer at all to, like potentially type other
// stuff while it's doing that initial load situation." A Cloud start made the composer `inert` until it
// ended (#28686), because this tab closes when the chat opens on its machine and anything typed
// meanwhile went with it. Now the composer stays open: the sent prompt leaves it (it shows as the
// message, with the start under it), what is typed or pasted meanwhile is kept and lands in the started
// chat's composer as a draft (never sent), a failed start puts the prompt back in front of it, and a
// second Send while the start is out starts nothing.
//
// The pane runs its real client against the in-page mock daemon; the native host is a stub whose
// `cloud.startChat` answers when the test says. The started chat is a second page on the same web
// data store, as every agent pane shares one (AgentPaneView+Warmup `sharedDataStore`).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;

/// The project folder is trusted on the mock daemon: no trust question holds the first send.
async function trustFolder() {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return Promise.resolve({ cwd: FOLDER, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } });
    return answer.call(this, method, params);
  };
}

afterEach(async () => {
  restoreAnswer?.();
  restoreAnswer = undefined;
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
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
  acpmuxMarkdownField?: { value(): string; type(text: string): unknown; focus(): void };
};
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};
const composerText = () => promptField()?.value() ?? "";
const composerBox = () => host.querySelector<HTMLElement>(".acpmux-composer-box");

type Debug = {
  runMode(mode?: string): { runMode?: string | null; error?: string };
  composeSend(text: string): Promise<{ sent?: boolean; error?: string }>;
};
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

const FOLDER = "/tmp/cloud-project";
const PROMPT = "Run the sidebar tests and fix what fails";
const TYPED = "also check the nightly once that is done";

/// A new chat on the mock daemon whose host offers Cloud. `cloud.startChat` waits until `answer` or
/// `fail`; `ready` adds the handshake fields a started chat's page gets (its seeded prompt).
async function mount(ready: Record<string, unknown> = {}) {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  const calls: string[] = [];
  let settle: ((reply: unknown) => void) | undefined;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            calls.push(message.method);
            if (message.method === "cloud.startChat") {
              starts.push(message.params ?? {});
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
    calls,
    answer: () => act(async () => settle?.({ ok: true, value: { machine: "paint-dev" } })),
    fail: (retryable = false) =>
      act(async () =>
        settle?.({
          ok: false,
          error: { code: "cloud_start_failed", userMessage: "The machine stopped answering.", retryable },
        }),
      ),
  };
}

/// Cloud picked, the prompt sent: the start is out.
async function startInCloud() {
  const pane = await mount();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is offered and picked");
  await typeInto(PROMPT);
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud");
  expect(pane.starts[0]!.task).toBe(PROMPT);
  return pane;
}

async function typeInto(text: string) {
  await act(async () => void promptField()!.type(text));
  await until(() => composerText() === text, "the composer takes what is typed");
}
const typeWhileStarting = typeInto;

/// Return in the prompt, as the person sends.
async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

test("the composer stays focusable and typable while a Cloud chat starts", async () => {
  await startInCloud();
  // The box is not inert, and the sent prompt left it: it shows as the message, not as a draft.
  expect(composerBox()?.hasAttribute("inert")).toBe(false);
  expect(promptElement()?.closest("[inert]")).toBeNull();
  await until(() => composerText() === "", "the sent prompt leaves the composer");
  await act(async () => promptField()!.focus());
  expect(promptElement()?.contains(dom.window.document.activeElement)).toBe(true);
  await typeWhileStarting(TYPED);
}, 60_000);

test("a second Send while the start is out starts no second chat and keeps the text", async () => {
  const pane = await startInCloud();
  const bubbles = () => [...host.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? "");
  await typeWhileStarting(TYPED);
  // Return again, still on Cloud: no second start.
  await pressSend();
  expect(pane.starts.length).toBe(1);
  expect(composerText()).toBe(TYPED);
  // The Where menu is reachable now: picking This Mac and pressing Return starts no chat here either,
  // which the host would close with this tab when the Cloud chat opens.
  await until(() => debug().runMode("persistent").runMode === "persistent", "This Mac is picked");
  await pressSend();
  for (let step = 0; step < 20; step += 1) await tick();
  expect(pane.starts.length).toBe(1);
  expect(bubbles().some((text) => text.includes(TYPED))).toBe(false);
  expect(composerText()).toBe(TYPED);
}, 60_000);

test("what was typed during the start lands in the started chat's composer, never sent", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  await pane.answer();
  // The host opened the chat on its machine and closes this tab.
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();

  // The started chat's page: its handshake seeds the prompt, which goes by itself.
  await mount({ prompt: PROMPT });
  await until(() => composerText() === TYPED, "the started chat's composer holds the draft");
  await until(
    () => [...host.querySelectorAll(".cv-user__bubble")].some((bubble) => bubble.textContent?.includes(PROMPT)),
    "the seeded prompt went",
  );
  expect([...host.querySelectorAll(".cv-user__bubble")].some((bubble) => bubble.textContent?.includes(TYPED))).toBe(
    false,
  );

  // Taken once: another chat opened with the same prompt gets no copy.
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await mount({ prompt: PROMPT });
  await tick();
  expect(composerText()).toBe("");
}, 90_000);

test("a failed start puts the prompt back in front of what was typed", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  await pane.fail();
  await until(() => composerText() === `${PROMPT}\n\n${TYPED}`, "the prompt is back, the typed text after it");
}, 60_000);

test("Retry on a failed start sends its prompt alone, under the same key, and keeps what was typed", async () => {
  const pane = await startInCloud();
  await typeWhileStarting(TYPED);
  await pane.fail(true);
  await until(() => composerText() === `${PROMPT}\n\n${TYPED}`, "the prompt is back, the typed text after it");
  const retry = () => host.querySelector<HTMLButtonElement>(".acpmux-cloud-start__retry");
  await until(() => retry() !== null, "the failure offers Retry");
  await act(async () => retry()!.click());
  await until(() => pane.starts.length === 2, "Retry starts again");
  expect(pane.starts[1]!.task).toBe(PROMPT);
  expect(pane.starts[1]!.key).toBe(pane.starts[0]!.key);
  await until(() => composerText() === TYPED, "the typed text stays, unsent");
}, 60_000);
