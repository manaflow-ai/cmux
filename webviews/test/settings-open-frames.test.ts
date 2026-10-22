// cmux-web-test-timeout: 240
// Leo, 2026-10-20: "the settings flicker is bad when you load it". Records every frame of a Settings
// open in real Chromium on the settings dev server, with the mock given the app's timing
// (mockTiming.ts: each call answers after 30 ms; a pooled page's calls wait for the host's claim).
// Each frame's signature: the rows drawn, the disabled controls, the controls' values, the rows'
// offsets, the selected section and the content's height. Every frame from the open to the settled
// page must already be the settled page (or blank before the first paint of a cold open); the test
// names the parts that changed in the frames that were not.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("settings-open-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("settings-open-frames: skipping (run `bunx playwright install chromium`)");
    describe.skip("settings open frames", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  let server: ChildProcess | null = null;
  let base = "";
  let browser: Browser | undefined;

  beforeAll(async () => {
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(
      path.join(webviews, "node_modules/.bin/vp"),
      ["dev", "--config", "vite.config.settings-page.mjs", "--port", String(port), "--strictPort"],
      { cwd: webviews, stdio: ["ignore", "pipe", "pipe"] },
    );
    base = `http://127.0.0.1:${port}`;
    // The server prints its address once it listens.
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`settings dev server exited ${code}`)));
    });
    await warmDevServer(base, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server compiles on the first load: load once untimed.
    const warm = await browser.newPage();
    await warm.goto(`${base}/?mock`);
    await warm.waitForSelector("[data-row-key]", { timeout: 60_000 });
    await warm.close();
  }, 180_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  /// Starts sampling one signature per painted frame (into window.openFrames).
  const SAMPLER = () => {
    type Frame = Record<string, string | number>;
    const frames: { at: number; shown: boolean; sig: Frame }[] = [];
    (window as unknown as { openFrames: typeof frames }).openFrames = frames;
    const start = performance.now();
    // The host shows the page from the frame its paint report names (PagePaintProbe.swift): one
    // animation frame after the page's gate (`__cmuxPaintAfter`) settles; before that, the pane keeps
    // what it showed. Frames before it are recorded as hidden.
    let shown = false;
    const showAfterGate = () => {
      const gate = (window as unknown as { __cmuxPaintAfter?: Promise<unknown> }).__cmuxPaintAfter;
      const show = () => requestAnimationFrame(() => (shown = true));
      if (gate && typeof gate.then === "function") gate.then(show, show);
      // In the app the page's module sets the gate before the probe's document-end read; on the
      // dev server its top-level awaits (strings, mock timing) set it after DOMContentLoaded. Wait
      // for it while nothing is drawn; a page that draws without a gate is shown at once.
      else if (!document.getElementById("root")?.firstChild) void window.cmuxPaintFrame().then(showAfterGate);
      else show();
    };
    (window as unknown as { showAfterGate: () => void }).showAfterGate = showAfterGate;
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", showAfterGate);
    window.cmuxAfterPaint(() => {
      const rows = [...document.querySelectorAll<HTMLElement>("[data-row-key]")].filter((row) => !row.inert);
      const first = rows.slice(0, 40);
      const controlState = (row: HTMLElement) =>
        [...row.querySelectorAll<HTMLElement>(".row-control input, .row-control button, .row-control [role]")]
          .map((node) => {
            const input = node as HTMLInputElement;
            return `${input.checked ? "x" : ""}${input.value ?? ""}${node.getAttribute("aria-checked") ?? ""}${node.textContent?.trim().slice(0, 24) ?? ""}`;
          })
          .join("|");
      const content = document.querySelector<HTMLElement>(".content");
      frames.push({
        at: performance.now() - start,
        shown,
        sig: {
          rows: rows.length,
          disabled: document.querySelectorAll(".row-control :disabled, .row-control [aria-disabled='true']").length,
          values: first.map((row) => `${row.dataset.rowKey}=${controlState(row)}`).join(";"),
          tops: first.map((row) => row.offsetTop).join(","),
          section:
            document.querySelector("[aria-current='page'], [aria-selected='true'], .section-item.selected")
              ?.textContent ?? "",
          height: content?.scrollHeight ?? 0,
          cards: document.querySelectorAll(".card, section").length,
        },
      });
      return performance.now() - start < 2500;
    });
  };

  async function framesOf(page: Page) {
    await page.waitForFunction(() => {
      const frames = (window as unknown as { openFrames?: { at: number }[] }).openFrames;
      return !!frames && frames.length > 0 && frames.at(-1)!.at >= 2400;
    });
    const all = await page.evaluate(
      () =>
        (
          window as unknown as {
            openFrames: { at: number; shown: boolean; sig: Record<string, string | number> }[];
          }
        ).openFrames,
    );
    const frames = all.filter((frame) => frame.shown);
    await page.close();
    const final = JSON.stringify(frames.at(-1)!.sig);
    // A frame before anything is drawn (a cold open's first paint) is the page loading, not a flicker.
    const drawn = frames.filter((frame) => Number(frame.sig.rows) > 0 || Number(frame.sig.cards) > 0);
    const off = drawn.filter((frame) => JSON.stringify(frame.sig) !== final);
    const changed: Record<string, number> = {};
    for (let index = 1; index < drawn.length; index++)
      for (const key of Object.keys(drawn[index].sig))
        if (drawn[index].sig[key] !== drawn[index - 1].sig[key]) changed[key] = (changed[key] ?? 0) + 1;
    const span = off.length ? off.at(-1)!.at - off[0].at : 0;
    const hidden = all.length - frames.length;
    return {
      frames: frames.length,
      hidden,
      off: off.length,
      span,
      changed,
      final: frames.at(-1)!.sig,
      firstOff: off[0]?.sig,
    };
  }

  test("a pooled Settings page claimed by the host draws its settled page from the first frame", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(`${base}/?mock&latency=30&parked`);
    // The spare sits parked (built, its calls held) until the host claims it: it is built once its
    // store has started and handed the paint gate its first screen to wait for at the claim.
    await page.waitForFunction(
      () => typeof (window as unknown as { __cmuxPageClaimReady?: unknown }).__cmuxPageClaimReady === "function",
    );
    await page.evaluate(SAMPLER);
    await page.evaluate(() => {
      const scope = window as unknown as { __cmuxSettingsClaim(): void; showAfterGate(): void };
      scope.__cmuxSettingsClaim();
      // The host's paint probe after a claim (PageWebView.swift: repaintsAtNextLayout).
      scope.showAfterGate();
    });
    const result = await framesOf(page);
    console.log(
      `settings-open pooled: ${result.frames} frames shown (${result.hidden} held), ${result.off} not the settled page over ${result.span.toFixed(0)} ms; ` +
        `changed: ${JSON.stringify(result.changed)}; rows ${result.final.rows}`,
    );
    if (process.env.SETTINGS_FRAMES_DEBUG)
      console.log(JSON.stringify({ first: result.firstOff, final: result.final }, null, 1).slice(0, 6000));
    expect(Number(result.final.rows)).toBeGreaterThan(0);
    expect(result.off).toBe(0);
  });

  test("a cold Settings open draws its settled page from its first drawn frame", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 760 } });
    await installPaintedFrames(page);
    await page.addInitScript(SAMPLER);
    await page.goto(`${base}/?mock&latency=30`);
    const result = await framesOf(page);
    console.log(
      `settings-open cold: ${result.frames} frames shown (${result.hidden} held), ${result.off} not the settled page over ${result.span.toFixed(0)} ms; ` +
        `changed: ${JSON.stringify(result.changed)}; rows ${result.final.rows}`,
    );
    expect(Number(result.final.rows)).toBeGreaterThan(0);
    expect(result.off).toBe(0);
  });
});
