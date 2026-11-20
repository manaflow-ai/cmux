// Find in Chat opens a folded message from another agent that holds the current match
// (conversation/IncomingMessageCard.tsx, chatFind.ts FindReveal): the line is one disclosure, so its
// text is not drawn until opened, and a match only in the envelope opens Details too. A match for
// another row leaves it folded.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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
  NodeFilter: dom.window.NodeFilter,
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
const { FindReveal, findMatches, paintFindHighlights } =
  await import("../src/agent-session/acpmux/conversation/chatFind");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
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
    toggle: () => host.querySelector<HTMLButtonElement>("button.cv-agentmsg__toggle")!,
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
  expect(host.querySelector("button.cv-agentmsg__toggle")?.getAttribute("aria-expanded")).toBe("false");
});

test("the panel has no From header: the line names the sender once", async () => {
  await draw("find-4", "zebra-tail");
  expect(host.querySelector(".cv-received__from-line")).toBeNull();
});

// Find counts a received message's text only (chatFind.ts rowText), so its line (the sender's chip,
// its machine, the first line) adds no matches: the line DisclosureRow drew skipped Find whole, and
// the one message row's line does too (cmux#37653 review). Else a sender named like the query took
// the first match and the message's second occurrence never became the current one.
test("Find matches a received message's text, never its sender's line", async () => {
  const body = "grid first. grid second.";
  const id = "find-5";
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={{ rowId: id, card: false, needle: "grid", repaint: () => {} }}>
        <div data-row-id={id}>
          <IncomingMessageLine
            id={id}
            message={{ name: "grid-lane", sessionId: "mux-grid", text: body, raw: body }}
            onOpen={() => {}}
          />
        </div>
      </FindReveal.Provider>,
    ),
  );
  expect(host.querySelector(".cv-agentmsg__line")?.textContent).toContain("grid-lane");
  // The index: two matches, both in the message's text.
  const matches = findMatches([{ id, kind: "user", text: body } as never], "grid");
  expect(matches.map(({ occurrence }) => occurrence)).toEqual([0, 1]);
  // A stand-in for WebKit's CSS highlight registry.
  const set = new Map<string, unknown>();
  const css = (globalThis as Record<string, unknown>).CSS;
  const highlight = (globalThis as Record<string, unknown>).Highlight;
  Object.assign(globalThis, {
    CSS: { highlights: { set: (name: string, value: unknown) => set.set(name, value), delete: () => {} } },
    Highlight: class {
      constructor(...ranges: Range[]) {
        Object.assign(this, { ranges });
      }
    },
  });
  try {
    const card = host.querySelector(".cv-received__text")!;
    const second = paintFindHighlights(host, "grid", { rowId: id, card: false, occurrence: 1 });
    // The second match is the message's second "grid".
    expect(second).toBeDefined();
    expect(card.contains(second!.startContainer)).toBe(true);
    const before = second!.cloneRange();
    before.setStart(card, 0);
    expect(before.toString()).toContain("grid first. ");
    // Every drawn match is in the message's text: none on the line.
    const all = [...((set.get("acpmux-find") as { ranges: Range[] } | undefined)?.ranges ?? []), second!];
    expect(all.every((range) => card.contains(range.startContainer))).toBe(true);
    expect(all.length).toBe(2);
  } finally {
    Object.assign(globalThis, { CSS: css, Highlight: highlight });
  }
});
