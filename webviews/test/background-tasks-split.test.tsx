// l10n-allow-file: test fixture text, not shipped UI.
// Background tasks opened into a split (Leo, 2026-11-22: "it gave me the agent pane could not be drawn
// after i opedn up background tasks. i guess it sent you to that split."). The composer hat's
// Background tasks button asks the app for the chat's Background tasks tab (`chat.subagentPane` with
// the reserved id `cmux:background-tasks`, backgroundPane.ts); the app opens it in a split right of the
// chat by handing a prewarmed spare page the chat with the reveal `subagent:cmux:background-tasks`
// (AgentPaneView.adoptSession, newtab/adoption.ts). That page must draw the panel, filling the tab,
// with no render error caught by the pane's boundary (PaneBoundary.tsx: "The agent pane could not be
// drawn") and no "Maximum update depth exceeded" (React #185) logged on the way.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

const originalError = console.error;
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

afterEach(async () => {
  console.error = originalError;
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext;
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

const newTab = { template: "default", cwd: "/tmp/spare-project", projects: ["/tmp/spare-project"] };
const REVEAL = "subagent:cmux:background-tasks";

/// What the page logged as errors, in their own words.
let errors: string[] = [];
const recordErrors = () => {
  errors = [];
  console.error = (...args: unknown[]) => {
    errors.push(args.map((arg) => (arg instanceof Error ? `${arg.message}\n${arg.stack}` : String(arg))).join(" "));
  };
};

/// The pane, under its production boundary (mountModel.tsx), on a host that answers with the in-page
/// mock daemon: a spare New Tab page, or the mock's chat opened directly. `subagentPane`: what the
/// host answers `chat.subagentPane` (the app's split opened, or none).
async function mount(kind: "spare" | "direct", subagentPane: { opened: boolean } = { opened: false }) {
  const { WORKED_SESSION } = await import("../src/agent-session/acpmux/mockFixture");
  if (kind === "spare") Object.assign(dom.window, { __cmuxNewTabContext: newTab });
  const ready =
    kind === "spare"
      ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac", newTab }
      : { protocolVersion: 1, transport: "mock", sessionId: WORKED_SESSION, machineName: "Mac" };
  const asked: string[] = [];
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: { subagent?: string } }) => {
            asked.push(
              message.method === "chat.subagentPane" ? `${message.method} ${message.params?.subagent}` : message.method,
            );
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? ready
                  : message.method === "newTab.context" && kind === "spare"
                    ? { newTab }
                    : message.method === "chat.scrollAnchor.get"
                      ? null
                      : message.method === "chat.subagentPane"
                        ? subagentPane
                        : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  const { PaneBoundary } = await import("../src/agent-session/acpmux/PaneBoundary");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <PaneBoundary>
        <AcpmuxApp />
      </PaneBoundary>,
    ),
  );
  return { session: WORKED_SESSION, asked };
}

const panel = () => host.querySelector<HTMLElement>(".acpmux-bg");
const failed = () => host.querySelector(".acpmux-pane-failed");
const loops = () => errors.filter((error) => /Maximum update depth|Too many re-renders|#185|#301/.test(error));

/// The pane drew the Background tasks panel and nothing failed on the way.
async function drawsPanel(what: string) {
  await until(() => panel() !== null || failed() !== null, what);
  // A few more turns: a loop that starts once the panel draws shows up here.
  for (let turn = 0; turn < 20; turn++) await tick();
  expect(loops(), "no update loop").toEqual([]);
  expect(failed(), "the pane's boundary caught nothing").toBeNull();
  expect(panel(), what).not.toBeNull();
}

test("the split the app opens for Background tasks (a spare adopted with its reveal) draws the panel", async () => {
  recordErrors();
  const { session } = await mount("spare");
  await until(() => host.querySelector(".nt-field") !== null, "the spare draws its New Tab page");
  await until(() => host.querySelector(".acpmux-dock") !== null, "the spare built the chat view");
  const { SESSION_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.CustomEvent(SESSION_ADOPT_EVENT, { detail: { sessionId: session, revealTurn: REVEAL } }),
    ),
  );
  await drawsPanel("the adopted split draws the Background tasks panel");
  // Its own tab: the panel fills it, with no Close of its own (the tab has one).
  expect(host.querySelector("[data-background-pane]")).not.toBeNull();
}, 60_000);

test("a chat page told to show the Background tasks tab draws the panel", async () => {
  recordErrors();
  await mount("direct");
  await until(() => host.querySelector(TRANSCRIPT_ROW) !== null, "the chat draws its rows");
  const bridge = () =>
    (dom.window as unknown as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } }).cmuxAcpmuxBridge;
  await until(() => bridge()?.revealTurn !== undefined, "the page's bridge");
  await act(async () => bridge()!.revealTurn!(REVEAL));
  await drawsPanel("the chat page draws the Background tasks panel");
}, 60_000);

test("Background tasks from the chat's actions, on a host that opens no split, docks the panel", async () => {
  recordErrors();
  const { asked } = await mount("direct", { opened: false });
  await until(() => host.querySelector(TRANSCRIPT_ROW) !== null, "the chat draws its rows");
  const page = dom.window.document;
  const actions = () =>
    page.querySelector<HTMLButtonElement>('button[aria-label="Chat actions"], button[title="Chat actions"]');
  await until(() => actions() !== null, "the chat's actions");
  await act(async () => actions()!.click());
  const item = () =>
    Array.from(page.querySelectorAll<HTMLElement>('[role="menuitem"]')).find(
      (node) => node.textContent?.trim() === "Background tasks",
    );
  await until(() => item() !== undefined, "the Background tasks item");
  await act(async () => item()!.click());
  await drawsPanel("the docked Background tasks panel");
  expect(asked).toContain("chat.subagentPane cmux:background-tasks");
}, 60_000);
