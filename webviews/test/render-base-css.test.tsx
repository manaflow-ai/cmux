// A rendered page gets the pane's theme and a cmux base stylesheet: the card hands its render frame
// the `--cmux-*` variables and plain defaults (renderBase.ts), the frame puts them first in the
// page's head (AgentPaneRenderFrame.swift), and anything the page styles itself wins. The frame's
// page is drawn here in happy-dom, which resolves var() and :where() like the pane's WebKit.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

// The agent page on the page host's WebKit, the one page that frames renders.
const dom = new JSDOM('<!doctype html><html data-engine="webkit"><div id=root></div></html>', {
  url: "cmux-page://cmux.agent/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const LIGHT = {
  isDark: false,
  pageBackground: "rgb(250, 250, 250)",
  surfaceBackground: "rgb(240, 240, 240)",
  border: "rgb(220, 220, 220)",
  text: "rgb(20, 20, 20)",
  mutedText: "rgb(110, 110, 110)",
  accent: "rgb(0, 90, 200)",
};
const DARK = {
  ...LIGHT,
  isDark: true,
  pageBackground: "rgb(24, 24, 24)",
  surfaceBackground: "rgb(36, 36, 36)",
  border: "rgb(60, 60, 60)",
  text: "rgb(236, 236, 236)",
  mutedText: "rgb(150, 150, 150)",
};

const PAGE = [
  "<title>Report</title><h1>Build times</h1><p>Median <code>4.2 s</code></p>",
  "<table><tr><th>Lane</th></tr><tr><td>fast</td></tr></table><button>Rerun</button>",
].join("");

/// Draws a render card under `theme`, runs it, and returns what the card hands its frame.
async function frameMessage(theme: typeof LIGHT, html: string): Promise<{ html: string; css: string }> {
  const { createRoot } = await import("react-dom/client");
  const { RenderCard, ranRenders } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  applyAgentTheme(theme as never);
  ranRenders.clear();
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<RenderCard call={{ html, title: "Report" }} />));
  act(() => [...host.querySelectorAll("button")].find((element) => element.textContent === "Run")!.click());
  const frame = host.querySelector("iframe")!.contentWindow!;
  const sent: unknown[] = [];
  frame.postMessage = ((message: unknown) => sent.push(message)) as never;
  // The frame document asks for its page once it loads.
  const ready = new Event("message") as MessageEvent;
  Object.defineProperties(ready, { data: { value: { type: "cmux-render-ready" } }, source: { value: frame } });
  act(() => {
    globalThis.dispatchEvent(ready);
  });
  expect(sent).toHaveLength(1);
  return sent[0] as { html: string; css: string };
}

/// The frame's page, as AgentPaneRenderFrame.swift builds it: the HTML, then the card's styles first in its head.
function framePage(message: { html: string; css: string }) {
  const page = new Window();
  page.document.write(message.html);
  const theme = page.document.createElement("style");
  theme.textContent = message.css;
  page.document.head.insertBefore(theme, page.document.head.firstChild);
  const style = (selector: string) => page.getComputedStyle(page.document.querySelector(selector)!);
  return { page, style, root: page.getComputedStyle(page.document.documentElement) };
}

test("a rendered page sees the theme's --cmux-* variables and cmux's plain defaults", async () => {
  const { root: vars, style } = framePage(await frameMessage(LIGHT, PAGE));
  expect(vars.getPropertyValue("--cmux-text").trim()).toBe(LIGHT.text);
  expect(vars.getPropertyValue("--cmux-muted").trim()).toBe(LIGHT.mutedText);
  expect(vars.getPropertyValue("--cmux-card").trim()).toBe(LIGHT.surfaceBackground);
  expect(vars.getPropertyValue("--cmux-border").trim()).toBe(LIGHT.border);
  expect(vars.getPropertyValue("--cmux-accent").trim()).toBe(LIGHT.accent);
  for (const name of [
    "--cmux-bg",
    "--cmux-font",
    "--cmux-mono",
    "--cmux-size-body",
    "--cmux-size-heading",
    "--cmux-radius",
    "--cmux-space-2",
  ])
    expect(vars.getPropertyValue(name).trim()).not.toBe("");
  // The page itself is see-through, so the card's surface shows, and reads in the theme's text.
  expect(style("html").backgroundColor).toMatch(/transparent|rgba\(0, 0, 0, 0\)/);
  expect(style("body").color).toBe(LIGHT.text);
  expect(style("body").fontSize).toBe("13px");
  // Headings, tables, code and buttons get the pane's scale and controls.
  expect(style("h1").fontSize).toBe("17px");
  expect(style("th").color).toBe(LIGHT.mutedText);
  expect(style("td").borderBottomStyle).toBe("solid");
  expect(style("code").fontFamily).toContain("monospace");
  expect(style("button").minHeight).toBe("26px");
});

