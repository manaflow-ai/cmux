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
    open: host.querySelector<HTMLButtonElement>("button.cv-disclosure__open"),
    from: host.querySelector<HTMLElement>(".cv-received__from"),
    toggle: host.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!,
    opened,
  };
}

test("a peer lane, found by its bare name, opens from the chat identity control", async () => {
  const { open, from, toggle, opened } = await line({ name: "chief-ui" });
  expect(open?.getAttribute("aria-label")).toBe(t("subsession.openChat"));
  expect(from?.textContent).toBe("chief-ui");
  expect(from?.closest("button")).toBe(toggle);
  expect(host.querySelector(".cv-received__name")).toBeNull();
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-chief-ui"]);
  // Open chat leaves the message closed.
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
});

test("a chat on this Mac opens by the id its message gives", async () => {
  const { open, opened } = await line({ name: "coord-deputy", sessionId: "mux-deputy" });
  await act(async () => open!.click());
  expect(opened).toEqual(["mux-deputy"]);
});

test("a sender no list names has no Open chat: its line only opens the message", async () => {
  const { open, from, toggle, opened } = await line({ name: "gone-lane" });
  expect(open).toBeNull();
  expect(from?.textContent).toBe("gone-lane");
  await act(async () => toggle.click());
  expect(host.querySelector(".cv-received")?.getAttribute("data-open")).toBe("true");
  expect(opened).toEqual([]);
});

test("a mounted agent identity takes a late profile icon without a parent render", async () => {
  const { AgentIdentity } = await import("../src/agent-session/acpmux/subagents/AgentIdentity");
  const { rememberHarnessIcons } = await import("../src/agent-session/shared/harnessIcons");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <div>
        <span data-identity="unknown">
          <AgentIdentity harness="late-identity-profile" tone={2} />
        </span>
        <span data-identity="known-family">
          <AgentIdentity harness="claude-late-identity-profile" tone={3} />
        </span>
      </div>,
    ),
  );
  const unknown = host.querySelector('[data-identity="unknown"]')!;
  const known = host.querySelector('[data-identity="known-family"]')!;
  expect(unknown.querySelector('[data-agent-tone="2"]')).not.toBeNull();
  expect(known.querySelector(".agent-mark")).not.toBeNull();
  expect(known.querySelector("[data-agent-tone]")).toBeNull();
  await act(async () =>
    rememberHarnessIcons([
      { id: "late-identity-profile", iconSpec: { kind: "emoji", text: "🦊", source: "profile" } },
      { id: "claude-late-identity-profile", iconSpec: { kind: "emoji", text: "🦉", source: "profile" } },
    ]),
  );
  expect(unknown.textContent).toBe("🦊");
  expect(known.textContent).toBe("🦉");
  expect(unknown.querySelector("[data-agent-tone]")).toBeNull();
});
