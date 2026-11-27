// l10n-allow-file: test fixture text, not shipped UI.
// cmux#63350: a chat page that idle hibernation released is built again when its tab shows, by a
// prewarmed spare taking the chat (`acpmux-session-adopt`). With acpmux stalled (a starved or stopped
// daemon), the chat's attach does not answer, and once the page's draw hold ran out
// (App.tsx CHAT_DRAW_HOLD_MS) the host showed a pane with no rows and nothing naming the chat: to the
// person, their chat was gone and a new one stood in its place. These hold, with the attach unanswered:
// - the page never shows a new chat (New Tab, the plain new chat) for the chat it took;
// - past the hold it says it is opening that chat, which is what the page is;
// - once acpmux answers, the chat's rows replace that line.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
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
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
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


const newTab = { template: "default", cwd: "/tmp/stalled-project", projects: ["/tmp/stalled-project"] };
const painted: unknown[] = [];

/// A spare New Tab page on the in-page mock daemon, whose attach answers only after `attachMs`.
/// `cold`: the chat's own page, its handshake naming the chat (the host's cold rebuild of the tab).
async function mountSpare(attachMs: number, cold = false) {
  const { WORKED_SESSION } = await import("../src/agent-session/acpmux/mockFixture");
  if (!cold) Object.assign(dom.window, { __cmuxNewTabContext: newTab });
  Object.assign(globalThis, { cmuxAcpmuxMockSlowMethod: "_acpmux/attach", cmuxAcpmuxMockSlowMs: attachMs });
  const ready = cold
    ? { protocolVersion: 1, transport: "mock", sessionId: WORKED_SESSION, sessionMustExist: true, machineName: "Mac" }
    : { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac", newTab };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: unknown }) => {
            if (message.method === "pane.painted") painted.push(message.params);
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? ready
                  : message.method === "newTab.context" && !cold
                    ? { newTab }
                    : message.method === "chat.scrollAnchor.get"
                      ? null
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
  return WORKED_SESSION;
}

const rows = () => host.querySelectorAll(TRANSCRIPT_ROW).length;
/// The pane's sign that it is reading the chat: the transcript's loading mark.
const opening = () => host.querySelector(".acpmux-transcript-loading");
/// What would read as a new chat: the New Tab page, or the plain new chat (EmptyState.tsx).
const showsNewChat = () =>
  host.querySelector(".nt-field") !== null ||
  host.querySelector("[data-plain-new-chat]") !== null ||
  host.querySelector("[data-new-chat]") !== null;

afterEach(() => {
  delete (globalThis as Record<string, unknown>).cmuxAcpmuxMockSlowMethod;
  delete (globalThis as Record<string, unknown>).cmuxAcpmuxMockSlowMs;
  painted.length = 0;
});

test("a spare that took a chat acpmux does not answer for says it opens that chat, never a new one", async () => {
  const session = await mountSpare(16_000);
  await until(() => host.querySelector(".nt-field") !== null, "the spare draws its New Tab page");
  const { SESSION_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  // The New Tab page's own paint report is the spare's; the adopted chat's is the next one.
  painted.length = 0;
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.CustomEvent(SESSION_ADOPT_EVENT, { detail: { sessionId: session, scrollAnchor: null } }),
    ),
  );
  // Past the page's draw hold (10 s): the page reports its first paint and the host shows it.
  await until(() => painted.length > 0, "the page reports its first paint past the draw hold", 13_000);
  expect(rows(), "the attach has not answered").toBe(0);
  expect(showsNewChat(), "the chat the spare took shows as a new chat").toBe(false);
  expect(opening(), "the pane says it opens the chat").not.toBeNull();
  // acpmux answers: the chat's own rows take the line's place.
  await until(() => rows() > 0, "the chat draws once its attach answers", 15_000);
  expect(opening(), "the opening line left with the rows").toBeNull();
  expect(showsNewChat()).toBe(false);
}, 60_000);

test("a chat page built again while acpmux does not answer its attach says it opens that chat", async () => {
  await mountSpare(16_000, true);
  await until(() => painted.length > 0, "the page reports its first paint past the draw hold", 13_000);
  expect(rows(), "the attach has not answered").toBe(0);
  expect(showsNewChat(), "the chat shows as a new chat").toBe(false);
  expect(opening(), "the pane says it opens the chat").not.toBeNull();
  await until(() => rows() > 0, "the chat draws once its attach answers", 15_000);
  expect(opening()).toBeNull();
}, 60_000);
