// Leo, 2026-10-21: "why is there no harness at the left". The quiet row under the composer box
// (ComposerFoot.tsx) showed only the mode on the left and the model button and context ring on the
// right; nothing said which harness the chat runs. Claude Code's footer starts with its project; ours
// starts with the harness (ComposerHarness.tsx): its mark and its name, quiet text with no capsule,
// then the mode.
//
// It renders the real composer (gallery `agent-pane.composer`, `footer-harness*`) in Chromium:
//   - the row's first item is the harness, named Claude Code for Claude and Codex for Codex, with its
//     brand mark, before the mode;
//   - it draws no pill at rest; a started chat's harness is fixed, so its item is not a button;
//   - a new chat can still switch: the item is a button that opens the model button's menu (its rail);
//   - at 410 px the row still shows the harness's mark, and no two items overlap.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Item = {
  className: string;
  left: number;
  right: number;
  /** Visible text, left to right. */
  text: string;
  /** The brand mark the item draws, when one is visible. */
  mark: string | null;
  markWidth: number;
  background: string;
  button: boolean;
};

await requireBrowserLane("composer-footer-harness.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-footer-harness: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer footer harness", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer"], { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width: number): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height: 560 } });
    await page.goto(url(variant));
    // Vite can reload the stage once while it optimizes a dependency on the first load.
    const ready = () =>
      page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30_000 });
    await ready().catch(async () => {
      await page.reload();
      await ready();
    });
    await page.waitForSelector(".acpmux-composer-foot .acpmux-access");
    // The row's fit settles in a layout effect and on resize; one frame lets it write its forms.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  }

  /** Runs in the page: the quiet row's items as drawn, left to right. */
  function measure(): Item[] {
    const foot = document.querySelector<HTMLElement>(".acpmux-composer-foot")!;
    const shown = (element: Element) => {
      for (let node: Element | null = element; node && node !== foot; node = node.parentElement) {
        const css = getComputedStyle(node);
        if (css.display === "none" || css.visibility !== "visible") return false;
      }
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    // The row's items, looking through `display: contents` wrappers (the chips).
    const items = (container: Element): HTMLElement[] =>
      [...container.children].flatMap((child) => {
        if (!(child instanceof HTMLElement)) return [];
        if (getComputedStyle(child).display === "contents") return items(child);
        return shown(child) && getComputedStyle(child).position !== "absolute" ? [child] : [];
      });
    return items(foot)
      .map((element) => {
        const rect = element.getBoundingClientRect();
        const texts: [number, string][] = [];
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode())
          if (node.textContent?.trim() && node.parentElement && shown(node.parentElement))
            texts.push([node.parentElement.getBoundingClientRect().left, node.textContent.trim()]);
        const mark = [...element.querySelectorAll<SVGElement>("svg.agent-mark")].find(shown);
        const control = element.querySelector<HTMLElement>(".acpmux-picker-button") ?? element;
        return {
          className: element.className,
          left: rect.left,
          right: rect.right,
          text: texts
            .sort(([a], [b]) => a - b)
            .map(([, text]) => text)
            .join(" "),
          mark: mark?.dataset.agent ?? null,
          markWidth: mark?.getBoundingClientRect().width ?? 0,
          background: getComputedStyle(control).backgroundColor,
          button: control instanceof HTMLButtonElement,
        };
      })
      .sort((a, b) => a.left - b.left);
  }

  const clear = (color: string) => color === "rgba(0, 0, 0, 0)" || color === "transparent";

  for (const [variant, name, mark] of [
    ["footer-harness", "Claude Code", "claude"],
    ["footer-harness-codex", "Codex", "openai"],
  ] as const) {
    test(`${name}: the quiet row starts with the harness, its mark and name, before the mode`, async () => {
      const page = await open(variant, 760);
      const row = await page.evaluate(measure);
      const [first, second] = row;
      expect(first?.className).toContain("acpmux-harness");
      expect(first?.text).toBe(name);
      expect(first?.mark).toBe(mark);
      expect(second?.className).toContain("acpmux-access");
      // Quiet text: no capsule at rest, and a started chat's harness is fixed, so not a button.
      expect(clear(first!.background)).toBe(true);
      expect(first?.button).toBe(false);
      await page.close();
    });
  }

  test("a started chat's harness takes no pill on hover", async () => {
    const page = await open("footer-harness", 760);
    await page.hover(".acpmux-composer-foot .acpmux-harness");
    const background = await page.$eval(
      ".acpmux-composer-foot .acpmux-harness .acpmux-picker-button",
      (element) => getComputedStyle(element).backgroundColor,
    );
    expect(clear(background)).toBe(true);
    await page.close();
  });

  test("a new chat's harness opens the model button's menu, whose rail switches harness", async () => {
    const page = await open("footer-harness-new-chat", 760);
    const [first] = await page.evaluate(measure);
    expect(first?.className).toContain("acpmux-harness");
    expect(first?.text).toBe("Claude Code");
    expect(first?.button).toBe(true);
    await page.click(".acpmux-composer-foot .acpmux-harness button");
    await page.waitForSelector(".acpmux-quick-menu", { timeout: 5_000 });
    await page.close();
  });

  for (const [variant, mark] of [
    ["footer-harness", "claude"],
    ["footer-harness-codex", "openai"],
  ] as const) {
    test(`at 410 px the row still shows ${mark}'s mark first, and no items overlap`, async () => {
      const page = await open(variant, 410);
      const row = await page.evaluate(measure);
      const footBox = await page.$eval(".acpmux-composer-foot", (foot) => {
        const rect = foot.getBoundingClientRect();
        return { left: rect.left, right: rect.right };
      });
      expect(row[0]?.className).toContain("acpmux-harness");
      expect(row[0]?.mark).toBe(mark);
      expect(row[0]!.markWidth).toBeGreaterThan(10);
      for (let index = 1; index < row.length; index++)
        expect(row[index]!.left).toBeGreaterThanOrEqual(row[index - 1]!.right - 0.5);
      expect(row[0]!.left).toBeGreaterThanOrEqual(footBox.left - 0.5);
      expect(row.at(-1)!.right).toBeLessThanOrEqual(footBox.right + 0.5);
      // Its name, when the row gives it up, stays in its tooltip.
      if (!row[0]!.text) {
        const title = await page.$eval(
          ".acpmux-composer-foot .acpmux-harness .acpmux-picker-button",
          (element) => (element as HTMLElement).title,
        );
        expect(title).toBe(mark === "claude" ? "Claude Code" : "Codex");
      }
      await page.close();
    });
  }
});
