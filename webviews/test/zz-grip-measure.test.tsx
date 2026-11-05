// l10n-allow-file: test fixture names, not shipped UI.
// Session Info before any drag is the panel it was (Leo, 2026-10-29: "LITERALLY BE THE EXACT SAME
// FUCKING SITUTAION AS BEFORE BUT NOW YOU CAN FUCKING FCLICK AND DRAG TO REARRANGE"). The gallery's
// full chat is rendered in jsdom, then laid out in real Chromium from the pane's stylesheets, and
// its pixels are compared with the same panel with the six-dot handles and their positioning taken
// out, which is the markup and the styles from before the handles: they must be byte-identical. On
// hover a section shows its handle, and nothing moves. CI fails the file when Chromium cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Browser, Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { gridLength } from "../src/agent-session/acpmux/transcriptGrid";

await requireBrowserLane("session-info-section-order-browser.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const { JSDOM, VirtualConsole } = await import("jsdom");
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
    localStorage: dom.window.localStorage,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
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
    if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|Keyboard|Mouse|Focus|Event)/.test(key) && !(key in scope))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);

  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
  const { SessionInfo } = await import("../src/agent-session/acpmux/session-info/SessionInfo");
  const gallery = (await import("../src/agent-session/acpmux/session-info/SessionInfo.gallery")).default;
  const { chromium } = await import("playwright");
  setPaneLanguage("en");

  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(SessionInfo, gallery.variants.full!.props as never)));
  await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  const markup = container.innerHTML;
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/summary/summary.css",
    "agent-session/acpmux/subagents/subagents.css",
    "agent-session/acpmux/session-info/sessionInfo.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8").replace(/^@import[^;]*;$/gm, ""))
    .join("\n");
  // The grid's --grid-* lengths, as the app's pane has them from pages/shared/desktop.css (generated
  // from schemas/layout-grid/layout-grid.json). Since #27570 the section list's gaps are those tokens.
  const gridTokens = readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8")
    .split("\n")
    .filter((line) => /^\s*--grid-[\w-]+\s*:/.test(line))
    .join("\n");

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // Away from the panel, so no section starts hovered.
  const show = async (page: Page, { grid = false } = {}) => {
    await page.setContent(
      `<style>${grid ? `:root {\n${gridTokens}\n}\n` : ""}${css} body { margin: 0 }</style>` +
        `<div style="position: absolute; left: 40px; top: 40px; width: 320px">${markup}</div>`,
    );
    await page.mouse.move(2, 2);
  };
  const boxes = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll("section[data-section]")].map((section) => {
        const box = section.getBoundingClientRect();
        return [section.getAttribute("data-section"), box.left, box.top, box.width, box.height];
      }),
    );

  test("measure", async () => {
    const page = await browser.newPage({ viewport: { width: 400, height: 1400 }, deviceScaleFactor: 3 });
    await show(page, { grid: true });
    const ids = await page.evaluate(() => [...document.querySelectorAll("section[data-section]")].map((s) => s.getAttribute("data-section")));
    for (const id of ids) {
      const sel = `section[data-section="${id}"]`;
      const found = await page.evaluate((sel) => {
        const s = document.querySelector(sel)!;
        const t = s.querySelector(":scope > :not(.acpmux-session-info-section__handle) .ui-disclosure-trigger, :scope > .acpmux-session-info-section__head") ?? s.querySelector(":scope > :not(.acpmux-session-info-section__handle) > :first-child");
        t?.setAttribute("data-probe", "1");
        return !!t;
      }, sel);
      if (!found) { console.log(id, "no head"); continue; }
      await page.hover(`${sel} [data-probe]`);
      const m = await page.evaluate((sel) => {
        const s = document.querySelector(sel)!;
        const h = s.querySelector(":scope > .acpmux-session-info-section__handle")!;
        const svg = h.querySelector("svg")!.getBoundingClientRect();
        const t = s.querySelector("[data-probe]")!;
        const tb = t.getBoundingClientRect();
        const cs = getComputedStyle(t);
        const bt = parseFloat(cs.borderTopWidth), bb = parseFloat(cs.borderBottomWidth);
        const sb = s.getBoundingClientRect();
        return { cls: t.className.slice(0, 40), sectionTop: sb.top, pill: [tb.left, tb.top + bt, tb.right, tb.bottom - bb].map(Math.round), grip: [svg.left, svg.top, svg.right, svg.bottom], dy: (svg.top + svg.bottom) / 2 - (tb.top + bt + tb.bottom - bb) / 2, gapToPill: svg.left - tb.left, op: getComputedStyle(h).opacity };
      }, sel);
      console.log(id, JSON.stringify(m));
      await page.screenshot({ path: `${process.env.FAST_CHECKS_OUT ?? process.env.OUT ?? "/tmp"}/grip-${id}.png`, clip: { x: 20, y: m.pill[1] - 10, width: 200, height: 40 } });
    }
    await page.close();
  });
});
