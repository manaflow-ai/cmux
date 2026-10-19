import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  collectFindPaintRanges,
  collectOpenShadowRoots,
} from "../src/find/highlight";
import type { FindMatch } from "../src/find/model";

const originalGlobals = new Map<string, any>();
for (const key of ["document", "window", "NodeFilter"]) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(() => {
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

function setupDOM() {
  const dom = new JSDOM("<!doctype html><html><body><main id=\"viewer\"></main></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).NodeFilter = dom.window.NodeFilter;
  return dom.window.document;
}

type RowSpec = {
  lineType: string;
  line: number;
  altLine?: number;
  gutterText: string;
  codeTokens: string[];
};

/**
 * Mimics the code view's structure: a light-DOM host element per file with
 * an OPEN shadow root, sibling number cells carrying data-column-number,
 * and code cells carrying data-line/data-alt-line with the code text split
 * across token spans.
 */
function appendShadowFile(container: Element, rows: RowSpec[]): ShadowRoot {
  const host = document.createElement("diffs-container");
  container.appendChild(host);
  const shadow = host.attachShadow({ mode: "open" });
  for (const spec of rows) {
    // Separate line-number cell, like the code view renders: it carries
    // data-column-number and digits-only text, and must never be searched.
    const numberCell = document.createElement("div");
    numberCell.setAttribute("data-line-type", spec.lineType);
    numberCell.setAttribute("data-column-number", String(spec.line));
    numberCell.textContent = spec.gutterText;
    shadow.appendChild(numberCell);
    const row = document.createElement("div");
    row.setAttribute("data-line-type", spec.lineType);
    row.setAttribute("data-line", String(spec.line));
    if (spec.altLine != null) {
      row.setAttribute("data-alt-line", String(spec.altLine));
    }
    for (const token of spec.codeTokens) {
      const span = document.createElement("span");
      span.textContent = token;
      row.appendChild(span);
    }
    shadow.appendChild(row);
  }
  return shadow;
}

const activeMatch: FindMatch = {
  itemId: "a.txt",
  side: "additions",
  lineNumber: 2,
  start: 0,
  length: 6,
  occurrence: 0,
  lineText: "needle CHANGED needle",
};

test("collectOpenShadowRoots finds nested open shadow roots", () => {
  const document = setupDOM();
  const container = document.getElementById("viewer")!;
  const first = appendShadowFile(container, []);
  const nestedHost = document.createElement("div");
  first.appendChild(nestedHost);
  nestedHost.attachShadow({ mode: "open" });
  appendShadowFile(container, []);

  expect(collectOpenShadowRoots(container).length).toBe(3);
});

test("collectFindPaintRanges highlights matches inside shadow rows, skipping gutters", () => {
  const document = setupDOM();
  const container = document.getElementById("viewer") as HTMLElement;
  appendShadowFile(container, [
    // Token boundary splits the word: "nee" + "dle CHANGED needle".
    { lineType: "change-addition", line: 2, gutterText: "2", codeTokens: ["nee", "dle CHANGED needle"] },
    { lineType: "change-deletion", line: 2, gutterText: "2", codeTokens: ["old needle text"] },
    // A number cell whose text contains the query must not be highlighted.
    { lineType: "context", line: 3, altLine: 3, gutterText: "needle", codeTokens: ["no match here"] },
  ]);

  const { matchRanges, activeRanges } = collectFindPaintRanges(container, {
    query: "needle",
    active: activeMatch,
    activeItemSpan: null,
  });

  // Addition row: 2 occurrences (first is the active match, cross-token);
  // deletion row: 1 occurrence; gutter occurrence excluded.
  expect(activeRanges.length).toBe(1);
  expect(matchRanges.length).toBe(2);
  expect(activeRanges[0].toString()).toBe("needle");
  expect(matchRanges.every((range) => range.toString().toLowerCase() === "needle")).toBe(true);
});

test("collectFindPaintRanges respects the active side when line numbers collide", () => {
  const document = setupDOM();
  const container = document.getElementById("viewer") as HTMLElement;
  appendShadowFile(container, [
    { lineType: "change-deletion", line: 2, gutterText: "2", codeTokens: ["needle on deletions"] },
    { lineType: "change-addition", line: 2, gutterText: "2", codeTokens: ["needle on additions"] },
  ]);

  const deletionActive: FindMatch = { ...activeMatch, side: "deletions" };
  const { activeRanges } = collectFindPaintRanges(container, {
    query: "needle",
    active: deletionActive,
    activeItemSpan: null,
  });

  expect(activeRanges.length).toBe(1);
  expect(activeRanges[0].startContainer.textContent).toBe("needle on deletions");
});

test("collectFindPaintRanges returns nothing for an empty query", () => {
  const document = setupDOM();
  const container = document.getElementById("viewer") as HTMLElement;
  appendShadowFile(container, [
    { lineType: "context", line: 1, altLine: 1, gutterText: "1", codeTokens: ["needle"] },
  ]);
  const { matchRanges, activeRanges } = collectFindPaintRanges(container, {
    query: "",
    active: null,
    activeItemSpan: null,
  });
  expect(matchRanges.length).toBe(0);
  expect(activeRanges.length).toBe(0);
});
