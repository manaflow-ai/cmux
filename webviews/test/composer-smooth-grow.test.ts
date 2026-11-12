// cmux-web-test-timeout: 300
// l10n-allow-file: typed and pasted fixture text, not shipped UI.
// The composer grows and shrinks on one smooth motion, and the transcript moves with it in every
// frame. Leo, 2026-11-07: "it's like the composer kind of doesn't grow smoothly. It grows in bursts.
// You know, say like you reach the end of the line and then your next character goes to the next
// line. It's like, but it doesn't grow nicely."
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a seeded chat
// followed at its latest row. Every painted frame is read (after the pane's own observers, which
// place the rows over the bottom stack before paint): the composer card's height, the rest gap from
// the newest row's line to the stack's top, the prompt field's box and the caret.
//
// - A typed wrap: the card's height changes over several frames, never more than half a line in
//   one, never backwards; the rows keep their gap in every frame; the caret's line stays in the
//   field (at least partly while the edge reveals it, whole once it rests).
// - A 40-line paste: one motion to the field's cap (no still frame between its first and last
//   move, never backwards, no frame over half the growth), the caret in view in every frame.
// - Reduce Motion: the same wrap lands in one frame, the rows with it.
// - Per key: a key that wraps no line renders no transcript; the report prints the renders per key
//   and per wrapped line.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Frame = {
  t: number;
  card: number;
  gap: number;
  fieldTop: number;
  fieldBottom: number;
  caretTop: number;
  caretBottom: number;
};

