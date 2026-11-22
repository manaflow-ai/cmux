// l10n-allow-file: test fixture prompts, not shipped UI.
// The pricing card's hold on a Cloud send (App `sendToCloud`, cloudPlanSubscribe.ts) ends with the start it held, and a
// plan bought meanwhile is read fresh, never from the app's kept read:
//  - held, the plan turns active, the page becomes the key one again: the held prompt starts exactly once;
//  - held, the person sends again once the plan is on and that start goes: the page becoming key again starts nothing
//    more and the start's progress card stays (a failed start never runs the held prompt a second time);
//  - a last read of `none` (a minute old) never holds a Send by itself: the plan is read fresh first
//    (`cloudMachine.list {fresh: true}`), and the return from checkout reads it fresh too.
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

const PROMPT = "Run the sidebar tests and fix what fails";
const NONE = { state: "none", id: null, max_size: null };
const PRO = { state: "active", id: "pro", max_size: "lg" };

type Pane = {
  starts: Record<string, unknown>[];
  lists: Record<string, unknown>[];
  subscribes: Record<string, unknown>[];
  setPlan(next: unknown): void;
  fail(): Promise<void>;
};

/// A new chat whose host offers Cloud: `cloudMachine.list` answers `plan` (as set), `cloud.startChat` waits until `fail`.
async function mount(): Promise<Pane> {
  const starts: Record<string, unknown>[] = [];
  const lists: Record<string, unknown>[] = [];
  const subscribes: Record<string, unknown>[] = [];
  let plan: unknown = NONE;
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
            if (message.method === "cloudMachine.list") lists.push({ ...message.params });
            if (message.method === "cloud.plan.subscribe") subscribes.push({ ...message.params });
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac", sandboxState: true }
                  : message.method === "cloudMachine.list"
                    ? { signedIn: true, loaded: true, machines: [], plan }
                    : message.method === "cloud.plan.subscribe"
                      ? { opened: true }
                      : message.method === "transport.gesture"
                        ? { ticket: "ticket-1" }
                        : message.method === "sandbox.state"
                          ? {}
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
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is offered and picked");
  return {
    starts,
    lists,
    subscribes,
    setPlan: (next) => (plan = next),
    fail: () =>
      act(async () =>
        settle?.({
          ok: false,
          error: { code: "cloud_start_failed", userMessage: "The machine stopped answering.", retryable: true },
        }),
      ),
  };
}

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { value(): string; type(text: string): unknown } };
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};
type Debug = { runMode(mode?: string): { runMode?: string | null; error?: string } };
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;
const startCard = () => host.querySelector<HTMLElement>(".acpmux-cloud-start");
const pricingCard = () => host.querySelector('[data-action="subscribe"][data-plan="next_pro"]');

async function typeAndSend() {
  if (promptField()?.value() !== PROMPT) {
    await act(async () => void promptField()!.type(PROMPT));
    await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  }
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

/// Held for want of a plan: Send shows the pricing card, Subscribe opens the checkout and the page waits.
async function holdAndSubscribe(pane: Pane) {
  const started = pane.starts.length;
  await typeAndSend();
  await until(() => pricingCard() !== null, "the pricing card shows in the start's place");
  expect(pane.starts).toHaveLength(started);
  await act(async () => (pricingCard() as HTMLButtonElement).click());
  await until(() => pane.subscribes.length === 1, "Subscribe asks the host for the checkout");
  await settle();
}

/// The person comes back from the browser: the page stops being the key one and becomes it again.
async function comeBack() {
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.Event("blur"));
    dom.window.dispatchEvent(new dom.window.Event("focus"));
  });
  await settle();
}

async function settle() {
  for (let step = 0; step < 10; step += 1) await tick();
}

let uninstallKey: (() => void) | undefined;
async function installKey() {
  const { installPageKey } = await import("../src/agent-session/acpmux/pageKey");
  uninstallKey = installPageKey(dom.window.document);
}

afterEach(async () => {
  uninstallKey?.();
  uninstallKey = undefined;
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudPlanForTest();
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

test("held, the plan turns active, the page becomes key again: the held prompt starts exactly once", async () => {
  const pane = await mount();
  await installKey();
  await holdAndSubscribe(pane);
  // Paid: the return reads the plan fresh and the held prompt goes, once.
  pane.setPlan(PRO);
  await comeBack();
  await until(() => pane.starts.length === 1, "the held prompt starts");
  expect(pane.starts[0]!.task).toBe(PROMPT);
  expect(pane.lists.at(-1)).toEqual({ fresh: true });
  await until(() => startCard()?.dataset.state === "starting", "the progress card shows");
  // Even after that start fails, coming back again starts nothing more.
  await pane.fail();
  await comeBack();
  await comeBack();
  expect(pane.starts).toHaveLength(1);
}, 60_000);

test("held, then a Send that goes: coming back starts nothing more and the progress card stays", async () => {
  const pane = await mount();
  await installKey();
  await holdAndSubscribe(pane);
  // A later read says the plan is on (the page's copy follows it); the person presses Send and the start goes.
  pane.setPlan(PRO);
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudPlanForTest({
    state: "active",
    id: "pro",
    maxSize: "lg",
  });
  await typeAndSend();
  await until(() => pane.starts.length === 1, "the Send starts");
  await until(() => startCard()?.dataset.state === "starting", "the progress card shows");
  await comeBack();
  expect(startCard()?.dataset.state).toBe("starting");
  expect(pane.starts).toHaveLength(1);
  // The start fails: the held prompt never goes a second time.
  await pane.fail();
  await until(() => startCard()?.dataset.state === "failed", "the card shows the failure");
  await comeBack();
  expect(pane.starts).toHaveLength(1);
}, 60_000);

test("a plan bought within the minute the app keeps a read: Send and the return read it fresh", async () => {
  const pane = await mount();
  await installKey();
  // The picker's read said none; the person bought a plan on the website since.
  await until(() => pane.lists.some((params) => Object.keys(params).length === 0), "Cloud's pick reads the plan");
  pane.setPlan(PRO);
  await typeAndSend();
  await until(() => pane.starts.length === 1, "the Send reads the plan fresh and starts");
  expect(pane.lists).toContainEqual({ fresh: true });
  expect(pricingCard()).toBeNull();
  await pane.fail();
  // Held again (no plan now), Subscribe, and a return within the old 60 s: a fresh read, and the retry goes.
  pane.setPlan(NONE);
  await until(() => startCard()?.dataset.state === "failed", "the failed start shows");
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudPlanForTest({
    state: "none",
    id: null,
    maxSize: null,
  });
  const freshBefore = pane.lists.filter((params) => params.fresh === true).length;
  await holdAndSubscribe(pane);
  pane.setPlan(PRO);
  await comeBack();
  expect(pane.lists.filter((params) => params.fresh === true).length).toBeGreaterThan(freshBefore + 1);
  await until(() => pane.starts.length === 2, "the held prompt starts after the return");
}, 60_000);
