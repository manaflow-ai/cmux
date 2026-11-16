// l10n-allow-file: test fixture text, not shipped UI.
// A prewarmed spare New Tab page that takes a released chat (`acpmux-session-adopt`,
// AgentPaneView.adoptSession) builds the chat view before the event: the view is mounted hidden
// under New Tab (`<Activity mode="hidden">`), so the adopt event's own task only shows it and draws
// the chat's rows. Before, that task built the whole chat view (header, dock, composer, pickers) in
// New Tab's place: one ~70 ms React pass at 10 turns (first-load-after-restart MODE=reopen-spare).
// These hold:
// - the spare holds the chat view, hidden, before any adopt, and the adopt shows those same nodes;
// - the chat the spare took shows what the same chat opened directly shows: no state of the empty
//   view (its composer text, its new chat's harness and model chips) carries into the chat.
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

const newTab = { template: "default", cwd: "/tmp/spare-project", projects: ["/tmp/spare-project"] };

/// The pane on a host that answers with the in-page mock daemon: a spare New Tab page (`spare`),
/// the mock's chat opened directly (`direct`), or a new chat's page with no New Tab context (`new`).
async function mount(kind: "spare" | "direct" | "new") {
  const { WORKED_SESSION } = await import("../src/agent-session/acpmux/mockFixture");
  if (kind === "spare") Object.assign(dom.window, { __cmuxNewTabContext: newTab });
  const ready =
    kind === "spare"
      ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac", newTab }
      : kind === "new"
        ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac" }
        : { protocolVersion: 1, transport: "mock", sessionId: WORKED_SESSION, machineName: "Mac" };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) =>
            Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? ready
                  : message.method === "newTab.context" && kind === "spare"
                    ? { newTab }
                    : // No place kept: the chat opens at its latest message.
                      message.method === "chat.scrollAnchor.get"
                      ? null
                      : undefined,
            }),
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

const rows = () => host.querySelectorAll(".acpmux-row[data-row-id]").length;
const dock = () => host.querySelector<HTMLElement>(".acpmux-dock");
const stage = () => host.querySelector<HTMLElement>(".acpmux-stage");
const shown = (element: HTMLElement | null) => element !== null && element.style.display !== "none";
const composerText = () =>
  (
    host.querySelector(".acpmux-composer-prompt") as { acpmuxMarkdownField?: { value(): string } } | null
  )?.acpmuxMarkdownField?.value() ?? "";
/// What the dock draws, the composer's chips (harness, model, mode) among it, without its own ids.
const dockText = () => (dock()?.textContent ?? "").replace(/\s+/g, " ").trim();

test("a spare holds the chat view hidden, and its adopt shows those nodes instead of building them", async () => {
  const session = await mount("spare");
  await until(() => host.querySelector(".nt-field") !== null, "the spare draws its New Tab page");
  // Built while the page is idle, before any adopt: hidden, under New Tab.
  await until(() => dock() !== null && stage() !== null, "the spare built the chat view");
  const builtDock = dock()!;
  const builtStage = stage()!;
  // The transcript too: the adopt draws the chat's rows into the scroller the spare built.
  const builtScroller = host.querySelector(".acpmux-scroll");
  expect(builtScroller, "the spare built the transcript").not.toBeNull();
  expect(shown(builtDock), "the built chat view is hidden while New Tab shows").toBe(false);
  expect(shown(builtStage)).toBe(false);
  expect(rows()).toBe(0);

  const { SESSION_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.CustomEvent(SESSION_ADOPT_EVENT, { detail: { sessionId: session, scrollAnchor: null } }),
    ),
  );
  // The adopt's own task left New Tab and showed the view it had: the same nodes, not new ones.
  expect(host.querySelector(".nt-field"), "New Tab left in the adopt's task").toBeNull();
  expect(dock(), "the adopt showed the dock the spare built").toBe(builtDock);
  expect(stage(), "the adopt showed the stage the spare built").toBe(builtStage);
  expect(shown(builtDock)).toBe(true);
  expect(shown(builtStage)).toBe(true);
  await until(() => rows() > 0, "the adopted chat draws its rows");
  expect(dock()).toBe(builtDock);
  expect(host.querySelector(".acpmux-scroll"), "the rows drew in the scroller the spare built").toBe(builtScroller);
}, 60_000);

