// LaTeX in agent replies (Lawrence 10-14, "native LaTeX support"): `$…$`, `\(…\)`, `$$…$$` and
// `\[…\]` typeset by KaTeX; prices and shell text never become math; a reply without math never
// loads KaTeX; and a selection copies an equation as the TeX it was written in.
import { afterAll, expect, test } from "bun:test";
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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const window = dom.window;
const host = window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");

const katexLoaded = () => Object.keys(require.cache).some((file) => file.includes("node_modules/katex/"));
const settle = async () => {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
};

/// Draws `source`, then yields until no equation waits for KaTeX (its source shows until the chunk
/// has run). Fails after 5 s.
async function show(source: string) {
  root ??= createRoot(host);
  await act(async () => root!.render(<Markdown>{source}</Markdown>));
  const deadline = performance.now() + 5_000;
  while (host.querySelector(".cv-math-source")) {
    if (performance.now() > deadline) throw new Error("timed out waiting for KaTeX");
    await settle();
  }
}

const PRICES_AND_SHELL: [source: string, shown: string][] = [
  ["It costs $5 and $10 after tax.", "It costs $5 and $10 after tax."],
  ["Plans run $5-$10 a month.", "Plans run $5-$10 a month."],
  ["Between $1,000 and $2,000.", "Between $1,000 and $2,000."],
  ["Prices: $5/$10/$20.", "Prices: $5/$10/$20."],
  ["US$5 vs US$10", "US$5 vs US$10"],
  ["cost:$5,cap:$10", "cost:$5,cap:$10"],
  ["Set $HOME and $PATH first.", "Set $HOME and $PATH first."],
  ["Run echo $$ and $$ to see the PID.", "Run echo $$ and $$ to see the PID."],
  [
    "The runner costs $5 and $10 an hour, and echo $$ prints the PID.",
    "The runner costs $5 and $10 an hour, and echo $$ prints the PID.",
  ],
  // Prose between two shell `$$` (an apostrophe, a comma) is still prose (the DEV capture's reply).
  [
    "echo $$ prints the shell's PID, and echo $$ and $$ print it twice.",
    "echo $$ prints the shell's PID, and echo $$ and $$ print it twice.",
  ],
  ["Escaped \\$5 and \\$10.", "Escaped $5 and $10."],
  ["Use `$x$` literally.", "Use $x$ literally."],
];

test("a reply without math never loads KaTeX", async () => {
  await show(PRICES_AND_SHELL.map(([source]) => source).join("\n\n"));
  // Only an equation drawn loads KaTeX, and an equation shows its source at once while it does: with
  // none in the document after the reply rendered, nothing started the load.
  await settle();
  expect(host.querySelector(".cv-math, .cv-math-source")).toBeNull();
  expect(katexLoaded()).toBe(false);
});

test("prices, shell variables and escaped dollars stay text", async () => {
  for (const [source, shown] of PRICES_AND_SHELL) {
    await show(source);
    expect({ source, math: host.querySelectorAll(".cv-math, .cv-math-source").length }).toEqual({ source, math: 0 });
    expect(host.textContent).toBe(shown);
  }
});

test("each delimiter typesets once math appears", async () => {
  const cases: [source: string, tex: string[], display: boolean][] = [
    ["Area is $\\pi r^2$ here.", ["\\pi r^2"], false],
    ["So \\(a+b\\) holds.", ["a+b"], false],
    ["Half: $\\frac{1}{2}$ of it.", ["\\frac{1}{2}"], false],
    ["$$E=mc^2$$", ["E=mc^2"], true],
    ["\\[\n\\int_0^1 x\\,dx\n\\]", ["\\int_0^1 x\\,dx"], true],
    ["Inline $$a^2+b^2$$ display.", ["a^2+b^2"], true],
    ["The energy is $$ E = mc^2 $$ here.", ["E = mc^2"], true],
  ];
  for (const [source, tex, display] of cases) {
    await show(source);
    const drawn = [...host.querySelectorAll<HTMLElement>("[data-tex]")];
    expect({ source, tex: drawn.map((el) => el.dataset.tex) }).toEqual({ source, tex });
    expect({ source, katex: drawn.every((el) => el.querySelector(".katex")) }).toEqual({ source, katex: true });
    expect({ source, display: drawn.every((el) => !!el.querySelector(".katex-display")) }).toEqual({ source, display });
  }
  expect(katexLoaded()).toBe(true);
});

let copiedHtml: string | undefined;
function copySelection(): string | undefined {
  const data = new Map<string, string>();
  const event = new window.Event("copy", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { setData: (type: string, value: string) => data.set(type, value) },
  });
  window.document.getSelection()!.anchorNode!.parentElement!.dispatchEvent(event);
  copiedHtml = data.get("text/html");
  return event.defaultPrevented ? data.get("text/plain") : undefined;
}

test("a selection copies its equations as their TeX", async () => {
  await show("Area is $\\pi r^2$ here.\n\n$$\nE=mc^2\n$$\n\nDone.");
  const paragraphs = host.querySelectorAll(".cv-p");
  const selection = window.document.getSelection()!;
  const range = window.document.createRange();
  range.setStart(paragraphs[0]!.firstChild!, 0);
  range.setEnd(paragraphs[1]!.lastChild!, paragraphs[1]!.lastChild!.textContent!.length);
  selection.removeAllRanges();
  selection.addRange(range);
  expect(copySelection()).toBe("Area is $\\pi r^2$ here.\n$$E=mc^2$$\nDone.");
  // The HTML copy keeps the paragraphs, with each equation as its source.
  expect(copiedHtml).toContain("<p");
  expect(copiedHtml).toContain("$\\pi r^2$");
  expect(copiedHtml).not.toContain("katex");

  // A selection that starts inside an equation takes the whole equation.
  const glyph = host.querySelector(".cv-math .katex-html")!;
  const inside = window.document.createTreeWalker(glyph, 4).nextNode()!;
  range.setStart(inside, 0);
  range.setEnd(paragraphs[0]!.lastChild!, paragraphs[0]!.lastChild!.textContent!.length);
  selection.removeAllRanges();
  selection.addRange(range);
  expect(copySelection()).toBe("$\\pi r^2$ here.");

  // Text with no math copies as the page would copy it.
  range.selectNodeContents(paragraphs[1]!);
  selection.removeAllRanges();
  selection.addRange(range);
  expect(copySelection()).toBeUndefined();
});
