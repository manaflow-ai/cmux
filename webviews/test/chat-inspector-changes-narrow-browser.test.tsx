// l10n-allow-file: test fixture pull request titles and owners, not shipped UI.
// Session Info's Changes rows in a narrow inspector (#28081, the gallery's
// agent-pane.inspector-worst-content): with an unbreakable repository name and every count at
// Number.MAX_SAFE_INTEGER, the unshortened line counts filled the row's second line by themselves,
// so the comment count and the failing checks after them were pushed out of the row. The counts now
// shorten (formatCount: 9Q) and the line gives way in order, `repo #N` first, then the line counts;
// the comments and the checks stay whole inside the row, and nothing runs past its edge.
//
// The rows are the real ChangesSection's, rendered in jsdom, then laid out in real Chromium from the
// inspector's stylesheets. CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-inspector-changes-narrow-browser.test.tsx", async () => {
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
  const { ChangesSection } = await import("../src/agent-session/acpmux/inspector/ChangesSection");
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
  // Each case: every count at its maximum, with failing checks, a green dot, or the by-kind wrapper.
  const cases = {
    failing: { checks: "failing", failing: max },
    passing: { checks: "passing", failing: 0 },
    breakdown: { checks: "failing", failing: max, breakdown: { code: { additions: max, deletions: max } } },
  } as const;

  const container = dom.window.document.getElementById("root")!;
  const html: Record<string, string> = {};
  for (const [name, extra] of Object.entries(cases)) {
    const root = createRoot(container);
    const statuses = Object.fromEntries(
      pullRequests.map((pr, index) => [
        pr.url,
        { owner: titles[index] || "🦊 Fox", additions: max, deletions: max, comments: max, ...extra },
      ]),
    );
    await act(async () => root.render(<ChangesSection pullRequests={pullRequests} statuses={statuses} />));
    html[name] = container.innerHTML;
    act(() => root.unmount());
  }
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = ["agent-session/acpmux/styles.css", "agent-session/acpmux/inspector/inspector.css"]
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
      expect(html.failing).toContain("acpmux-chat-inspector-pr__comments");
      expect(html.failing).toContain('data-checks="failing"');
      expect(html.passing).toContain('data-checks="passing"');
      expect(html.breakdown).toContain("acpmux-chat-inspector-pr__counts");
    });
    for (const name of Object.keys(cases))
      test(`${name}: the comments and checks stay whole inside the row, and no count runs past it`, async () => {
        const page = await browser.newPage({ viewport: { width: 280, height: 400 } });
        try {
          await page.setContent(
            `<style>${tokens}\n${css}\nbody { margin: 0; font: 13px system-ui, sans-serif }</style>` +
              `<div class="acpmux-shell" style="width: 280px">${html[name]}</div>`,
          );
          const rows = await page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>("li.acpmux-chat-inspector-pr")].map((row) => {
              const line = row.querySelector<HTMLElement>(".acpmux-chat-inspector-pr__line")!;
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
                comments: part(".acpmux-chat-inspector-pr__comments"),
                checks: part(".acpmux-chat-inspector-pr__checks"),
                counts: [part(".acpmux-diff-add"), part(".acpmux-diff-del")],
              };
            }),
          );
          expect(rows.length).toBe(titles.length);
          for (const row of rows) {
            expect(row.lineRight).toBeLessThanOrEqual(row.rowRight + 0.5);
            expect(row.lineOverflows).toBe(false);
            for (const kept of [row.comments, row.checks]) {
              expect(kept).not.toBeNull();
              expect(kept!.width).toBeGreaterThan(0);
              expect(kept!.inside).toBe(true);
              expect(kept!.whole).toBe(true);
            }
            // At 280px the shortened counts fit whole too, and inside the row.
            for (const count of row.counts) {
              expect(count).not.toBeNull();
              expect(count!.inside).toBe(true);
              expect(count!.whole).toBe(true);
            }
          }
        } finally {
          await page.close();
        }
      });
  });
});