test("the chat a spare took shows what the same chat opened directly shows", async () => {
  // The chat has a draft kept on this Mac: the empty view's composer must not stand in for it.
  const { cachePersistedDraft } = await import("../src/agent-session/acpmux/composerDraft");
  const { WORKED_SESSION } = await import("../src/agent-session/acpmux/mockFixture");
  cachePersistedDraft(WORKED_SESSION, "the chat's kept draft");
  await mount("direct");
  await until(() => rows() > 0 && composerText() !== undefined && dock() !== null, "the chat opens directly");
  await until(() => host.querySelector(".acpmux-composer-prompt [contenteditable]") !== null, "its composer");
  await tick();
  const direct = { dock: dockText(), composer: composerText() };
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  cachePersistedDraft(WORKED_SESSION, "the chat's kept draft");

  const session = await mount("spare");
  await until(() => dock() !== null && host.querySelector(".nt-field") !== null, "the spare built the chat view");
  const { SESSION_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.CustomEvent(SESSION_ADOPT_EVENT, { detail: { sessionId: session, scrollAnchor: null } }),
    ),
  );
  await until(() => rows() > 0, "the adopted chat draws its rows");
  await until(() => host.querySelector(".acpmux-composer-prompt [contenteditable]") !== null, "its composer");
  await until(() => dockText() === direct.dock, "the dock (composer chips: harness, model) is the chat's own");
  expect(dockText()).toBe(direct.dock);
  expect(composerText()).toBe(direct.composer);
}, 60_000);

test("a chat view that goes under a New Tab page (Cmd-T in the page) is built again, not kept", async () => {
  await mount("new");
  await until(() => host.querySelector(".acpmux-composer-prompt [contenteditable]") !== null, "the new chat's view");
  await until(
    () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions !== undefined,
    "the chat connects",
  );
  const typed = host.querySelector(".acpmux-composer-prompt") as {
    acpmuxMarkdownField?: { type(text: string): unknown };
  };
  await act(async () => void typed.acpmuxMarkdownField!.type("the first chat's draft"));
  await until(() => composerText() === "the first chat's draft", "the chat's draft");
  const chatDock = dock()!;
  const { NEW_TAB_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  await act(async () => dom.window.dispatchEvent(new dom.window.CustomEvent(NEW_TAB_ADOPT_EVENT, { detail: newTab })));
  await until(() => host.querySelector(".nt-field") !== null, "the New Tab page");
  // The hidden view under it is a new one: the chat's dock (its composer and draft) went with the chat.
  await until(() => dock() !== null, "the page built a chat view under it");
  expect(dock()).not.toBe(chatDock);
  expect(shown(dock())).toBe(false);
}, 60_000);

test("a spare parked drawn but invisible has run its chat view's effects before the adopt", async () => {
  // The visible park (App SPARE_PARK_VISIBLE): its effects run while parked, so the reveal runs none.
  // The composer's editor is made in an effect: it exists before the adopt only if they ran.
  Object.assign(dom.window, { __cmuxSparePark: "visible" });
  try {
    const session = await mount("spare");
    await until(() => host.querySelector(".nt-field") !== null, "the spare draws its New Tab page");
    await until(
      () => host.querySelector(".acpmux-composer-prompt [contenteditable]") !== null,
      "the parked composer's editor (made in an effect) exists before the adopt",
    );
    const editor = host.querySelector(".acpmux-composer-prompt [contenteditable]");
    expect(stage()?.style.visibility, "parked invisible").toBe("hidden");
    expect(stage()?.hasAttribute("inert"), "parked inert").toBe(true);
    const { SESSION_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
    await act(async () =>
      dom.window.dispatchEvent(
        new dom.window.CustomEvent(SESSION_ADOPT_EVENT, { detail: { sessionId: session, scrollAnchor: null } }),
      ),
    );
    expect(stage()?.style.visibility).not.toBe("hidden");
    expect(host.querySelector(".acpmux-composer-prompt [contenteditable]"), "the same editor").toBe(editor);
  } finally {
    delete (dom.window as unknown as { __cmuxSparePark?: unknown }).__cmuxSparePark;
  }
}, 60_000);
