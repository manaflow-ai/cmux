import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AgentSessionTheme } from "../shared/types";
import type { AcpmuxSnapshot } from "./model";

// appearance.borders none: the composer, its menus and the transcript's code and tool cards
// draw no edge. The page's own stylesheets (in the order the pane bundle concatenates them)
// render the real components; each edge's custom properties are resolved through the cascade.
const css = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const dom = new JSDOM(
  `<!doctype html><style>${[
    "./styles.css",
    "./conversation/conversation.css",
    "./changes/changes.css",
    "./composerControls.css",
    "./composerStates.css",
  ]
    .map(css)
    .join("\n")}</style><div id=root></div>`,
  { url: "http://localhost/", pretendToBeVisual: true, virtualConsole: new VirtualConsole() },
);
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The code card renders @pierre/diffs web components, which reach for DOM classes by name.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { CodeBlock } = await import("./conversation/CodeBlock");
const { ShellBlock } = await import("./conversation/ShellBlock");
const { Markdown } = await import("./conversation/Markdown");
const { ScopeMenu } = await import("./changes/ScopeMenu");
const { applyAgentTheme } = await import("../shared/theme");

const theme: AgentSessionTheme = {
  isDark: true,
  pageBackground: "rgba(30, 30, 46, 1.0)",
  surfaceBackground: "rgba(30, 30, 46, 1.0)",
  surfaceElevatedBackground: "rgba(40, 40, 56, 1.0)",
  inputBackground: "rgba(41, 42, 58, 1.0)",
  border: "rgba(205, 214, 244, 0.08)",
  borderStrong: "rgba(205, 214, 244, 0.07)",
  text: "rgba(205, 214, 244, 1.0)",
  mutedText: "rgba(160, 166, 190, 1.0)",
  softText: "rgba(130, 136, 160, 1.0)",
  accent: "rgba(205, 214, 244, 1.0)",
  accentSoft: "rgba(205, 214, 244, 0.1)",
  accentText: "rgba(30, 30, 46, 1.0)",
  danger: "rgba(243, 139, 168, 1.0)",
  shadow: "rgba(5, 5, 7, 1.0)",
};
const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

/// `value` with every `var(--name[, fallback])` replaced by the custom property as `element`
/// computes it (jsdom cascades custom properties but leaves var() in other properties).
function resolve(element: Element, value: string, depth = 0): string {
  if (depth > 8) return value;
  const style = dom.window.getComputedStyle(element);
  const next = value.replace(
    /var\((--[\w-]+)\s*(?:,([^()]*(?:\([^()]*\)[^()]*)*))?\)/g,
    (_, name: string, fallback?: string) => {
      const own = style.getPropertyValue(name).trim();
      return own || (fallback ?? "").trim();
    },
  );
  return next === value ? value : resolve(element, next, depth + 1);
}
const edge = (selector: string, property: "box-shadow" | "border-bottom-color" = "box-shadow") => {
  const element = dom.window.document.querySelector(selector);
  expect(element).not.toBeNull();
  return resolve(element!, dom.window.getComputedStyle(element!).getPropertyValue(property));
};
/// The top-level comma-separated layers of a box-shadow (commas inside color-mix() stay).
function layers(shadow: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < shadow.length; index += 1) {
    if (shadow[index] === "(") depth += 1;
    else if (shadow[index] === ")") depth -= 1;
    else if (shadow[index] === "," && depth === 0) {
      parts.push(shadow.slice(start, index).trim());
      start = index + 1;
    }
  }
  parts.push(shadow.slice(start).trim());
  return parts;
}
/// Every color an inset ring draws with: what follows its geometry. A drop shadow (the
/// menus' `0 10px 30px`) is not an edge and is left out.
const insetColors = (shadow: string) =>
  layers(shadow)
    .filter((part) => part.startsWith("inset"))
    .map((part) => part.replace(/^inset\s+(?:-?[\d.]+(?:px)?\s+){3,4}/, "").trim());

