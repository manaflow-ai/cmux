// Find in Chat opens a folded message from another agent that holds the current match
// (conversation/IncomingMessageCard.tsx, chatFind.ts FindReveal): the line is one disclosure, so its
// text is not drawn until opened, and a match only in the envelope opens Details too. A match for
// another row leaves it folded.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");

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

// The message's last paragraph, which only the opened panel draws; and the envelope Details hides.
const text = Array.from({ length: 12 }, (_, i) => `Paragraph ${i + 1} of the report.`).join("\n\n") + "\n\nzebra-tail";
const raw = `<cross-session-message from-name="grid-lane">\n${text}\n</cross-session-message>\nenvelope-only-word`;

async function draw(id: string, needle?: string) {
  let repaints = 0;
  root ??= createRoot(host);
  const reveal = needle ? { rowId: id, card: false, needle, repaint: () => void (repaints += 1) } : undefined;
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={reveal}>
        <IncomingMessageLine
          id={id}
          message={{ name: "grid-lane", sessionId: "mux-grid", text, raw }}
          onOpen={() => {}}
        />
      </FindReveal.Provider>,
    ),
  );
  return {
    repaints: () => repaints,
    toggle: () => host.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!,
  };
}

test("a Find match in a folded message opens it, so the match is drawn and highlighted", async () => {
  const closed = await draw("find-1");
  expect(closed.toggle().getAttribute("aria-expanded")).toBe("false");
  expect(host.textContent).not.toContain("zebra-tail");
  const found = await draw("find-1", "zebra-tail");
  expect(found.toggle().getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__text")?.textContent).toContain("zebra-tail");
  expect(found.repaints()).toBeGreaterThan(0);
});

test("a Find match only in the envelope opens the message and its Details", async () => {
  await draw("find-2", "envelope-only-word");
  expect(host.querySelector(".cv-received__more")?.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__details pre")?.textContent).toContain("envelope-only-word");
});

test("a Find match for another row leaves the message folded", async () => {
  await draw("find-3");
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={{ rowId: "other-row", card: false, needle: "zebra-tail", repaint: () => {} }}>
        <IncomingMessageLine
          id="find-3"
          message={{ name: "grid-lane", sessionId: "mux-grid", text, raw }}
          onOpen={() => {}}
        />
      </FindReveal.Provider>,
    ),
  );
  expect(host.querySelector("button.cv-disclosure__toggle")?.getAttribute("aria-expanded")).toBe("false");
});

test("the panel has no From header: the line names the sender once", async () => {
  await draw("find-4", "zebra-tail");
  expect(host.querySelector(".cv-received__from-line")).toBeNull();
});
