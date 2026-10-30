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
import type { IncomingMessage } from "../src/agent-session/acpmux/conversation/incomingMessage";

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
const { PromptMarksSession } = await import("../src/agent-session/acpmux/threadMinimap/promptMarks");

const t = translatorFor("en");
const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
// A lane on huge-blue, listed here through the peer as `huge-blue/chief-ui`, and a chat on this Mac.
const sessions = [
  entry({ sessionId: "mux-chief-ui", name: "huge-blue/chief-ui", peer: "huge-blue" }),
  entry({ sessionId: "mux-deputy", name: "coord-deputy", hostKind: "local" }),
];

let nextMessageId = 0;

async function line(
  message: Pick<IncomingMessage, "name" | "sessionId" | "relation">,
  entries = sessions,
  viewer = "viewer",
) {
  const store = new SubsessionStore();
  store.set(entries);
  const opened: string[] = [];
  const text = "Rebased; ready for review.";
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <PromptMarksSession.Provider value={viewer}>
          <IncomingMessageLine
            id={`row-${++nextMessageId}`}
            message={{ ...message, text, raw: text }}
            onOpen={(id) => void opened.push(id)}
          />
        </PromptMarksSession.Provider>
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

test("a peer lane, found by its bare name, opens from Open chat; its name is plain text on the toggle", async () => {
  const { open, from, toggle, opened } = await line({ name: "chief-ui" });
  expect(open?.textContent).toBe(t("subsession.openChat"));
  expect(from?.querySelector(".acpmux-sender__name")?.textContent).toBe("chief-ui");
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

const remote = entry({
  sessionId: "remote-review",
  name: "gcp-codex-lane-10/pr-row",
  peer: "gcp-codex-lane-10",
  harness: "codex",
  startedBy: "viewer",
});

test("a qualified remote sender uses its session headline in the disclosure, relation label and tooltip", async () => {
  const { open, from, toggle, opened } = await line(
    { name: remote.name!, sessionId: remote.sessionId, relation: "parent" },
    [remote],
  );
  expect(from?.querySelector(".acpmux-sender__name")?.textContent).toBe("Parent · pr-row");
  expect(from?.querySelector(".acpmux-sender__host")?.textContent).toBe("gcp-codex-lane-10");
  expect(open?.title).toBe("Open pr-row (gcp-codex-lane-10)");
  expect(toggle.getAttribute("aria-label")).toBe(
    t("message.collapsedLabel", { from: "Parent · pr-row", preview: "Rebased; ready for review." }),
  );
  await act(async () => toggle.click());
  expect(host.querySelector(".cv-received__from-line")?.textContent).toBe(
    t("message.fromHeader", { name: "Parent · pr-row" }),
  );
  await act(async () => open!.click());
  expect(opened).toEqual([remote.sessionId]);
});

test("a sender found only by its name gains no child relationship", async () => {
  const { open, from } = await line({ name: remote.name! }, [remote]);
  expect(from?.querySelector(".acpmux-sender__name")?.textContent).toBe("pr-row");
  expect(from?.textContent).not.toContain("Sub-session");
  expect(open?.title).toBe("Open pr-row (gcp-codex-lane-10)");
});

test("consecutive peer messages keep independent disclosures with canonical senders and secondary hosts", async () => {
  const store = new SubsessionStore();
  store.set([remote]);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        {[1, 2].map((index) => (
          <IncomingMessageLine
            key={index}
            id={`received-${index}`}
            message={{
              name: remote.name!,
              sessionId: remote.sessionId,
              text: `Report ${index}`,
              raw: `Report ${index}`,
            }}
            onOpen={() => undefined}
          />
        ))}
      </SubsessionContext.Provider>,
    ),
  );
  expect(host.querySelectorAll(".cv-received")).toHaveLength(2);
  expect(
    Array.from(host.querySelectorAll(".cv-received__from .acpmux-sender__name"), (node) => node.textContent),
  ).toEqual(["pr-row", "pr-row"]);
  expect(
    Array.from(host.querySelectorAll(".cv-received__from .acpmux-sender__host"), (node) => node.textContent),
  ).toEqual(["gcp-codex-lane-10", "gcp-codex-lane-10"]);
  const toggles = host.querySelectorAll<HTMLButtonElement>(".cv-disclosure__toggle");
  await act(async () => toggles[1]!.click());
  expect(toggles[0]!.getAttribute("aria-expanded")).toBe("false");
  expect(toggles[1]!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__text")?.textContent).toBe("Report 2");
});