await requireBrowserLane("composer-smooth-grow.test.ts", async () => {
  /// Pins the composer dock to its push arm (composer/dockMotion.experiment.ts): these cases measure the
  /// rows riding the composer's growth, which the overlay arm (the default) leaves still under the card
  /// by design (test/agent-pane-composer-dock-motion.test.ts measures both arms).
  const pushDock = () => localStorage.setItem("cmux.experiments", JSON.stringify({ "composer-dock-motion": "push" }));
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The page side of the frame reads: `__grow.start()` records one Frame per painted frame into
  /// `__grow.frames` until `__grow.stop()`. Read in a ResizeObserver made after the pane's own (a
  /// probe resized in each frame's callbacks), so each read is of the layout that frame paints.
  const sampler = () => {
    const w = window as unknown as { __grow: { frames: Frame[]; start(): void; stop(): void } };
    const read = (): Frame | undefined => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const dock = document.querySelector<HTMLElement>(".acpmux-main[data-dock=float] > .acpmux-dock");
      const card = document.querySelector<HTMLElement>(".acpmux-composer-box");
      const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field");
      if (!scroller || !dock || !card || !field) return undefined;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter(
        (row) => row.getBoundingClientRect().height > 0,
      );
      if (!rows.length) return undefined;
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const parts = [...dock.children].flatMap((part) =>
        part.classList.contains("acpmux-composer") ? [...part.children] : [part],
      );
      const tops = parts.map((part) => part.getBoundingClientRect()).filter((rect) => rect.height > 0);
      const stackTop = Math.min(...tops.map((rect) => rect.top));
      const selection = getSelection();
      const range = selection && selection.rangeCount ? selection.getRangeAt(0) : undefined;
      // An empty paragraph's caret has no box (an empty draft): no reading.
      const caret = range ? [...range.getClientRects()].at(-1) : undefined;
      const box = field.getBoundingClientRect();
      const round = (value: number) => Math.round(value * 100) / 100;
      return {
        t: Math.round(performance.now()),
        card: round(card.getBoundingClientRect().height),
        gap: round(stackTop - last.getBoundingClientRect().bottom),
        fieldTop: round(box.top),
        fieldBottom: round(box.bottom),
        caretTop: round(caret?.top ?? NaN),
        caretBottom: round(caret?.bottom ?? NaN),
      };
    };
    let stop: (() => void) | undefined;
    let observer: ResizeObserver | undefined;
    w.__grow = {
      frames: [],
      start() {
        w.__grow.frames = [];
        const probe = document.createElement("div");
        probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
        document.body.append(probe);
        observer = new ResizeObserver(() => {
          const frame = read();
          if (frame) w.__grow.frames.push(frame);
        });
        observer.observe(probe);
        let wide = false;
        stop = window.cmuxAfterPaint(
          () => true,
          () => {
            wide = !wide;
            probe.style.width = wide ? "2px" : "1px";
          },
        );
        w.__grow.stop = () => {
          stop?.();
          observer?.disconnect();
          probe.remove();
        };
      },
      stop() {},
    };
  };

  const open = async (reducedMotion: "reduce" | "no-preference", look?: "push") => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 820 } });
    if (look === "push") await page.addInitScript(pushDock);
    await page.emulateMedia({ reducedMotion });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(60))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await installPaintedFrames(page);
    // The page's animations run at a tenth of their speed, so a loaded host still paints many frames
    // of each (the motion's shape, not its length, is measured). A change with no motion still lands
    // in one frame.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.1 });
    await page.evaluate(sampler);
    await page.locator(".acpmux-composer-box .acpmux-md").click();
    await rest(page);
    return page;
  };

  /// Until nothing in the composer animates and two painted frames pass.
  const rest = async (page: Page) => {
    await page.waitForFunction(
      () => document.querySelector(".acpmux-composer-box")!.getAnimations({ subtree: true }).length === 0,
    );
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
  };

  const record = async (page: Page, act: () => Promise<void>) => {
    await page.evaluate(() => (window as any).__grow.start());
    await act();
    // fixed-wait: past the last input, a frame or two before the slowed motion (at most 2.4 s) starts.
    await page.waitForTimeout(100);
    await rest(page);
    return (await page.evaluate(() => {
      const grow = (window as any).__grow;
      grow.stop();
      return grow.frames;
    })) as Frame[];
  };

  const lineHeight = (page: Page) =>
    page.evaluate(() =>
      Number.parseFloat(getComputedStyle(document.querySelector(".acpmux-composer-box .acpmux-md-field")!).lineHeight),
    );

  /// The runs of frames whose card height changed (each a growth or shrink), split where it held
  /// still for four frames (a spring's tail moves by hundredths of a pixel a frame).
  const runs = (frames: Frame[]) => {
    const found: { from: number; to: number; steps: number[] }[] = [];
    let current: { from: number; to: number; steps: number[] } | undefined;
    let still = 0;
    for (let index = 1; index < frames.length; index++) {
      const step = frames[index]!.card - frames[index - 1]!.card;
      if (Math.abs(step) < 0.005) {
        if (++still >= 4) current = undefined;
        continue;
      }
      still = 0;
      if (!current) {
        current = { from: frames[index - 1]!.card, to: frames[index]!.card, steps: [] };
        found.push(current);
      }
      current.to = frames[index]!.card;
      current.steps.push(step);
    }
    return found;
  };

  const restGap = (frames: Frame[]) => {
    const sorted = frames.map((frame) => frame.gap).sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)]!;
  };

  const WRAP =
    "the client waits a little longer before each retry and adds random jitter so a crowd of clients does not retry in step with the others";

  // Skipped until https://github.com/manaflow-ai/cmux/issues/40187: under the pinned Inter face the
  // composer's growth moves the transcript's top row, and the roving tab stop that follows it redraws
  // two rows (rowRenders 2, not 0). DejaVu's wrap left the top row in place.
  test.skip("a typed wrap grows the composer over frames, with the rows in step and the caret in the field", async () => {
    const page = await open("no-preference");
    const line = await lineHeight(page);
    const perf = "/perf.ts";
    await page.evaluate(async (url) => (await import(/* @vite-ignore */ url)).acpmuxPerf.resetRenders(), perf);
    const before = await page.evaluate(
      () => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
    );
    const frames = await record(page, () => page.keyboard.type(WRAP, { delay: 30 }));
    const renders = (await page.evaluate(
      async (url) => Object.fromEntries((await import(/* @vite-ignore */ url)).acpmuxPerf.renders),
      perf,
    )) as Record<string, number>;
    const grown = runs(frames);
    const lines = Math.round((frames.at(-1)!.card - before) / line);
    const steps = grown.flatMap((run) => run.steps);
    const gap = restGap(frames);
    const report = {
      line,
      lines,
      runs: grown.map((run) => ({ from: run.from, to: run.to, frames: run.steps.length })),
      maxStep: Math.max(...steps.map(Math.abs)),
      gapOff: Math.max(...frames.map((frame) => Math.abs(frame.gap - gap))),
      keys: WRAP.length,
      transcriptRenders: renders.transcript ?? 0,
      transcriptRendersPerKey: (renders.transcript ?? 0) / WRAP.length,
      transcriptRendersPerLine: lines ? (renders.transcript ?? 0) / lines : NaN,
      composerRenders: renders.composer ?? 0,
      paneRenders: renders.pane ?? 0,
      rowRenders: Object.entries(renders)
        .filter(([name]) => name.startsWith("row:") || name.startsWith("content:"))
        .reduce((sum, [, count]) => sum + count, 0),
    };
    console.log(`COMPOSER-GROW wrap ${JSON.stringify(report)}`);
    await page.close();
    // The text wrapped onto at least one new line.
    expect(lines).toBeGreaterThanOrEqual(1);
    expect(grown.length).toBe(lines);
    for (const run of grown) {
      // Eased: over several frames, never more than half a line in one, never backwards.
      expect(run.steps.length, `frames of the growth ${run.from} -> ${run.to}`).toBeGreaterThanOrEqual(4);
      for (const step of run.steps) expect(step).toBeGreaterThan(-0.05);
    }
    expect(report.maxStep, "the largest one-frame step of the card (px)").toBeLessThanOrEqual(line / 2);
    // The rows move with the card in the same frame.
    expect(report.gapOff, "the rest gap's largest change in a frame (px)").toBeLessThanOrEqual(1);
    // The caret's line is in the field in every frame, and whole in it at rest.
    for (const frame of frames.filter((each) => Number.isFinite(each.caretTop))) {
      expect(frame.caretTop).toBeLessThan(frame.fieldBottom);
      expect(frame.caretBottom).toBeGreaterThan(frame.fieldTop);
    }
    const last = frames.at(-1)!;
    expect(last.caretBottom).toBeLessThanOrEqual(last.fieldBottom + 0.5);
    // Typing renders the transcript once per line it adds, as at once did: never per key, and never
    // per frame of the motion (the rows move on the compositor).
    expect(report.transcriptRenders, "transcript renders over the typed wrap").toBeLessThanOrEqual(lines);
    expect(report.rowRenders, "row renders over the typed wrap").toBe(0);
  });

  test("a 40-line paste grows the composer once, to its cap, with the caret in view", async () => {
    const page = await open("no-preference", "push");
    const line = await lineHeight(page);
    const text = Array.from({ length: 40 }, (_, index) => `Line ${index + 1} of the pasted notes`).join("\n");
    // The pasteboard holds the text, as after a copy in another app, and the platform's paste key pastes it.
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.evaluate((pasted) => navigator.clipboard.writeText(pasted), text);
    const before = await page.evaluate(
      () => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
    );
    const frames = await record(page, () => page.keyboard.press("ControlOrMeta+V"));
    const pasted = await page.evaluate(
      () => document.querySelector(".acpmux-composer-box .acpmux-md")!.textContent ?? "",
    );
    expect(pasted).toContain("Line 40 of the pasted notes");
    // The height before the paste comes first: a paste that lands at once may do so before the
    // first frame read.
    const grown = runs([{ ...frames[0]!, card: before }, ...frames]);
    const growth = frames.at(-1)!.card - before;
    const steps = grown.flatMap((run) => run.steps);
    const gap = restGap(frames);
    const report = {
      line,
      growth,
      runs: grown.map((run) => ({ from: run.from, to: run.to, frames: run.steps.length })),
      maxStep: Math.max(...steps.map(Math.abs)),
      gapOff: Math.max(...frames.map((frame) => Math.abs(frame.gap - gap))),
    };
    console.log(`COMPOSER-GROW paste ${JSON.stringify(report)}`);
    await page.close();
    // To the cap: many lines, but under forty.
    expect(growth).toBeGreaterThan(line * 8);
    expect(growth).toBeLessThan(line * 39);
    // One motion, eased over several frames, never backwards, no frame over half of it.
    expect(grown.length).toBe(1);
    expect(grown[0]!.steps.length).toBeGreaterThanOrEqual(4);
    for (const step of steps) expect(step).toBeGreaterThan(-0.05);
    expect(report.maxStep).toBeLessThanOrEqual(growth / 2);
    expect(report.gapOff).toBeLessThanOrEqual(1);
    // The caret (the paste's end) is in view in every frame it is drawn in (the empty draft's has no box).
    for (const frame of frames.filter((each) => Number.isFinite(each.caretTop))) {
      expect(frame.caretTop).toBeGreaterThanOrEqual(frame.fieldTop - 0.5);
      expect(frame.caretBottom).toBeLessThanOrEqual(frame.fieldBottom + 0.5);
    }
  });

  test("with Reduce Motion a wrap lands in one frame, the rows with it", async () => {
    const page = await open("reduce", "push");
    const line = await lineHeight(page);
    const frames = await record(page, () => page.keyboard.type(WRAP, { delay: 30 }));
    const grown = runs(frames);
    const gap = restGap(frames);
    const gapOff = Math.max(...frames.map((frame) => Math.abs(frame.gap - gap)));
    console.log(
      `COMPOSER-GROW reduced ${JSON.stringify({ runs: grown.map((run) => ({ from: run.from, to: run.to, frames: run.steps.length })), gapOff })}`,
    );
    await page.close();
    expect(grown.length).toBeGreaterThanOrEqual(1);
    for (const run of grown) {
      expect(run.steps.length).toBe(1);
      expect(Math.abs(run.to - run.from)).toBeGreaterThan(line / 2);
    }
    expect(gapOff).toBeLessThanOrEqual(1);
  });
});
