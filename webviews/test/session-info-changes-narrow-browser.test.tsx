// l10n-allow-file: test fixture pull request titles and owners, not shipped UI.
// Session Info's Changes rows in a narrow Session Info (#28081, the gallery's
// agent-pane.inspector-worst-content): with an unbreakable repository name and every count at
// Number.MAX_SAFE_INTEGER, the unshortened line counts filled the row's second line by themselves,
// so the comment count and the failing checks after them were pushed out of the row. The counts now
// shorten (formatCount: 9Q) and the line gives way in order, `repo #N` first, then the line counts;
// the comments and the checks stay whole inside the row, and nothing runs past its edge.
//
// The rows are the real ChangesSection's, rendered in jsdom, then laid out in real Chromium from the
// Session Info's stylesheets. CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-changes-narrow-browser.test.tsx", async () => {
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
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);

  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { ChangesSection } = await import("../src/agent-session/acpmux/session-info/ChangesSection");
  const { chromium } = await import("playwright");

  const max = Number.MAX_SAFE_INTEGER;
  const repo = `example/${"longunbreakablerepository".repeat(5)}`;
  const titles = ["Aleksandra Wiśniewska-Kowalczyk-".repeat(4), "王秀英".repeat(20), "عبد الرحمن".repeat(10), ""];
  const pullRequests = titles.map((title, index) => ({
    url: `https://github.com/${repo}/pull/${index + 1}`,
    repo,
    number: index + 1,
    title,
    opened: true,
    state: "open" as const,
  }));
  // Each case: every count at its maximum, with failing checks (some already failing on base), a
  // green dot, or the by-kind wrapper. `ordinary` is a real row (#28774's review): before the checks
  // annotation could shrink, "3 failing (2 already on base)" pushed `cmux #22240 +1482 -311` out.
  const cases = {
    failing: { checks: "failing", failing: max },
    failingOnBase: { checks: "failing", failing: max, failingOnBase: max },
    passing: { checks: "passing", failing: 0 },
    breakdown: { checks: "failing", failing: max, breakdown: { code: { additions: max, deletions: max } } },
    ordinary: { checks: "failing", failing: 3, failingOnBase: 2, additions: 1482, deletions: 311, comments: 0 },
  } as const;
  const ordinaryPullRequests = titles.map((title, index) => ({
    url: `https://github.com/manaflow-ai/cmux/pull/${22240 + index}`,
    repo: "manaflow-ai/cmux",
    number: 22240 + index,
    title,
    opened: true,
    state: "open" as const,
  }));

  const container = dom.window.document.getElementById("root")!;
  const html: Record<string, string> = {};
  for (const [name, extra] of Object.entries(cases)) {
    const root = createRoot(container);
    const rows = name === "ordinary" ? ordinaryPullRequests : pullRequests;
    const statuses = Object.fromEntries(
      rows.map((pr, index) => [
        pr.url,
        { owner: titles[index] || "🦊 Fox", additions: max, deletions: max, comments: max, ...extra },
      ]),
    );
    await act(async () => root.render(<ChangesSection pullRequests={rows} statuses={statuses} />));
    html[name] = container.innerHTML;
    act(() => root.unmount());
  }
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = ["agent-session/acpmux/styles.css", "agent-session/acpmux/session-info/sessionInfo.css"]
    .map((file) => readFileSync(path.join(src, file), "utf8").replace(/^@import[^;]*;$/gm, ""))
    .join("\n");
  // The pane's detail size (pages/shared/desktop.css), which the line's text uses.
  const tokens = ":root { --text-detail: 12px; --text-detail--letter-spacing: 0; }";

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  describe("Session Info's Changes rows at 280px with every count at its maximum", () => {
    test("the rows render the shortened counts, the comments and the checks", () => {
      expect(html.failing).toContain("+9Q");
      expect(html.failing).toContain("acpmux-session-info-pr__comments");
      expect(html.failing).toContain('data-checks="failing"');
      expect(html.passing).toContain('data-checks="passing"');
      expect(html.breakdown).toContain("acpmux-session-info-pr__counts");
      expect(html.failingOnBase).toContain("acpmux-session-info-pr__base");
      expect(html.ordinary).toContain("cmux #22240");
      expect(html.ordinary).toContain("(2 already on base)");
    });
    for (const name of Object.keys(cases))
      test(`${name}: the comments and checks stay whole inside the row, and no count runs past it`, async () => {
        // The ordinary row at Session Info's usual 320px: this Chromium's fallback font is wider than
        // the app's Inter, which fits it at 280px. The maximum counts take the narrow 280px.
        const width = name === "ordinary" ? 320 : 280;
        const page = await browser.newPage({ viewport: { width, height: 400 } });
        try {
          await page.setContent(
            `<style>${tokens}\n${css}\nbody { margin: 0; font: 13px system-ui, sans-serif }</style>` +
              `<div class="acpmux-shell" style="width: ${width}px">${html[name]}</div>`,
          );
          const rows = await page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>("li.acpmux-session-info-pr")].map((row) => {
              const line = row.querySelector<HTMLElement>(".acpmux-session-info-pr__line")!;
              const edge = line.getBoundingClientRect();
              const part = (selector: string) => {
                const element = line.querySelector<HTMLElement>(selector);
                if (!element) return null;
                const box = element.getBoundingClientRect();
                return {
                  selector,
                  width: box.width,
                  inside: box.left >= edge.left - 0.5 && box.right <= edge.right + 0.5,
                  whole: element.scrollWidth <= element.clientWidth + 1 || element.clientWidth === 0,
                };
              };
              return {
                rowRight: row.getBoundingClientRect().right,
                lineRight: edge.right,
                lineOverflows: line.scrollWidth > line.clientWidth + 1,
                comments: part(".acpmux-session-info-pr__comments"),
                // Failing, the checks' parts sit on the line itself: "N failing" is the part kept whole.
                checks: part(
                  '.acpmux-session-info-pr__failing, .acpmux-session-info-pr__checks:not([data-checks="failing"])',
                ),
                ref: part(".acpmux-session-info-pr__ref"),
                base: part(".acpmux-session-info-pr__base"),
                counts: [part(".acpmux-diff-add"), part(".acpmux-diff-del")],
              };
            }),
          );
          expect(rows.length).toBe(titles.length);
          for (const row of rows) {
            expect(row.lineRight).toBeLessThanOrEqual(row.rowRight + 0.5);
            expect(row.lineOverflows).toBe(false);
            // The ordinary row has no comments; every other row has the maximum.
            for (const kept of name === "ordinary" ? [row.checks] : [row.comments, row.checks]) {
              expect(kept).not.toBeNull();
              expect(kept!.width).toBeGreaterThan(0);
              expect(kept!.inside).toBe(true);
              expect(kept!.whole).toBe(true);
            }
            // The shortened counts fit whole too, and inside the row.
            for (const count of row.counts) {
              expect(count).not.toBeNull();
              expect(count!.inside).toBe(true);
              expect(count!.whole).toBe(true);
            }
            if (name === "failingOnBase" || name === "ordinary") {
              expect(row.base).not.toBeNull();
              expect(row.base!.inside).toBe(true);
            }
            // An ordinary `repo #N` stays whole beside the checks annotation (#28774's review).
            if (name === "ordinary") {
              expect(row.ref).not.toBeNull();
              expect(row.ref!.whole).toBe(true);
              expect(row.ref!.inside).toBe(true);
            }
          }
        } finally {
          await page.close();
        }
      });
  });

  // The ⋯ menu button is not repeated down every row (#28774's review): it shows on the hovered
  // row, on the row that has focus (so Tab still reaches it), and while its menu is open, after the
  // pointer and focus leave. Base UI marks the open trigger with data-popup-open
  // (session-info-changes.test.tsx checks that the click sets it).
  test("the ⋯ button shows only on hover, on focus, or while its menu is open", async () => {
    const page = await browser.newPage({ viewport: { width: 280, height: 400 } });
    try {
      await page.setContent(
        `<style>${tokens}\n${css}\nbody { margin: 0; font: 13px system-ui, sans-serif }</style>` +
          `<div class="acpmux-shell" style="width: 280px">${html.ordinary}</div><button id=away>away</button>`,
      );
      const more = page.locator("button.acpmux-session-info-pr__more");
      const opacities = () =>
        more.evaluateAll((buttons) => buttons.map((button) => Number(getComputedStyle(button).opacity)));
      await page.mouse.move(279, 399);
      expect(await more.count()).toBe(titles.length);
      expect(await opacities()).toEqual(titles.map(() => 0));
      // Hover: only that row's button.
      await page.locator("li.acpmux-session-info-pr").nth(1).hover();
      expect(await opacities()).toEqual(titles.map((_, index) => (index === 1 ? 1 : 0)));
      await page.mouse.move(279, 399);
      // Keyboard: Tab from the first row's link reaches its ⋯, which shows.
      await page.locator("a.acpmux-session-info-pr__link").first().focus();
      expect((await opacities())[0]).toBe(1);
      await page.keyboard.press("Tab");
      expect(await more.first().evaluate((button) => button === document.activeElement)).toBe(true);
      expect(await opacities()).toEqual(titles.map((_, index) => (index === 0 ? 1 : 0)));
      // Menu open: it stays shown once the pointer and focus have left the row.
      await more.nth(2).evaluate((button) => button.setAttribute("data-popup-open", ""));
      await page.locator("#away").focus();
      expect(await opacities()).toEqual(titles.map((_, index) => (index === 2 ? 1 : 0)));
    } finally {
      await page.close();
    }
  });

  // A touch screen has no hover (`(hover: none)`), so every row's ⋯ shows at rest there; the rule
  // must outrank the resting `opacity: 0`, not lose to it.
  test("on a screen with no hover, every row's ⋯ shows at rest", async () => {
    const context = await browser.newContext({ viewport: { width: 280, height: 400 }, hasTouch: true, isMobile: true });
    try {
      const page = await context.newPage();
      await page.setContent(
        `<style>${tokens}\n${css}\nbody { margin: 0; font: 13px system-ui, sans-serif }</style>` +
          `<div class="acpmux-shell" style="width: 280px">${html.ordinary}</div>`,
      );
      expect(await page.evaluate(() => matchMedia("(hover: none)").matches)).toBe(true);
      const opacities = await page
        .locator("button.acpmux-session-info-pr__more")
        .evaluateAll((buttons) => buttons.map((button) => Number(getComputedStyle(button).opacity)));
      expect(opacities).toEqual(titles.map(() => 1));
    } finally {
      await context.close();
    }
  });
});
