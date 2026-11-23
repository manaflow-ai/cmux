// cmux-web-test-timeout: 600
// l10n-allow-file: the test's report keys, not shipped UI.
// Leo, 2026-11-06 (ask-e972252749): "when i scroll through this it flickers and the composer flickers".
//
// It scrolls with the wheel, as a person does, and reads per frame what a reader would see flicker,
// in every engine the browser lane has, and holds each at none:
// - the composer's folder menu (agent-pane.composer-context folder-long-list: 40 folders): the menu's
//   box, the composer strip's box, frames where the rows leave part of the menu's viewport empty
//   (a virtualized row not mounted yet), the highlight moving under a still pointer, DOM mutations
//   in the menu and the strip by attribute, layout-shift entries, and the strip's pixels per step;
// - the transcript (the real pane on `?mock`, 300 seeded turns): the composer's box and node, frames
//   where the rows leave the transcript's viewport empty, composer mutations, layout-shift entries,
//   and the composer's pixels per step.
// Each prints one `SCROLL-FLICKER {json}` line; screenshots go to $FAST_CHECKS_OUT. On feat-cmux-next
// b7aeb6bd348 (Chromium) every count was already none: this keeps it so.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { createHash } from "node:crypto";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Recorder = {
  frames: number;
  moved: Record<string, number>;
  blankFrames: number;
  maxGapPx: number;
  highlightChanges: number;
  mutations: Record<string, number>;
  shifts: { count: number; sum: number; sources: Record<string, number> };
  nodes: Record<string, number>;
};

