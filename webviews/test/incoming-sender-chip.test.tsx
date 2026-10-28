// The sender chip of another agent's message (conversation/IncomingMessageCard.tsx) goes to that
// chat (Leo, ask-7325396234: "I THINK I WANNA BE ABLE TO CLICK ON THESE TO ACTUALLY GO TO THEM"):
// a click opens the sender by its acpmux id, a lane on a peer found by its bare name too, and the
// tooltip names the chat and the other machine it runs on.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { IncomingMessage } from "../src/agent-session/acpmux/conversation/incomingMessage";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
const { WaitingMessagesCard } = await import("../src/agent-session/acpmux/conversation/WaitingMessagesCard");

const t = translatorFor("en");
const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
// A lane on huge-blue, listed here through the peer as `huge-blue/chief-ui`, and a chat on this Mac.
const sessions = [
  entry({ sessionId: "mux-chief-ui", name: "huge-blue/chief-ui", peer: "huge-blue" }),
  entry({ sessionId: "mux-deputy", name: "coord-deputy", hostKind: "local" }),
];

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
            id="row-1"
            message={{ ...message, text, raw: text }}
            onOpen={(id) => void opened.push(id)}
          />
        </PromptMarksSession.Provider>
      </SubsessionContext.Provider>,
    ),
  );
  return { chip: host.querySelector<HTMLButtonElement>("button.cv-received__name"), opened };
}

test("a peer lane's chip, found by its bare name, opens it and names its machine", async () => {
  const { chip, opened } = await line({ name: "chief-ui" });
  expect(chip?.querySelector(".acpmux-sender__name")?.textContent).toBe("chief-ui");
  expect(chip?.title).toBe("Open chief-ui (huge-blue)");
  expect(chip?.getAttribute("aria-label")).toBe(t("subagents.openOnHost", { name: "chief-ui", host: "huge-blue" }));
  await act(async () => chip!.click());
  expect(opened).toEqual(["mux-chief-ui"]);
});

test("a chat on this Mac opens by the id its message gives, its tooltip naming no machine", async () => {
  const { chip, opened } = await line({ name: "coord-deputy", sessionId: "mux-deputy" });
  expect(chip?.title).toBe("Open coord-deputy");
  await act(async () => chip!.click());
  expect(opened).toEqual(["mux-deputy"]);
});

test("a sender no list names is no button: nothing to open", async () => {
  const { chip } = await line({ name: "gone-lane" });
  expect(chip).toBeNull();
  expect(host.querySelector(".cv-received__name.is-plain")?.textContent).toBe("gone-lane");
});

const remote = entry({
  sessionId: "remote-review",
  name: "gcp-codex-lane-10/pr-row",
  peer: "gcp-codex-lane-10",
  harness: "codex",
  startedBy: "viewer",
});

test("a qualified remote sender uses its session headline in the chip, relation label and tooltip", async () => {
  const { chip, opened } = await line({ name: remote.name!, sessionId: remote.sessionId, relation: "parent" }, [
    remote,
  ]);
  expect(chip?.querySelector(".acpmux-sender__name")?.textContent).toBe("Parent · pr-row");
  expect(chip?.querySelector(".acpmux-sender__host")?.textContent).toBe("gcp-codex-lane-10");
  expect(chip?.title).toBe("Open pr-row (gcp-codex-lane-10)");
  expect(chip?.getAttribute("aria-label")).toBe("Open pr-row (gcp-codex-lane-10)");
  expect(host.querySelector(".cv-received__toggle")?.getAttribute("aria-label")).toBe(
    t("message.label", { from: "Parent · pr-row", to: t("message.self") }),
  );
  await act(async () => chip!.click());
  expect(opened).toEqual([remote.sessionId]);
});

test("a sender found only by its name gains no child relationship", async () => {
  const { chip } = await line({ name: remote.name! }, [remote]);
  expect(chip?.querySelector(".acpmux-sender__name")?.textContent).toBe("pr-row");
  expect(chip?.textContent).not.toContain("Sub-session");
  expect(chip?.title).toBe("Open pr-row (gcp-codex-lane-10)");
});

test("a batched peer message card uses canonical sender headlines and secondary hosts", async () => {
  const store = new SubsessionStore();
  store.set([remote]);
  const message = { name: remote.name!, sessionId: remote.sessionId, text: "Ready.", raw: "Ready." };
  const rows = [1, 2].map((index) => ({ id: `queued-${index}`, incoming: { kind: "message", message } }) as AcpmuxRow);
  const row = { id: "batch", waiting: { delivery: "turn", rows } } as AcpmuxRow;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <WaitingMessagesCard row={row} renderMessage={() => null} />
      </SubsessionContext.Provider>,
    ),
  );
  expect(host.querySelectorAll(".cv-waiting__sender")).toHaveLength(1);
  expect(host.querySelector(".cv-waiting__sender .acpmux-sender__name")?.textContent).toBe("pr-row");
  expect(host.querySelector(".cv-waiting__sender .acpmux-sender__host")?.textContent).toBe("gcp-codex-lane-10");
  expect(host.querySelector(".cv-waiting__toggle")?.getAttribute("title")).toBe("pr-row (gcp-codex-lane-10)");
});
