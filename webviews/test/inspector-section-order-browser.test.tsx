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

await requireBrowserLane("inspector-section-order-browser.test.tsx", async () => {
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
  const { ChatInspector } = await import("../src/agent-session/acpmux/inspector/ChatInspector");
  const gallery = (await import("../src/agent-session/acpmux/inspector/ChatInspector.gallery")).default;
  const { chromium } = await import("playwright");
  setPaneLanguage("en");

  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(ChatInspector, gallery.variants.full!.props as never)));
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
    "agent-session/acpmux/inspector/inspector.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8").replace(/^@import[^;]*;$/gm, ""))
    .join("\n");

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // Away from the panel, so no section starts hovered.
  const show = async (page: Page) => {
    await page.setContent(
      `<style>${css} body { margin: 0 }</style>` +
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

  describe("Session Info's six-dot handles", () => {
    test("every section has one", () => {
      // Counted against the sections the full gallery draws, so a new section (Sources, #25208)
      // needs no edit here.
      const sections = markup.match(/<section class="acpmux-chat-inspector-section"/g)?.length ?? 0;
      expect(sections).toBeGreaterThanOrEqual(8);
      expect(markup.match(/acpmux-chat-inspector-section__handle/g)?.length).toBe(sections);
    });

    test("before any hover the panel's pixels are the panel's without them", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 }, deviceScaleFactor: 2 });
      try {
        await show(page);
        const body = page.locator(".acpmux-chat-inspector__body");
        const withHandles = await body.screenshot();
        const layoutWith = await boxes(page);
        await page.evaluate(() => {
          for (const handle of document.querySelectorAll(".acpmux-chat-inspector-section__handle")) handle.remove();
          const style = document.createElement("style");
          style.textContent = ".acpmux-chat-inspector-section { position: static !important }";
          document.head.append(style);
        });
        expect(await boxes(page)).toEqual(layoutWith);
        const without = await body.screenshot();
        expect(withHandles.equals(without)).toBe(true);
      } finally {
        await page.close();
      }
    });

    test("hovering a section shows its handle in the left padding, and nothing moves", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 } });
      try {
        await show(page);
        const before = await boxes(page);
        const opacity = () =>
          page.evaluate(
            () =>
              getComputedStyle(
                document.querySelector('section[data-section="outputs"] > .acpmux-chat-inspector-section__handle')!,
              ).opacity,
          );
        expect(await opacity()).toBe("0");
        await page.hover('section[data-section="outputs"] .ui-disclosure-trigger');
        expect(await opacity()).toBe("1");
        expect(await boxes(page)).toEqual(before);
        const inside = await page.evaluate(() => {
          const handle = document
            .querySelector('section[data-section="outputs"] > .acpmux-chat-inspector-section__handle')!
            .getBoundingClientRect();
          const body = document.querySelector(".acpmux-chat-inspector__body")!.getBoundingClientRect();
          const section = document.querySelector('section[data-section="outputs"]')!.getBoundingClientRect();
          return { inBody: handle.left >= body.left - 0.5, beforeSection: handle.right <= section.left + 0.5 };
        });
        expect(inside).toEqual({ inBody: true, beforeSection: true });
      } finally {
        await page.close();
      }
    });
  });
});
