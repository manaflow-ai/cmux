// Session Info's show more / show less rows (SessionInfoFold, session-info/SessionInfoSection.tsx). Leo asked
// for show more / less to be the whole row, plain text, no hover pill. In real Chromium on the
// gallery's busy coordinator (agent-pane.chat-inspector#subagents-busy), each fold (Changes' Show
// more, Subagents' Show 12 more, Background tasks' 4 finished) spans its list's width; a click in
// the empty part of the row, right of its label, opens it; hovering paints no fill; and keyboard focus
// follows the agent pane's shared policy (agent-session/shared/styles.css: the soft pill, no outline).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-fold-rows.test.ts", async () => {
  const ENTRY = "agent-pane.chat-inspector";
  type Row = {
    found: boolean;
    width: number;
    list: number;
    labelRight: number;
    right: number;
    y: number;
    expanded: string | null;
  };

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-fold-rows: skipping (run `bunx playwright install chromium`)");
    describe.skip("session info fold rows", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser });
    const port = (vite.httpServer!.address() as { port: number }).port;
    page = await browser.newPage({ viewport: { width: 420, height: 1600 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "subagents-busy", width: 420, height: 1600 })}`,
    );
    // A cold dev server compiles the gallery on the first request; give it longer than the default.
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The fold whose label matches `label`: its box, its list's width and where its label ends. */
  const row = (label: string) =>
    page!.evaluate((source) => {
      const pattern = new RegExp(source);
      const button = [...document.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-fold")].find(
        (candidate) => pattern.test(candidate.textContent ?? ""),
      );
      if (!button)
        return {
          found: false,
          width: 0,
          list: 0,
          labelRight: 0,
          right: 0,
          y: 0,
          expanded: null,
        };
      // The busy card stops at its ceiling and scrolls; bring the row into the viewport first.
      button.scrollIntoView({ block: "center" });
      const box = button.getBoundingClientRect();
      const parent = button.parentElement!;
      const style = getComputedStyle(parent);
      const range = document.createRange();
      range.selectNodeContents(button);
      return {
        found: true,
        width: box.width,
        list: parent.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
        labelRight: range.getBoundingClientRect().right,
        right: box.right,
        y: box.top + box.height / 2,
        expanded: button.getAttribute("aria-expanded"),
      };
    }, label) as Promise<Row>;

  const fill = (label: string) =>
    page!.evaluate((source) => {
      const pattern = new RegExp(source);
      const button = [...document.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-fold")].find(
        (candidate) => pattern.test(candidate.textContent ?? ""),
      )!;
      const style = getComputedStyle(button);
      return {
        color: style.backgroundColor,
        image: style.backgroundImage,
        outline: style.outlineStyle,
      };
    }, label);

  for (const [section, closed, open] of [
    ["Changes", "Show more", "Show less"],
    ["Subagents", "Show 12 more", "Show less"],
    ["Background tasks", "4 finished", "4 finished"],
  ] as const) {
    test(`${section}: "${closed}" is the whole row, opens from its empty end, and hovers with no pill`, async () => {
      const before = await row(closed);
      expect(before.found, `${section} has no "${closed}" fold`).toBe(true);
      expect(before.expanded).toBe("false");
      expect(before.width).toBeGreaterThanOrEqual(before.list - 1);
      // A point well right of the label, still inside the row.
      expect(before.right - before.labelRight).toBeGreaterThan(40);
      const x = before.right - 6;

      await page!.mouse.move(x, before.y);
      const hovered = await fill(closed);
      expect(hovered.color).toBe("rgba(0, 0, 0, 0)");
      expect(hovered.image).toBe("none");

      await page!.mouse.click(x, before.y);
      await page!.waitForFunction(
        (source) =>
          [...document.querySelectorAll("button.acpmux-session-info-fold")].some(
            (button) =>
              new RegExp(source).test(button.textContent ?? "") && button.getAttribute("aria-expanded") === "true",
          ),
        open,
      );
      // Fold it back, so the next section's row sits where it rendered.
      await page!.mouse.move(0, 0);
      const after = await row(open);
      await page!.mouse.click(after.right - 6, after.y);
      await page!.waitForFunction(
        (source) =>
          [...document.querySelectorAll("button.acpmux-session-info-fold")].some(
            (button) =>
              new RegExp(source).test(button.textContent ?? "") && button.getAttribute("aria-expanded") === "false",
          ),
        closed,
      );
    });
  }

  test("keyboard focus on a fold takes the agent pane's soft pill, not an outline", async () => {
    await page!.mouse.move(0, 0);
    await page!.evaluate(() => {
      const button = document.querySelector<HTMLButtonElement>("button.acpmux-session-info-pr-fold")!;
      (button.focus as (options: { focusVisible: boolean }) => void)({
        focusVisible: true,
      });
    });
    const focused = await page!.evaluate(() => {
      const button = document.querySelector<HTMLButtonElement>("button.acpmux-session-info-pr-fold")!;
      const style = getComputedStyle(button);
      return {
        visible: button.matches(":focus-visible"),
        outline: style.outlineStyle,
        image: style.backgroundImage,
      };
    });
    expect(focused.visible).toBe(true);
    expect(focused.outline).toBe("none");
    expect(focused.image).toContain("linear-gradient");
  });
});
