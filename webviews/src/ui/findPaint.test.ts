// Find's fitted highlights follow a theme change (review F1 on cmux#37649): the fills are fit to the
// surfaces and colors of the theme they were painted in, so a switch from light to dark repaints
// them, as the `light-dark()` rules they replace would have followed by themselves.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { clearAdaptiveFind, paintAdaptiveFind } from "./findPaint";

const NAME = "test-find";
const colors = { match: "rgb(255, 199, 0)", current: "rgb(232, 130, 30)", currentInk: "rgb(26, 18, 8)" };

let dom: JSDOM | undefined;
const saved = {
  CSS: (globalThis as { CSS?: unknown }).CSS,
  Highlight: (globalThis as { Highlight?: unknown }).Highlight,
};
afterEach(() => {
  clearAdaptiveFind(NAME);
  dom?.window.close();
  dom = undefined;
  Object.assign(globalThis, saved);
});

test("a theme change repaints the fitted groups from the new surfaces", async () => {
  dom = new JSDOM(
    `<!doctype html><body style="background-color: rgb(255, 255, 255); color: rgb(29, 29, 31)"><p id="p">the library cache</p></body>`,
    {
      pretendToBeVisual: true,
    },
  );
  const doc = dom.window.document;
  const rules: string[][] = [];
  const registry = new Map<string, unknown>();
  Object.assign(globalThis, {
    CSS: { highlights: registry },
    Highlight: class {
      priority = 0;
      constructor(..._ranges: Range[]) {}
    },
  });
  const text = doc.getElementById("p")!.firstChild!;
  const range = doc.createRange();
  range.setStart(text, 4);
  range.setEnd(text, 11);
  const fills = () => [...registry.keys()].filter((key) => key.startsWith(`${NAME}-fit-`));
  paintAdaptiveFind(doc, NAME, colors, [range], [range]);
  rules.push(fills());
  expect(rules[0]!.length).toBe(1);

  // Dark: the host flips the page and announces it (window.cmuxTheme.apply fires `cmux-theme`).
  registry.clear();
  doc.body.style.backgroundColor = "rgb(20, 20, 20)";
  doc.body.style.color = "rgb(230, 230, 230)";
  dom.window.dispatchEvent(new dom.window.Event("cmux-theme"));
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(fills().length).toBe(1);
});

test("a cleared painter is not repainted by a later theme change", async () => {
  dom = new JSDOM(`<!doctype html><body><p id="p">library</p></body>`, { pretendToBeVisual: true });
  const doc = dom.window.document;
  const registry = new Map<string, unknown>();
  Object.assign(globalThis, {
    CSS: { highlights: registry },
    Highlight: class {
      priority = 0;
      constructor(..._ranges: Range[]) {}
    },
  });
  const range = doc.createRange();
  range.selectNodeContents(doc.getElementById("p")!);
  paintAdaptiveFind(doc, NAME, colors, [range], []);
  clearAdaptiveFind(NAME);
  dom.window.dispatchEvent(new dom.window.Event("cmux-theme"));
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect([...registry.keys()].filter((key) => key.startsWith(`${NAME}-fit-`))).toEqual([]);
});

test("the Markdown page's paper theme switch repaints, with no host event", async () => {
  // next-review F2 at e03f60d5: Reading Settings sets data-cmux-md-theme (settings.ts) and nothing else.
  dom = new JSDOM(`<!doctype html><body><p id="p">library</p></body>`, { pretendToBeVisual: true });
  const doc = dom.window.document;
  const registry = new Map<string, unknown>();
  Object.assign(globalThis, {
    CSS: { highlights: registry },
    Highlight: class {
      priority = 0;
      constructor(..._ranges: Range[]) {}
    },
  });
  const range = doc.createRange();
  range.selectNodeContents(doc.getElementById("p")!);
  paintAdaptiveFind(doc, NAME, colors, [range], []);
  registry.clear();
  doc.documentElement.dataset.cmuxMdTheme = "dark";
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect([...registry.keys()].filter((key) => key.startsWith(`${NAME}-fit-`)).length).toBe(1);
});
