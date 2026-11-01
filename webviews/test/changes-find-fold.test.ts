// Find in the changes view paints a range over each match in the rendered rows. A row's text is
// lowercased to find the matches, and `İ` lowercases to two characters, so every range after it
// started one character late; the find folds it to `i` first (src/find/fold.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "NodeFilter"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let container: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM(
    `<!doctype html><div id="view">
      <div data-line-type="context" data-line="1">İa needle</div>
      <div data-line-type="addition" data-line="2">İİ Needle here</div>
      <div data-line-type="addition" data-line="3">istanbul and İstanbul</div>
    </div>`,
  );
  Object.assign(scope, { window, document: window.document, NodeFilter: window.NodeFilter });
  container = window.document.getElementById("view")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("ranges after İ cover the matched text, and a plain i query finds İ", async () => {
  const { collectQueryRanges } = await import("../src/find/highlight");
  expect(collectQueryRanges(container, "needle", []).map((range) => range.toString())).toEqual(["needle", "Needle"]);
  expect(collectQueryRanges(container, "istanbul", []).map((range) => range.toString())).toEqual([
    "istanbul",
    "İstanbul",
  ]);
});