test("a page's own styles win over the base stylesheet", async () => {
  const own =
    "<style>*{margin:0}body{color:rgb(1, 2, 3);font-size:15px}h1{font-size:30px}button{height:40px}</style>" + PAGE;
  const { style } = framePage(await frameMessage(LIGHT, own));
  expect(style("body").color).toBe("rgb(1, 2, 3)");
  expect(style("body").fontSize).toBe("15px");
  expect(style("h1").fontSize).toBe("30px");
  expect(style("h1").marginBottom).toBe("0px");
  expect(style("button").height).toBe("40px");
  // Even a page rule with no specificity at all (`*`) wins: every base rule adds none.
  const { page } = framePage(await frameMessage(LIGHT, PAGE));
  const base = page.document.head.querySelector("style")!.sheet!;
  const selectors = [...base.cssRules].map((rule) => (rule as unknown as { selectorText: string }).selectorText);
  // The variables too, so a page's `html{--cmux-text:…}` or `html{color-scheme:…}` wins over `:root`.
  expect(selectors[0]).toBe(":where(:root)");
  for (const selector of selectors) expect(selector).toMatch(/^:where\([^]*\)$/);
  const ownRoot = "<style>html{--cmux-text:rgb(5, 5, 5);color-scheme:light}</style>" + PAGE;
  const { root: vars, style: ownStyle } = framePage(await frameMessage(DARK, ownRoot));
  expect(vars.getPropertyValue("--cmux-text").trim()).toBe("rgb(5, 5, 5)");
  expect(vars.getPropertyValue("color-scheme").trim()).toBe("light");
  expect(ownStyle("body").color).toBe("rgb(5, 5, 5)");
});

test("a full-bleed page fills the frame, and a plain page starts inset", async () => {
  // A three.js scene sizes its canvas to innerWidth x innerHeight under `body{margin:0}`.
  const scene = "<style>body{margin:0}canvas{display:block}</style><canvas></canvas>";
  const { page, style } = framePage(await frameMessage(LIGHT, scene));
  const body = style("body");
  // An unset padding reads "" here; the page's default is none.
  const px = (value: string) => parseFloat(value || "0");
  const inset = (box: ReturnType<typeof style>) =>
    [
      "marginTop",
      "marginRight",
      "marginBottom",
      "marginLeft",
      "paddingTop",
      "paddingRight",
      "paddingBottom",
      "paddingLeft",
    ].map((side) => px(box.getPropertyValue(side.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`))));
  expect(page.innerWidth - px(body.paddingLeft) - px(body.paddingRight)).toBe(page.innerWidth);
  expect(inset(body)).toEqual([0, 0, 0, 0, 0, 0, 0, 0]);
  // A page with no CSS of its own starts inset from the card's edges, by margin, not padding.
  const plain = framePage(await frameMessage(LIGHT, PAGE)).style("body");
  expect(inset(plain)).toEqual([12, 14, 12, 14, 0, 0, 0, 0]);
});

test("the base never changes the layout or colors a page set itself", async () => {
  const styled =
    "<style>.card{width:340px;padding:20px;border-radius:12px;background:rgb(109, 40, 217);color:rgb(255, 255, 255)}" +
    ".card button{padding:10px;border:0;background:rgb(255, 255, 255);color:rgb(109, 40, 217)}.card small{opacity:0.7}</style>" +
    '<div class="card"><b>$20</b><small>/month</small><button>Choose Pro</button></div>';
  const plain = framePage({ html: styled, css: "" });
  const based = framePage(await frameMessage(LIGHT, styled));
  const read = (frame: typeof plain, selector: string) => {
    const box = frame.style(selector);
    return {
      boxSizing: box.boxSizing,
      width: box.width,
      height: box.height,
      display: box.display,
      padding: box.padding,
      color: box.color,
      opacity: box.opacity,
    };
  };
  // Controls get only a minimum height (26px), under a padded button's own.
  for (const selector of [".card", ".card button", ".card small", ".card b"])
    expect([selector, read(based, selector)]).toEqual([selector, read(plain, selector)]);
});

test("a page without a doctype keeps its tables at the body's text size", async () => {
  // Quirks mode resets a table's font size and line height to the browser's (16px, normal); the
  // base has the table inherit the body's. happy-dom lets no `inherit` override an earlier value,
  // so this reads the base's own table rule.
  const { page } = framePage(await frameMessage(LIGHT, PAGE));
  const base = page.document.head.querySelector("style")!.sheet!;
  const table = [...base.cssRules].find(
    (rule) => (rule as unknown as { selectorText: string }).selectorText === ":where(table)",
  ) as unknown as { style: { getPropertyValue(name: string): string } };
  expect([table.style.getPropertyValue("font-size"), table.style.getPropertyValue("line-height")]).toEqual([
    "inherit",
    "inherit",
  ]);
});

test("a dark theme changes the variables a page sees", async () => {
  const light = framePage(await frameMessage(LIGHT, PAGE));
  const dark = framePage(await frameMessage(DARK, PAGE));
  expect(light.root.getPropertyValue("color-scheme").trim()).toBe("light");
  expect(dark.root.getPropertyValue("color-scheme").trim()).toBe("dark");
  expect(dark.root.getPropertyValue("--cmux-text").trim()).toBe(DARK.text);
  expect(dark.root.getPropertyValue("--cmux-card").trim()).toBe(DARK.surfaceBackground);
  expect(dark.style("body").color).toBe(DARK.text);
  expect(dark.style("th").color).toBe(DARK.mutedText);
});

test("the render tool's description names every variable the frame sets", async () => {
  const { RENDER_TOKENS } = await import("../src/agent-session/acpmux/conversation/renderBase");
  const tool = readFileSync(
    new URL("../../cmux-tui/crates/cmux-tui/src/cli/mcp/render_tool.rs", import.meta.url),
    "utf8",
  );
  const description = /"description": "([^"]+)"/.exec(tool)![1]!;
  for (const [name] of RENDER_TOKENS) expect(description).toContain(name);
  expect(description).toMatch(/hardcod/i);
});
