// cmux-web-test-timeout: 300
// l10n-allow-file: typed test keys, not shipped UI.
// A line wrap in the agent chat's composer is a transition of the room under the last row with one
// owner, the list (transcript motion model rule 4). Before, each wrap drew the whole transcript
// synchronously: the field's growth (composer/fieldGrowth.ts) started in the key's own task and the
// transcript's dock handler took its room with `flushSync` there, before the frame could paint (the
// step 6 audit of chat typing while a reply streams; Leo, 2026-11-17: "man the difference typing on
// terminal vs gui is def noticeable rn ... slow and sad comparatively on the latter").
//
// The real pane (`?mock`) built as it ships, a light chat at its latest row, then real keys in
// Chromium until the draft wraps to a second and a third line. It checks:
// - no transcript render runs inside a key's input events or inside a ResizeObserver callback (the
//   frame's observer step), counted by `acpmuxPerf.render` around each;
// - the transcript renders the growth's room after all (it is not dropped);
// - `layoutWatch` reports no move but the declared one (`layoutWatch.expect("composer-growth")`);
// - the latest row keeps its gap over the composer once the growth lands (pinned, no jump).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-wrap-one-owner.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

/** Init script (self-contained): counts transcript renders inside input events and observer callbacks. */
function syncRenderProbe() {
  const w = window as unknown as {
    __wrapProbe: { on: boolean; inInput: number; inObserver: number; outside: number };
    cmuxAcpmuxDebug?: { renders(): Record<string, number> };
  };
  const probe = { on: false, inInput: 0, inObserver: 0, outside: 0 };
  w.__wrapProbe = probe;
  // renders() hands back the counts since its last call and starts again from zero.
  const take = () => (probe.on ? (w.cmuxAcpmuxDebug?.renders().transcript ?? 0) : 0);
  const Native = window.ResizeObserver;
  window.ResizeObserver = class extends Native {
    constructor(callback: ResizeObserverCallback) {
      super((entries, observer) => {
        probe.outside += take();
        try {
          callback(entries, observer);
        } finally {
          probe.inObserver += take();
          // And what the callback's own microtasks render, before the next observer.
          queueMicrotask(() => (probe.inObserver += take()));
        }
      });
    }
  };
  // From before the browser edits the text (beforeinput, capture: the first listener) to after every
  // listener of its input event and their microtasks (bubble on window: the last).
  let open = false;
  window.addEventListener(
    "beforeinput",
    () => {
      probe.outside += take();
      open = true;
    },
    true,
  );
  window.addEventListener("input", () => {
    if (!open) return;
    queueMicrotask(() => {
      probe.inInput += take();
      open = false;
    });
  });
}

await requireBrowserLane("composer-wrap-one-owner.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-wrap-one-owner", "chromium", chromium))) return;
  setDefaultTimeout(280_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-wrap-one-owner-"));
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });

  test("a line wrap renders no transcript synchronously, moves only what it declares, and keeps the latest row pinned", async () => {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 }, deviceScaleFactor: 1 });
    await page.addInitScript(syncRenderProbe);
    await page.goto(`http://127.0.0.1:${statics!.port!}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(40, { light: true }))) as {
      error?: string;
    };
    expect(seeded.error).toBeUndefined();
    const prompt = page.locator(PROMPT).first();
    await prompt.waitFor({ timeout: 30_000 });
    await prompt.click();
    const settled = () =>
      page.evaluate(() => new Promise<void>((done) => setTimeout(() => requestAnimationFrame(() => done()), 900)));
    // The first keys load the composer's lazy parts (emoji data, the mention index).
    for (const key of "warm") await page.keyboard.press(key);
    for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
    await settled();
    /** The latest row's bottom against the composer's top, and the prompt's text height. */
    const read = () =>
      page.evaluate((selector) => {
        const rows = [...document.querySelectorAll(".cv-message, .cv-worked, .cv-tool, .cv-turn-actions")];
        const last = rows.at(-1)?.getBoundingClientRect();
        const composer = document.querySelector(".acpmux-composer")?.getBoundingClientRect();
        const text = document.querySelector(selector)?.getBoundingClientRect();
        return {
          gap: last && composer ? composer.top - last.bottom : Number.NaN,
          text: text?.height ?? 0,
        };
      }, PROMPT);
    const rest = await read();
    expect(Number.isFinite(rest.gap)).toBe(true);
    await page.evaluate(() => {
      const w = window as any;
      w.cmuxAcpmuxDebug.renders();
      w.__wrapProbe.on = true;
      w.__wrapWatch = w.cmuxAcpmuxDebug.layoutWatch({ ms: 9000, tolerance: 1 });
    });
    await page.waitForTimeout(300);
    // Words typed until the draft has wrapped twice (a third line), a fast typist's pace.
    const words = "the quick brown fox jumps over the lazy dog ";
    let lines = 0;
    let last = rest.text;
    for (let i = 0; i < 600 && lines < 2; i += 1) {
      await page.keyboard.press(words[i % words.length] === " " ? "Space" : words[i % words.length]!);
      await page.waitForTimeout(25);
      const now = (await read()).text;
      if (now > last + 4) lines += 1;
      last = now;
    }
    expect(lines).toBe(2);
    await settled();
    const after = await read();
    const report = (await page.evaluate(async () => {
      const w = window as any;
      w.__wrapProbe.outside += w.cmuxAcpmuxDebug.renders().transcript ?? 0;
      w.__wrapProbe.on = false;
      return { probe: w.__wrapProbe, watch: await w.__wrapWatch };
    })) as {
      probe: { inInput: number; inObserver: number; outside: number };
      watch: { shifts: unknown[]; scroll_jumps: unknown[]; expected?: { reason: string }[] };
    };
    await page.close();
    if (process.env.WRAP_DEBUG) console.log(JSON.stringify({ report, rest, after }, null, 1));
    expect({
      transcript_renders_in_input: report.probe.inInput,
      transcript_renders_in_observer: report.probe.inObserver,
    }).toEqual({ transcript_renders_in_input: 0, transcript_renders_in_observer: 0 });
    // The room is still taken, by a render after the frame.
    expect(report.probe.outside).toBeGreaterThanOrEqual(1);
    expect({ shifts: report.watch.shifts, scroll_jumps: report.watch.scroll_jumps }).toEqual({
      shifts: [],
      scroll_jumps: [],
    });
    expect((report.watch.expected ?? []).some((move) => move.reason === "composer-growth")).toBe(true);
    // Pinned: the latest row rests the same gap over the taller composer.
    expect(Math.abs(after.gap - rest.gap)).toBeLessThanOrEqual(1.5);
  });
});
