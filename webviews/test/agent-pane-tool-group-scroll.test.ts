// l10n-allow-file: the gallery fixture supplies the long tool-call transcript.
// The inline run arm belongs to the transcript's scroll surface, without a second vertical scroller.
// The box arm intentionally scrolls long runs inside their own viewport (RunScroll.test.tsx).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { pinArms } from "./support/pinArms";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-tool-group-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("agent-pane-tool-group-scroll: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, "agent-pane.transcript", {
      browser,
      params: { variant: "tool-run-scrolled-fade" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("inline run: wheel over the collapsed tool rows scrolls the transcript", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.addInitScript(() => localStorage.clear());
    await pinArms(page, { "run-scroll": "inline" });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", { variant: "tool-run-scrolled-fade" })}`,
    );
    const worked = page.locator(".cv-worked").first();
    if ((await worked.getAttribute("aria-expanded")) !== "true") await worked.click();
    const runButton = page.locator(".cv-tools > .cv-tool.is-toggle").first();
    await runButton.waitFor();
    if ((await runButton.getAttribute("aria-expanded")) !== "true") await runButton.click();
    const group = page.locator(".cv-tool-run").first();
    await group.waitFor();
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".cv-tool-run");
      return node !== null && node.clientHeight > 0;
    });

    const inner = await group.evaluate((node) => ({
      scrollHeight: node.scrollHeight,
      clientHeight: node.clientHeight,
    }));
    expect(inner.scrollHeight - inner.clientHeight).toBeLessThanOrEqual(1);

    const inline = await group.locator(".cv-tool.is-toggle").evaluateAll((buttons) => {
      const values = buttons.map((button) => {
        const label = button.querySelector<HTMLElement>(".cv-tool__text, .cv-command__text")!;
        const caret = button.querySelector<HTMLElement>(".cv-tool__chevron")!;
        return caret.getBoundingClientRect().left - label.getBoundingClientRect().right;
      });
      return { count: values.length, max: Math.max(...values), min: Math.min(...values) };
    });
    expect(inline.count).toBeGreaterThan(3);
    expect(inline.min).toBeGreaterThanOrEqual(-0.5);
    expect(inline.max).toBeLessThanOrEqual(4.5);

    const transcript = page.locator(".acpmux-scroll");
    // The gallery shell keeps its pane height independent of the browser viewport. Constrain the
    // mounted transcript itself so this routing check always has a real scroll surface; this is a
    // layout precondition, not a timing wait or a retry.
    await transcript.evaluate((node) => {
      node.style.flex = "none";
      node.style.height = "360px";
    });
    const outer = await transcript.evaluate((node) => ({
      scrollHeight: node.scrollHeight,
      clientHeight: node.clientHeight,
    }));
    expect(outer.scrollHeight - outer.clientHeight).toBeGreaterThan(40);
    await transcript.evaluate((node) => {
      node.scrollTop = 0;
    });
    const before = await transcript.evaluate((node) => node.scrollTop);
    const box = (await group.boundingBox())!;
    const transcriptBox = (await transcript.boundingBox())!;
    const overlapTop = Math.max(box.y, transcriptBox.y);
    const overlapBottom = Math.min(box.y + box.height, transcriptBox.y + transcriptBox.height);
    expect(overlapBottom).toBeGreaterThan(overlapTop);
    await page.mouse.move(box.x + box.width / 2, (overlapTop + overlapBottom) / 2);
    await page.mouse.wheel(0, 420);
    await page.waitForFunction(
      (start) => (document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0) > start + 2,
      before,
    );
    expect(await transcript.evaluate((node) => node.scrollTop)).toBeGreaterThan(before + 2);
    expect(await group.evaluate((node) => node.scrollTop)).toBe(0);
    await page.close();
  });

  test("boxed run: wheel scrolls its calls without moving the transcript", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.addInitScript(() => localStorage.clear());
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", { variant: "tool-run-scrolled-fade" })}`,
    );
    const worked = page.locator(".cv-worked").first();
    if ((await worked.getAttribute("aria-expanded")) !== "true") await worked.click();
    const run = page.locator(".cv-tools > .cv-tool.is-toggle").first();
    await run.waitFor();
    if ((await run.getAttribute("aria-expanded")) !== "true") await run.click();
    const box = page.locator(".cv-run-scroll").first();
    await box.waitFor();
    // The run's open plays a height fold, and in its last frames a chat that fit starts to overflow
    // (3 px here). A wheel that landed in those frames moved the transcript to its end: 8 of 21 first
    // tries failed the last assert with 3 for 1. That window is a finding of its own (#41859's probe
    // lines); this test is about a wheel over a run at rest. Wait for the fold's END before an offset
    // is read and the wheel is sent: the run's row plays no animation, and its height and the
    // transcript's offset hold for 6 frames.
    await page
      .waitForFunction(
        () => {
          const row = document.querySelector<HTMLElement>(".cv-run-scroll")?.closest<HTMLElement>(".acpmux-row");
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!row || !scroller) return false;
          const holder = globalThis as unknown as { __runFoldSeen?: { height: number; top: number; held: number } };
          const seen = (holder.__runFoldSeen ??= { height: -1, top: -1, held: 0 });
          const height = row.getBoundingClientRect().height;
          const top = scroller.scrollTop;
          const playing = row.getAnimations({ subtree: true }).some((each) => each.playState === "running");
          const same = Math.abs(height - seen.height) < 0.01 && Math.abs(top - seen.top) < 0.01;
          seen.held = same && !playing ? seen.held + 1 : 0;
          seen.height = height;
          seen.top = top;
          return seen.held >= 6;
        },
        undefined,
        { polling: "raf", timeout: 5_000 },
      )
      .catch((error: unknown) => {
        throw new Error(
          `the run's fold did not end in 5 s: its row's height and the transcript's offset never held for 6 frames (${String(error).split("\n")[0]})`,
        );
      });
    await box.scrollIntoViewIfNeeded();
    await box.evaluate((node) => {
      node.scrollTop = 0;
    });
    expect(await box.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeGreaterThan(40);
    const transcript = page.locator(".acpmux-scroll");
    const before = await transcript.evaluate((node) => node.scrollTop);
    const bounds = (await box.boundingBox())!;
    await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
    await page.mouse.wheel(0, 40);
    await page.waitForFunction(() => (document.querySelector<HTMLElement>(".cv-run-scroll")?.scrollTop ?? 0) > 2);
    expect(await box.evaluate((node) => node.scrollTop)).toBeGreaterThan(2);
    expect(await box.getAttribute("data-fade-top")).not.toBeNull();
    expect(Math.abs((await transcript.evaluate((node) => node.scrollTop)) - before)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
