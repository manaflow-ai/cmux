// Open chat on another agent's message line (conversation/IncomingMessageCard.tsx, the shared
// DisclosureRow's `.cv-disclosure__open`) goes to the sender's chat (Leo, ask-7325396234: "I THINK I
// WANNA BE ABLE TO CLICK ON THESE TO ACTUALLY GO TO THEM"): a click opens the sender by its acpmux
// id, a lane on a peer found by its bare name too. The sender's name is plain text on the line's
// toggle, never a button of its own; a sender no list names has no Open chat.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

const t = translatorFor("en");
const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
// A lane on huge-blue, listed here through the peer as `huge-blue/chief-ui`, and a chat on this Mac.
const sessions = [
  entry({ sessionId: "mux-chief-ui", name: "huge-blue/chief-ui", peer: "huge-blue" }),
  entry({ sessionId: "mux-deputy", name: "coord-deputy", hostKind: "local" }),
];

async function line(message: { name: string; sessionId?: string }) {
  const store = new SubsessionStore();
  store.set(sessions);
  const opened: string[] = [];
  const text = "Rebased; ready for review.";
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <IncomingMessageLine
          id="row-1"
          message={{ ...message, text, raw: text }}
          onOpen={(id) => void opened.push(id)}
        />
      </SubsessionContext.Provider>,
    ),
  );
  return {
    // The sender's name is the link to its chat (Leo, 2026-10-29: "just make the left side
    // identifier like it was before and you can click it to go to that session"); no Open chat.
    open: host.querySelector<HTMLButtonElement>("button.cv-received__from--open"),
    from: host.querySelector<HTMLElement>(".cv-received__from"),
    toggle: host.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!,
    opened,
  };
}

test("a peer lane, found by its bare name, opens from its name; no Open chat, the toggle apart", async () => {
  const { open, from, toggle, opened } = await line({ name: "chief-ui" });
  expect(host.querySelector(".cv-disclosure__open")).toBeNull();
  expect(host.textContent).not.toContain(t("subsession.openChat"));
  expect(from?.textContent).toBe("chief-ui");
  expect(open).toBe(from);
  expect(from?.closest("button.cv-disclosure__toggle")).toBeNull();
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-chief-ui"]);
  // The name leaves the message closed.
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
});

test("a chat on this Mac opens by the id its message gives", async () => {
  const { open, opened } = await line({ name: "coord-deputy", sessionId: "mux-deputy" });
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-deputy"]);
});

test("a sender no list names is plain text: its line only opens the message", async () => {
  const { open, from, toggle, opened } = await line({ name: "gone-lane" });
  expect(open).toBeNull();
  expect(from?.textContent).toBe("gone-lane");
  await act(async () => toggle.click());
  expect(host.querySelector(".cv-received")?.getAttribute("data-open")).toBe("true");
  expect(opened).toEqual([]);
});