describe("agent pane edges follow appearance.borders", () => {
  let root: ReturnType<typeof createRoot>;
  const render = async (borders: AgentSessionTheme["borders"]) => {
    applyAgentTheme({ ...theme, borders });
    await act(async () =>
      root.render(
        createElement(
          "div",
          { className: "acpmux-shell" },
          createElement(CodeBlock, { code: "let x = 1", lang: "text" }),
          createElement(ShellBlock, { command: "ls", output: "a", exitCode: 0 }),
          createElement(Markdown, null, "- [ ] open task\n- [x] done task"),
          createElement(
            "div",
            { className: "acpmux-diff-tools" },
            createElement(ScopeMenu, { scope: "lastTurn", onScope: () => {} }),
          ),
          createElement(Composer, { snapshot, chips: () => null, onSend: () => {}, onStop: () => {} }),
        ),
      ),
    );
    // Open the + menu, as a click does.
    const plus = dom.window.document.querySelector(".acpmux-composer-plus .acpmux-picker-button") as HTMLButtonElement;
    await act(async () => plus.click());
  };
  const surfaces = [".acpmux-composer-box", ".acpmux-menu", ".cv-codeblock", ".cv-shell"];

  beforeEach(() => {
    root = createRoot(dom.window.document.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("none: the composer, menu, code card and tool card rings are transparent", async () => {
    await render("none");
    expect(dom.window.document.documentElement.dataset.borders).toBe("none");
    for (const selector of surfaces) {
      const colors = insetColors(edge(selector));
      expect(colors.length).toBeGreaterThan(0);
      for (const color of colors) expect(`${selector}: ${color}`).toBe(`${selector}: transparent`);
    }
  });

  // The task checkbox and the changes view's scope pill and toolbar draw a plain ring; under
  // none it goes, and the open checkbox shows as a fill instead so it does not vanish.
  const checkboxes = [".cv-checkbox:not(.is-checked)", ".cv-checkbox.is-checked"];
  const pills = [".acpmux-diff-scope", ".acpmux-diff-tools"];
  const rings = [...checkboxes, ...pills];
  test("none: the checkbox, scope pill and toolbar rings are gone; the open checkbox is a fill", async () => {
    await render("none");
    for (const selector of checkboxes) expect(`${selector}: ${edge(selector)}`).toBe(`${selector}: none`);
    for (const selector of pills) {
      const colors = insetColors(edge(selector));
      expect(`${selector}: ${colors.length}`).not.toBe(`${selector}: 0`);
      for (const color of colors) expect(`${selector}: ${color}`).toBe(`${selector}: transparent`);
    }
    const open = dom.window.document.querySelector(".cv-checkbox:not(.is-checked)")!;
    expect(resolve(open, dom.window.getComputedStyle(open).getPropertyValue("background"))).toMatch(
      /^color-mix\(in srgb,\s*rgba\(205, 214, 244, 1\.0\) 9%/,
    );
  });

  test("default: the checkbox, scope pill and toolbar keep their rings", async () => {
    await render("default");
    for (const selector of rings) {
      const colors = insetColors(edge(selector));
      expect(`${selector}: ${colors.length}`).not.toBe(`${selector}: 0`);
      for (const color of colors) expect(color).toMatch(/^color-mix\(in srgb,\s*rgba\(205, 214, 244, 1\.0\)/);
    }
  });

  test("none: the fills stay, so the composer and cards still read against the page", async () => {
    await render("none");
    for (const selector of [".acpmux-composer-box", ".acpmux-menu", ".cv-codeblock"]) {
      const element = dom.window.document.querySelector(selector)!;
      const fill = resolve(element, dom.window.getComputedStyle(element).getPropertyValue("background"));
      expect(fill).toMatch(/color-mix\(in srgb,\s*rgba\(205, 214, 244, 1\.0\)/);
    }
  });

  test("default: every ring keeps its theme-mixed color", async () => {
    for (const borders of [undefined, "default"] as const) {
      await act(async () => root.unmount());
      root = createRoot(dom.window.document.getElementById("root")!);
      await render(borders);
      expect(dom.window.document.documentElement.dataset.borders).toBeUndefined();
      for (const selector of surfaces) {
        const colors = insetColors(edge(selector));
        expect(colors.length).toBeGreaterThan(0);
        for (const color of colors) expect(color).toMatch(/^color-mix\(in srgb,\s*rgba\(205, 214, 244, 1\.0\)/);
      }
    }
  });
});
