// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Opening or closing a tool call, or a turn's "Worked for", never moves the reader's view (Leo
// 2026-10-20), in a real layout: while the view follows a streaming reply, the clicked line stays
// on the pixel it was clicked at through every frame of its fold, and the reply streaming on below
// does not pull it away. The fold plays (a height animation on `.cv-fold`) except under Reduce Motion.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fold-anchor-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-anchor-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript fold anchor", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const output = (lines: number) =>
    Array.from({ length: lines }, (_, index) => `line ${index + 1}: the keeper trimmed the wick`).join("\n");
  const read = (id: string, lines = 30) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: output(lines) },
  });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  /// A finished turn that worked first: its "Worked for" line opens to the calls.
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-run`, "activity", undefined, { items: [read(`t${index}-a`), read(`t${index}-b`)] }),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 9_000, toolCount: 2 }),
  ];
  const done = Array.from({ length: 8 }, (_, index) => turn(index)).flat();
  /// The turn still running: a call with output, then the reply streaming under it.
  const live = (version: number): Row[] => [
    row("live-user", "user", "Read the lantern log and summarize it."),
    row("live-run", "activity", undefined, { items: [read("live-log", 40)] }),
    row("live-answer", "assistant", paragraphs(version), { version, streaming: true }),
  ];

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const settle = async (page: Page) => {
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await page.waitForTimeout(400);
  };
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  /// Marks the line `selector` finds last in the transcript, and returns where it is drawn.
  const probe = (page: Page, selector: string) =>
    page.evaluate((query) => {
      const lines = [...document.querySelectorAll<HTMLElement>(query)];
      const line = lines.at(-1)!;
      line.dataset.probe = "true";
      const box = line.getBoundingClientRect();
      return { top: box.top, x: box.left + 24, y: box.top + box.height / 2 };
    }, selector);
  /// Clicks the marked line, then follows it every frame for `ms`: how far it ever moved, and
  /// whether a fold was playing at some frame.
  const clickAndWatch = async (page: Page, ms = 450) => {
    const point = await page.evaluate(() => {
      const box = document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect();
      return { x: box.left + 24, y: box.top + box.height / 2, top: box.top };
    });
    const watching = page.evaluate(
      ({ duration, from }) =>
        new Promise<{ moved: number; folded: boolean }>((resolve) => {
          const start = performance.now();
          let moved = 0;
          let folded = false;
          const step = () => {
            const line = document.querySelector<HTMLElement>("[data-probe]");
            if (line) moved = Math.max(moved, Math.abs(line.getBoundingClientRect().top - from));
            for (const fold of document.querySelectorAll(".cv-fold"))
              if (fold.getAnimations().length > 0) folded = true;
            if (performance.now() - start < duration) requestAnimationFrame(step);
            else resolve({ moved, folded });
          };
          requestAnimationFrame(step);
        }),
      { duration: ms, from: point.top },
    );
    await page.mouse.click(point.x, point.y);
    return { ...(await watching), top: point.top };
  };
  const probedTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect().top);
  const open = async (reducedMotion: "reduce" | "no-preference") => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.emulateMedia({ reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };

  test("a tool call opened while the reply is followed stays on its pixel, and the reply streaming on leaves it there", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);

    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(true);
    expect(opened.moved).toBeLessThanOrEqual(1);
    // The output opened below the line, out past the view's end: the view stopped following.
    expect(await atLatest(page)).toBe(false);

    // The reply streams on; the reader's place holds.
    for (let version = 2; version < 6; version += 1) {
      await show(page, [...done, ...live(version)]);
      await settle(page);
    }
    expect(Math.abs((await probedTop(page)) - opened.top)).toBeLessThanOrEqual(1);

    // Closed again, away from the end, it stays where it is too.
    const closed = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(closed.moved).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("a finished turn's Worked for opened at the latest row stays on its pixel", async () => {
    const page = await open("no-preference");
    await show(page, done);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, `[data-row-id="worked-t7-user"] button.cv-worked`);
    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.moved).toBeLessThanOrEqual(1);
    expect(await page.locator('[data-row-id="t7-run"]').count()).toBe(1);
    await page.close();
  });

  test("under Reduce Motion a tool call opens at once, and still stays on its pixel", async () => {
    const page = await open("reduce");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    const opened = await clickAndWatch(page, 250);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(false);
    expect(opened.moved).toBeLessThanOrEqual(1);
    await page.close();
  });
});
