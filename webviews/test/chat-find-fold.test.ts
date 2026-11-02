// Find in Chat compares case-folded text, and a match's offset in it is its offset in what the page
// draws. `İ` (U+0130) lowercases to two code units, which moved every highlight after it one character
// (the drawn range started a character late, or ended mid-word).
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  NodeFilter: dom.window.NodeFilter,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { findMatches, foldFind, paintFindHighlights } =
  await import("../src/agent-session/acpmux/conversation/chatFind");

test("folding keeps every character's place", () => {
  const text = "İstanbul, ISTANBUL, ǅ, ß, Σ";
  expect(foldFind(text).length).toBe(text.length);
});

test("a match after an İ is drawn over exactly its text", () => {
  const host = dom.window.document.getElementById("root")!;
  host.innerHTML = '<div data-row-id="r1"><p>İstanbul and then Istanbul again</p></div>';
  const highlights = new Map<string, { ranges: Range[] }>();
  const saveCss = scope.CSS;
  const saveHighlight = scope.Highlight;
  Object.assign(scope, {
    CSS: {
      highlights: { set: (name: string, value: { ranges: Range[] }) => highlights.set(name, value), delete: () => {} },
    },
    Highlight: class {
      ranges: Range[];
      constructor(...ranges: Range[]) {
        this.ranges = ranges;
      }
    },
  });
  try {
    const current = paintFindHighlights(host, "istanbul", { rowId: "r1", card: false, occurrence: 1 });
    const others = highlights.get("acpmux-find")?.ranges ?? [];
    expect([...others, current!].map((range) => range.toString())).toEqual(["İstanbul", "Istanbul"]);
    expect(current!.toString()).toBe("Istanbul");
  } finally {
    Object.assign(scope, { CSS: saveCss, Highlight: saveHighlight });
  }
});

test("the transcript's matches count the same occurrences the page draws", () => {
  const rows = [{ id: "r1", version: 1, at: 0, kind: "assistant", text: "İstanbul and then Istanbul again" }];
  expect(findMatches(rows as never, "istanbul").length).toBe(2);
});
