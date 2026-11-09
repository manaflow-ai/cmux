// cmux-web-test-timeout: 240
// l10n-allow-file: browser regression diagnostics and synthetic fixture text.
// A completed preview already has its rows before mounting. Its first surface frame must not
// be an empty shell, or a chat main that receives those rows in a later task. Keep the benchmark's
// first-content selector: moving the marker to the transcript would hide the regression.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type SurfaceFrame = { at: number; main: boolean; rows: number; prompt: boolean; reply: boolean };
type InitialProbe = { frames: SurfaceFrame[]; stop: () => void };
type Geometry = {
  rows: { id: string | null; text: string; box: number[]; lines: number[][] }[];
  scroll: number[];
  main: number[];
};

await requireBrowserLane("gallery-transcript-first-frame.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.transcript";
  const params = { variant: "conversation", colorScheme: "dark" };
  const engines = { chromium, webkit };
  const browsers = new Map<string, Browser>();
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, params)}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    // No engine fallback: this regression needs both engines, including in an explicit fleet run.
    for (const [name, engine] of Object.entries(engines))
      browsers.set(name, await engine.launch({ headless: true, timeout: 30_000 }));
    await warmGalleryFrame(vite, entry, { browser: browsers.get("chromium"), params });
  });
  afterAll(async () => {
    try {
      await Promise.all([...browsers.values()].map((browser) => browser.close()));
    } finally {
      await vite?.close();
    }
  });

  for (const name of Object.keys(engines)) {
    test(`${name}: the first transcript frame is whole and an equal snapshot keeps its geometry`, async () => {
      const context = await browsers.get(name)!.newContext({
        viewport: { width: 1200, height: 800 },
        colorScheme: "dark",
      });
      const page = await context.newPage();
      try {
        await installPaintedFrames(page);
        await page.addInitScript(() => {
          const probe: InitialProbe = { frames: [], stop: () => {} };
          (window as unknown as { transcriptInitialProbe: InitialProbe }).transcriptInitialProbe = probe;
          const deadline = performance.now() + 90_000;
          probe.stop = window.cmuxAfterPaint(
            () => performance.now() < deadline && probe.frames.length < 600,
            (at) => {
              // DOM presence at rAF, exactly as bench/stability.ts firstContent. Geometry is
              // measured separately after paint, never before the page's ResizeObservers run.
              const root = document.querySelector("#root:not(.gallery-frame-loading) > *");
              if (!root) return;
              const rows = [...document.querySelectorAll(".acpmux-row[data-row-id]")];
              const text = rows.map((row) => row.textContent ?? "").join("\n");
              probe.frames.push({
                at,
                main: document.querySelector(".acpmux-main") !== null,
                rows: rows.length,
                prompt: text.includes("Add retries with backoff to the fetch helper"),
                reply: text.includes("What changed") && text.includes("The jitter keeps a fleet"),
              });
            },
          );
        });
        await page.goto(url(), { waitUntil: "domcontentloaded" });
        await page.waitForFunction(
          () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          undefined,
          {
            timeout: 60_000,
          },
        );
        const initial = await page.evaluate(async () => {
          await window.cmuxPaintFrame();
          const probe = (window as unknown as { transcriptInitialProbe: InitialProbe }).transcriptInitialProbe;
          probe.stop();
          return { ready: document.documentElement.dataset.galleryReady, frames: probe.frames };
        });
        expect(initial.ready).toBe("1");
        expect(initial.frames.length).toBeGreaterThan(0);
        expect(
          initial.frames.filter((frame) => !frame.main || frame.rows < 2 || !frame.prompt || !frame.reply),
        ).toEqual([]);

        // Read the actual loaded fixture, preserving its ids, versions and timestamps. Rebuilding
        // a similar chat here could accidentally exercise changed-data reconciliation instead.
        const result = await page.evaluate(async () => {
          const entryPath = new URL(location.href).searchParams.get("entryPath");
          if (!entryPath) throw new Error("The narrowed gallery entry path is missing");
          const moduleURL = new URL(entryPath, location.href).href;
          const fixture = (await import(/* @vite-ignore */ moduleURL)) as {
            default: { variants: { conversation: { snapshot: AcpmuxSnapshot } } };
          };
          const snapshot = structuredClone(fixture.default.variants.conversation.snapshot);
          const bridge = window.cmuxAcpmuxBridge;
          if (!bridge) throw new Error("The pane bridge did not mount");
          await document.fonts.ready;
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller) throw new Error("The transcript scroller did not mount");
          // Exercise an interior reading position when this viewport overflows, rather than only
          // a bottom-following chat. A short fixture still checks its real zero scroll position.
          scroller.scrollTop = Math.max(0, (scroller.scrollHeight - scroller.clientHeight) / 2);
          scroller.dispatchEvent(new Event("scroll"));
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
          const box = (rect: DOMRect) => [rect.x, rect.y, rect.width, rect.height];
          const read = (): Geometry => ({
            rows: [...document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) => {
              const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
              const lines: number[][] = [];
              for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (!node.textContent?.trim()) continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                lines.push(...[...range.getClientRects()].map(box));
              }
              return {
                id: row.getAttribute("data-row-id"),
                text: row.textContent ?? "",
                box: box(row.getBoundingClientRect()),
                lines,
              };
            }),
            scroll: [
              scroller.scrollTop,
              scroller.scrollLeft,
              scroller.scrollHeight,
              scroller.clientHeight,
              scroller.clientWidth,
            ],
            main: box(document.querySelector(".acpmux-main")!.getBoundingClientRect()),
          });
          const before = read();
          const frames: Geometry[] = [];
          await new Promise<void>((resolve, reject) => {
            const started = performance.now();
            let stop = () => {};
            const timeout = setTimeout(() => {
              stop();
              reject(new Error("No complete equal-snapshot frame window"));
            }, 5000);
            stop = window.cmuxAfterPaint(() => {
              frames.push(read());
              if (performance.now() - started < 500 || frames.length < 6) return;
              clearTimeout(timeout);
              stop();
              resolve();
            });
            try {
              bridge.receive(snapshot);
            } catch (error) {
              clearTimeout(timeout);
              stop();
              reject(error);
            }
          });
          return { before, frames };
        });
        expect(result.before.rows.length).toBeGreaterThanOrEqual(2);
        expect(result.frames.length).toBeGreaterThanOrEqual(6);
        for (const frame of result.frames) {
          expect(frame.rows.map(({ id, text }) => ({ id, text }))).toEqual(
            result.before.rows.map(({ id, text }) => ({ id, text })),
          );
          const dimensions = (sample: Geometry) => [
            ...sample.main,
            ...sample.scroll,
            ...sample.rows.flatMap((row) => [...row.box, ...row.lines.flat()]),
          ];
          const before = dimensions(result.before);
          const after = dimensions(frame);
          expect(after.length).toBe(before.length);
          expect(Math.max(...after.map((value, index) => Math.abs(value - before[index]!)))).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await context.close();
      }
    });
  }
});