await requireBrowserLane("scroll-flicker.browser.test.ts", async () => {
  const OUT = process.env.FAST_CHECKS_OUT;
  const STEPS = Number(process.env.SCROLL_FLICKER_STEPS) || 30;

  /// Installs the in-page recorder: each animation frame reads the watched parts' boxes and nodes, and
  /// how much of `scroller`'s viewport its rows leave empty.
  async function startRecorder(
    page: Page,
    options: { parts: Record<string, string>; scroller: string; rows: string; highlight?: string },
  ): Promise<void> {
    await page.evaluate((options) => {
      const w = window as any;
      const state = {
        frames: 0,
        moved: {} as Record<string, number>,
        first: {} as Record<string, DOMRect>,
        nodes: {} as Record<string, Set<Element>>,
        blankFrames: 0,
        maxGapPx: 0,
        highlight: undefined as string | undefined,
        highlightChanges: 0,
        mutations: {} as Record<string, number>,
        shifts: { count: 0, sum: 0, sources: {} as Record<string, number> },
        running: true,
      };
      w.__flicker = state;
      const name = (node: Node | null) => {
        const element = node instanceof Element ? node : node?.parentElement;
        return `${element?.tagName.toLowerCase() ?? "?"}.${element?.classList[0] ?? ""}`;
      };
      const watch = new MutationObserver((records) => {
        for (const record of records) {
          const key = `${name(record.target)} ${record.attributeName ?? record.type}`;
          state.mutations[key] = (state.mutations[key] ?? 0) + 1;
        }
      });
      for (const selector of Object.values(options.parts)) {
        const node = document.querySelector(selector);
        if (node) watch.observe(node, { subtree: true, childList: true, attributes: true, characterData: true });
      }
      w.__flickerWatch = watch;
      try {
        const shifts = new PerformanceObserver((list) => {
          for (const entry of list.getEntries() as any[]) {
            state.shifts.count += 1;
            state.shifts.sum += entry.value;
            for (const source of entry.sources ?? []) {
              const key = name(source.node);
              state.shifts.sources[key] = (state.shifts.sources[key] ?? 0) + 1;
            }
          }
        });
        shifts.observe({ type: "layout-shift", buffered: false });
        w.__flickerShifts = shifts;
      } catch {
        state.shifts.count = -1;
      }
      // raf-read: the probe reads boxes and rows in the frame a scroll lands, as a reader sees them.
      const frame = () => {
        if (!state.running) return;
        state.frames += 1;
        for (const [part, selector] of Object.entries(options.parts)) {
          const node = document.querySelector(selector);
          if (!node) {
            state.moved[part] = Math.max(state.moved[part] ?? 0, Infinity);
            continue;
          }
          (state.nodes[part] ??= new Set()).add(node);
          const box = node.getBoundingClientRect();
          const first = (state.first[part] ??= box);
          state.moved[part] = Math.max(
            state.moved[part] ?? 0,
            Math.abs(box.x - first.x),
            Math.abs(box.y - first.y),
            Math.abs(box.width - first.width),
            Math.abs(box.height - first.height),
          );
        }
        const scroller = document.querySelector<HTMLElement>(options.scroller);
        if (scroller) {
          const view = scroller.getBoundingClientRect();
          // The viewport's empty stretch: rows sorted by top, gaps between them inside the view.
          const spans = [...scroller.querySelectorAll<HTMLElement>(options.rows)]
            .map((row) => row.getBoundingClientRect())
            .filter((box) => box.height > 0 && box.bottom > view.top && box.top < view.bottom)
            .map((box) => [Math.max(view.top, box.top), Math.min(view.bottom, box.bottom)] as const)
            .sort((a, b) => a[0] - b[0]);
          // The longest stretch of the view no row covers (turn spacing and padding leave some; a row
          // not mounted yet leaves most of a view). The list's own end is not a gap.
          const end = Math.min(view.bottom, view.top + scroller.scrollHeight - scroller.scrollTop);
          let gap = 0;
          let reach = view.top;
          for (const [top, bottom] of spans) {
            gap = Math.max(gap, top - reach);
            reach = Math.max(reach, bottom);
          }
          gap = Math.max(gap, end - reach);
          if (gap > view.height / 2) state.blankFrames += 1;
          state.maxGapPx = Math.max(state.maxGapPx, gap);
        }
        if (options.highlight) {
          const now = document.querySelector(options.highlight)?.textContent ?? undefined;
          if (now !== state.highlight) {
            if (state.highlight !== undefined || now !== undefined) state.highlightChanges += 1;
            state.highlight = now;
          }
        }
        // raf-read: the frame a scroll lands in is the one the reader sees.
        requestAnimationFrame(frame);
      };
      // raf-read: the frame a scroll lands in is the one the reader sees.
      requestAnimationFrame(frame);
    }, options);
  }

  async function stopRecorder(page: Page): Promise<Recorder> {
    return page.evaluate(() => {
      const w = window as any;
      const state = w.__flicker;
      state.running = false;
      w.__flickerWatch?.disconnect();
      w.__flickerShifts?.disconnect();
      const round = (value: number) => (Number.isFinite(value) ? Math.round(value * 100) / 100 : -1);
      return {
        frames: state.frames,
        moved: Object.fromEntries(Object.entries(state.moved as Record<string, number>).map(([k, v]) => [k, round(v)])),
        blankFrames: state.blankFrames,
        maxGapPx: round(state.maxGapPx),
        highlightChanges: state.highlightChanges,
        mutations: Object.fromEntries(
          Object.entries(state.mutations as Record<string, number>)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 12),
        ),
        shifts: { ...state.shifts, sum: round(state.shifts.sum) },
        nodes: Object.fromEntries(
          Object.entries(state.nodes as Record<string, Set<Element>>).map(([k, v]) => [k, v.size]),
        ),
      };
    });
  }

  /// Wheels `steps` notches down then back up over `at`, a frame between notches; after each notch the
  /// `clip` part is captured and its pixels hashed. Returns how many distinct pictures it took.
  async function wheelAndCapture(
    page: Page,
    at: { x: number; y: number },
    steps: number,
    delta: number,
    clip: string,
    tag: string,
    blur: boolean,
  ): Promise<{ captures: number; distinct: number; changedSteps: number[]; changedPixels: number }> {
    await page.mouse.move(at.x, at.y);
    // A focused field's caret blinks; that is not a flicker. (Playwright's own caret hiding writes
    // every field's style per capture, which the mutation counts would read as the page's.)
    // The folder menu's field keeps the focus (its menu closes without it), and its caret is not in the strip.
    if (blur) await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur?.());
    const outer = await page.locator(clip).first().boundingBox();
    // Inside the part's rounded edge: what shows past its corners is the content scrolling behind it.
    // Past the composer's translucent 1 px rim (about 25 px in from the form's left edge), which tints
    // with the rows scrolling under it: that is the glass, not a flicker.
    const inset = outer ? Math.min(24, Math.floor(outer.height / 4)) : 0;
    const side = outer && outer.height > 60 ? 40 : inset;
    const box = outer && {
      x: outer.x + side,
      y: outer.y + inset,
      width: outer.width - 2 * side,
      height: outer.height - 2 * inset,
    };
    const hashes: string[] = [];
    const changed: number[] = [];
    const shots: Buffer[] = [];
    for (let step = 0; step < steps * 2; step += 1) {
      await page.mouse.wheel(0, step < steps ? delta : -delta);
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      if (!box) continue;
      const shot = await page.screenshot({ clip: box, animations: "allow", caret: "initial" });
      const hash = createHash("sha256").update(shot).digest("hex");
      if (hashes.length > 0 && hash !== hashes[0] && !hashes.includes(hash)) {
        changed.push(step);
        shots.push(shot);
        if (OUT && changed.length <= 6) await Bun.write(path.join(OUT, `${tag}-clip-step${step}.png`), shot);
      }
      if (hashes.length === 0) shots.unshift(shot);
      if (hashes.length === 0 && OUT) await Bun.write(path.join(OUT, `${tag}-clip-first.png`), shot);
      hashes.push(hash);
      if (OUT && (step === Math.floor(steps / 2) || step === steps + Math.floor(steps / 2)))
        await page.screenshot({ path: path.join(OUT, `${tag}-page-step${step}.png`) });
    }
    return {
      captures: hashes.length,
      distinct: new Set(hashes).size,
      changedSteps: changed,
      changedPixels: await visiblyChangedPixels(page, shots),
    };
  }

  /// The most pixels any later picture changes against the first by more than a glass tint: the
  /// composer is translucent, and a bright row passing under it shifts a few of its pixels by up to
  /// about 24 of 255. A flicker (a blank, a jump, a redrawn control) changes far more, and by more.
  async function visiblyChangedPixels(page: Page, shots: Buffer[]): Promise<number> {
    if (shots.length < 2) return 0;
    const urls = shots.map((shot) => `data:image/png;base64,${shot.toString("base64")}`);
    return page.evaluate(async (urls) => {
      const pixels = async (url: string) => {
        const image = new Image();
        image.src = url;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.width;
        canvas.height = image.height;
        const context = canvas.getContext("2d")!;
        context.drawImage(image, 0, 0);
        return context.getImageData(0, 0, image.width, image.height).data;
      };
      const first = await pixels(urls[0]!);
      let most = 0;
      for (const url of urls.slice(1)) {
        const next = await pixels(url);
        let count = 0;
        for (let i = 0; i < first.length; i += 4) {
          const delta = Math.max(
            Math.abs(first[i]! - next[i]!),
            Math.abs(first[i + 1]! - next[i + 1]!),
            Math.abs(first[i + 2]! - next[i + 2]!),
          );
          if (delta > 48) count += 1;
        }
        most = Math.max(most, count);
      }
      return most;
    }, urls);
  }

  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let gallery: Awaited<ReturnType<typeof createServer>> | undefined;
  let pane: Awaited<ReturnType<typeof createServer>> | undefined;
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    gallery = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await gallery.listen();
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await pane.listen();
    for (const [name, engine] of engines) {
      try {
        browsers.set(name, await engine.launch({ headless: true, timeout: 30_000 }));
      } catch (error) {
        if (process.env.GITHUB_ACTIONS === "true") throw error;
        console.warn(`scroll-flicker: ${name} cannot launch here, skipped`);
      }
    }
    await warmGalleryFrame(gallery, "agent-pane.composer-context", {
      browser: browsers.get("chromium"),
      params: { variant: "folder-long-list" },
    });
    await warmViteServer(pane, "/?mock");
  }, 280_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await gallery?.close();
    await pane?.close();
  });

  for (const [engine] of engines) {
    test(`${engine}: wheel through the composer's folder menu`, async () => {
      const browser = browsers.get(engine);
      if (!browser) return;
      const page = await browser.newPage({ viewport: { width: 900, height: 700 }, deviceScaleFactor: 2 });
      try {
        const { port } = gallery!.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-context", { variant: "folder-long-list", width: 900, height: 700 })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const trigger = page.getByRole("button", { name: /^Folder/ }).first();
        if ((await trigger.getAttribute("aria-expanded")) !== "true") await trigger.click();
        const viewport = page.locator(".acpmux-folder-popover .ui-combobox-viewport").first();
        await viewport.waitFor();
        expect(await viewport.evaluate((node) => node.scrollHeight > node.clientHeight)).toBe(true);
        const view = (await viewport.boundingBox())!;
        if (OUT) await page.screenshot({ path: path.join(OUT, `folder-menu-${engine}-open.png`) });
        await startRecorder(page, {
          parts: { menu: ".acpmux-folder-popover", strip: ".acpmux-composer-context" },
          scroller: ".acpmux-folder-popover .ui-combobox-viewport",
          rows: '[role="option"]',
          highlight: ".acpmux-folder-popover [data-highlighted]",
        });
        const pixels = await wheelAndCapture(
          page,
          { x: view.x + view.width / 2, y: view.y + view.height / 2 },
          STEPS,
          60,
          ".acpmux-composer-context",
          `folder-menu-${engine}`,
          false,
        );
        const report = await stopRecorder(page);
        console.log(
          `SCROLL-FLICKER ${JSON.stringify({ scene: "folder-menu", engine, ...report, stripPixels: pixels })}`,
        );
        expect(report.moved, "the menu and the composer strip moved or resized (px)").toEqual({ menu: 0, strip: 0 });
        expect(report.nodes, "the menu or the strip drawn as more than one node").toEqual({ menu: 1, strip: 1 });
        expect(report.blankFrames, "frames with part of the menu's rows missing").toBe(0);
        expect(report.shifts.count, "layout shifts").toBeLessThanOrEqual(0);
        expect(pixels.changedPixels, "strip pixels visibly changed while the menu scrolled").toBe(0);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: wheel through a 300-turn transcript`, async () => {
      const browser = browsers.get(engine);
      if (!browser) return;
      const page = await browser.newPage({ viewport: { width: 900, height: 760 }, deviceScaleFactor: 2 });
      try {
        const { port } = pane!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/?mock`);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<
          string,
          unknown
        >;
        expect(seeded.error).toBeUndefined();
        const scroller = page.locator(".acpmux-scroll").first();
        const view = (await scroller.boundingBox())!;
        // The seeded chat sits at its latest row and the composer is drawn before the first notch.
        await page.waitForFunction(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll");
          return (
            !!node &&
            node.scrollHeight - node.clientHeight - node.scrollTop <= 2 &&
            !!document.querySelector("form.acpmux-composer")
          );
        });
        if (OUT) await page.screenshot({ path: path.join(OUT, `transcript-${engine}-start.png`) });
        await startRecorder(page, {
          parts: { composer: "form.acpmux-composer" },
          scroller: ".acpmux-scroll",
          rows: ".acpmux-row",
        });
        const pixels = await wheelAndCapture(
          page,
          { x: view.x + view.width / 2, y: view.y + view.height / 3 },
          STEPS,
          -240,
          "form.acpmux-composer",
          `transcript-${engine}`,
          true,
        );
        const report = await stopRecorder(page);
        console.log(
          `SCROLL-FLICKER ${JSON.stringify({ scene: "transcript", engine, ...report, composerPixels: pixels })}`,
        );
        expect(report.moved.composer, "the composer moved or resized (px)").toBe(0);
        expect(report.nodes.composer, "the composer drawn as more than one node").toBe(1);
        expect(report.blankFrames, "frames with part of the transcript's rows missing").toBe(0);
        expect(report.shifts.count, "layout shifts").toBeLessThanOrEqual(0);
        expect(pixels.changedPixels, "composer pixels visibly changed while the transcript scrolled").toBe(0);
        // The pane's own load harness (loadDebug.ts loadTick): the scroll alone, then with a tool
        // running and the hat's time ticking; the composer must hold still and no history row remount.
        for (const [label, options] of [
          ["idle", { seconds: 6, tick_ms: 0, sidebar_ms: 0 }],
          ["running", { seconds: 8, tick_ms: 100, sidebar_ms: 250, background_commands: 1 }],
        ] as const) {
          const run = (await page.evaluate(
            (options) =>
              (window as any).cmuxAcpmuxDebug.loadTick({
                ...options,
                still: { composer: "form.acpmux-composer" },
                still_settle_ms: 1500,
              }),
            options,
          )) as Record<string, any>;
          const composer = run.still?.parts?.composer;
          console.log(
            `SCROLL-FLICKER ${JSON.stringify({
              scene: `transcript-loadtick-${label}`,
              engine,
              error: run.error ?? run.still?.error,
              frames: run.frames,
              history_mounts: run.history_mounts,
              remounts: run.remounts,
              content_rerenders: run.content_rerenders,
              composer_moved_px: composer?.moved_px,
              composer_nodes: composer?.nodes,
              composer_structure_mutations: composer?.structure_mutations,
              composer_renders: run.still?.renders?.composer ?? 0,
              composer_busiest: composer?.busiest,
            })}`,
          );
          expect(run.error ?? run.still?.error).toBeUndefined();
          expect(run.remounts, "history rows remounted").toBe(0);
          expect(composer?.moved_px, "the composer moved or resized (px)").toBeLessThanOrEqual(0.5);
          expect(composer?.nodes, "the composer drawn as more than one node").toBe(1);
          expect(run.still?.renders?.composer ?? 0, "composer renders").toBeLessThanOrEqual(1);
        }
      } finally {
        await page.close();
      }
    });
  }
});
