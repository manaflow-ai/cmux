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
import { settleReact } from "./support/domTeardown";

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
  await settleReact();
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

  describe("Session Info's six-dot handles", () => {
    test("every section but the pinned Environment has one", () => {
      // Counted against the sections the full gallery draws, so a new section (Sources, #25208)
      // needs no edit here. Environment heads the panel and never moves, so it has no grip (Lucas,
      // 2026-11-06: "the re order icon feels a bit weird here"; sectionOrder.ts PINNED_TOP).
      const sections = markup.match(/<section class="acpmux-session-info-section"/g)?.length ?? 0;
      const pinned = markup.includes('data-section="environment"') ? 1 : 0;
      expect(sections).toBeGreaterThanOrEqual(6);
      expect(markup.match(/acpmux-session-info-section__handle/g)?.length).toBe(sections - pinned);
    });

    test("before any hover the panel's pixels are the panel's without them", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 }, deviceScaleFactor: 2 });
      try {
        await show(page);
        const body = page.locator(".acpmux-session-info__body");
        const withHandles = await body.screenshot();
        const layoutWith = await boxes(page);
        await page.evaluate(() => {
          for (const handle of document.querySelectorAll(".acpmux-session-info-section__handle")) handle.remove();
          const style = document.createElement("style");
          style.textContent = ".acpmux-session-info-section { position: static !important }";
          document.head.append(style);
        });
        expect(await boxes(page)).toEqual(layoutWith);
        const without = await body.screenshot();
        expect(withHandles.equals(without)).toBe(true);
      } finally {
        await page.close();
      }
    });

    // Since #27570 the section list owns the spacing (sessionInfo.css). The lean panel (Lucas, 2026-11-05,
    // Session Info lab) has no blocks and no hairlines: one grid gap between every two items of the list,
    // the Show more line included.
    test("the default order draws one grid gap between every two sections, and no hairline", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 } });
      try {
        await show(page, { grid: true });
        const geometry = await page.evaluate(() => {
          const slots = [...document.querySelectorAll(".acpmux-session-info-sections > [data-slot]")];
          return {
            count: slots.length,
            gaps: slots
              .slice(1)
              .map((slot, index) => slot.getBoundingClientRect().top - slots[index]!.getBoundingClientRect().bottom),
            rules: slots.filter((slot) => getComputedStyle(slot, "::before").content !== "none").length,
          };
        });
        expect(geometry.count).toBeGreaterThanOrEqual(5);
        for (const gap of geometry.gaps) expect(gap).toBeCloseTo(gridLength("gap"), 1);
        expect(geometry.rules).toBe(0);
      } finally {
        await page.close();
      }
    });

    // Leo, 2026-11-06: "if you look at the spacing of claude code, they have theirs at the right". The grip
    // went left on 2026-11-03 only because it sat by the scrollbar's thumb; the body draws none since.
    // Leo, 2026-11-07: "the grip and the lef tside aren't flush". The grip shows at its head's right end in
    // the count's place, its dots on the rows' right text edge, and the count fades out under it.
    test("hovering a section shows its faint handle at its head's right end, in the count's place, and nothing moves", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 } });
      try {
        // The handle's width and the body's insets are grid tokens since #27570.
        await show(page, { grid: true });
        const before = await boxes(page);
        const opacity = () =>
          page.evaluate(
            () =>
              getComputedStyle(
                document.querySelector('section[data-section="outputs"] > .acpmux-session-info-section__handle')!,
              ).opacity,
          );
        expect(await opacity()).toBe("0");
        await page.hover('section[data-section="outputs"] .ui-disclosure-trigger');
        // Faint on its head's hover, as the reference's; full only on the grip itself. It fades in over the
        // quick step.
        await page.waitForFunction(
          () =>
            getComputedStyle(
              document.querySelector('section[data-section="outputs"] > .acpmux-session-info-section__handle')!,
            ).opacity === "0.7",
        );
        expect(await opacity()).toBe("0.7");
        expect(await boxes(page)).toEqual(before);
        const inside = await page.evaluate(() => {
          const handle = document
            .querySelector('section[data-section="outputs"] > .acpmux-session-info-section__handle')!
            .getBoundingClientRect();
          const scroller = document.querySelector<HTMLElement>(".acpmux-session-info__body")!;
          const body = scroller.getBoundingClientRect();
          // The scrollport's right edge: where a classic scrollbar's track begins.
          const scrollport = body.left + scroller.clientLeft + scroller.clientWidth;
          const section = document.querySelector('section[data-section="outputs"]')!.getBoundingClientRect();
          const title = document
            .querySelector('section[data-section="outputs"] .acpmux-session-info-section__title')!
            .getBoundingClientRect();
          return {
            inBody: handle.left >= body.left - 0.5 && handle.right <= body.right + 0.5,
            // Clear of the panel's edge.
            clearOfEdge: scrollport - handle.right >= 3.5,
            // Its dots end on the rows' right text edge: the head's trailing padding, one grid gap, in.
            dotsOnTextEdge: Math.round(
              section.right -
                document
                  .querySelector('section[data-section="outputs"] > .acpmux-session-info-section__handle svg')!
                  .getBoundingClientRect().right,
            ),
            titleAtIconColumn: Math.round(title.left - section.left),
          };
        });
        expect(inside).toEqual({
          inBody: true,
          clearOfEdge: true,
          dotsOnTextEdge: 8,
          // The heads have no icon, and the title starts on the rows' icon column: the head's leading
          // padding, one grid gap (Lucas, 2026-11-05, Session Info lab).
          titleAtIconColumn: 8,
        });
      } finally {
        await page.close();
      }
    });

    // Leo, 2026-11-06: "I do not like the layout and proportion of the dragger." On every head the dots,
    // two columns of three at the reference's size, end on the rows' right text edge in the count's place
    // (the count fades out under them; 2026-11-07: "the grip and the lef tside aren't flush"), on the
    // head's middle line, and the head draws no fill.
    test("a head's grip takes its count's place on the rows' right text edge, on its middle line", async () => {
      const page = await browser.newPage({ viewport: { width: 400, height: 1400 } });
      try {
        await show(page, { grid: true });
        for (const id of ["subagents", "context", "outputs"]) {
          const head = `section[data-section="${id}"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger`;
          await page.hover(head);
          await page.waitForFunction((head) => {
            const section = document.querySelector(head)!.closest("section")!;
            const meta = section.querySelector(".acpmux-session-info-section__meta");
            const handle = section.querySelector(":scope > .acpmux-session-info-section__handle")!;
            return getComputedStyle(handle).opacity === "0.7" && (!meta || getComputedStyle(meta).opacity === "0");
          }, head);
          const fit = await page.evaluate((head) => {
            const trigger = document.querySelector(head)!;
            const pill = trigger.getBoundingClientRect();
            const dots = trigger
              .closest("section")!
              .querySelector(":scope > .acpmux-session-info-section__handle svg")!
              .getBoundingClientRect();
            const meta = trigger.querySelector(".acpmux-session-info-section__meta");
            const gap = Number.parseFloat(getComputedStyle(trigger).paddingRight);
            return {
              onTextEdge: Math.abs(dots.right - (pill.right - gap)) <= 1,
              countGivesWay: !meta || getComputedStyle(meta).opacity === "0",
              noFill: getComputedStyle(trigger).backgroundColor === "rgba(0, 0, 0, 0)",
              onMiddleLine: Math.abs(dots.top + dots.height / 2 - (pill.top + pill.height / 2)) <= 0.5,
              tall: dots.height > dots.width,
              small: dots.width <= 6 && dots.height <= 10,
            };
          }, head);
          expect({ id, ...fit }).toEqual({
            id,
            onTextEdge: true,
            countGivesWay: true,
            noFill: true,
            onMiddleLine: true,
            tall: true,
            small: true,
          });
        }
      } finally {
        await page.close();
      }
    });
  });
});
