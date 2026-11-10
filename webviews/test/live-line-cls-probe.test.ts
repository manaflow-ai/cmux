// l10n-allow-file: probe fixture.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";

setDefaultTimeout(120_000);
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

for (const mode of ["live"] as const)
  for (const perStep of [2, 25])
    test(`probe ${mode} ${perStep} frames between steps`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await installPaintedFrames(page);
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.addInitScript(() => {
        const w = window as unknown as { __ls: { v: number; s: string[] }[] };
        w.__ls = [];
        new PerformanceObserver((list) => {
          for (const e of list.getEntries() as unknown as {
            value: number;
            hadRecentInput: boolean;
            sources: { node?: Node; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly }[];
          }[]) {
            if (e.hadRecentInput) continue;
            w.__ls.push({
              v: e.value,
              s: e.sources.map((src) => {
                const el = src.node instanceof Element ? src.node : src.node?.parentElement;
                const id = el?.closest("[data-row-id]")?.getAttribute("data-row-id") ?? "?";
                const r = (x: DOMRectReadOnly) => `${Math.round(x.y)}+${Math.round(x.height)}`;
                return `${el?.tagName}.${String(el?.className).split(" ")[0]}(${id}) ${r(src.previousRect)}->${r(src.currentRect)}`;
              }),
            });
          }
        }).observe({ type: "layout-shift", buffered: true });
      });
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showLiveRows" in window);
      const out = await page.evaluate(
        ({ mode, perStep }) =>
          new Promise<{ total: number; shifts: { v: number; s: string[] }[]; scroll: number[] }>((done) => {
            type Row = Record<string, unknown>;
            const w = window as unknown as {
              __showLiveRows(rows: Row[]): void;
              __showRawRows(rows: Row[]): void;
              __ls: { v: number; s: string[] }[];
            };
            const show = (rows: Row[]) => (mode === "live" ? w.__showLiveRows(rows) : w.__showRawRows(rows));
            const t0 = Date.now() - 60_000;
            const rows: Row[] = [];
            for (let i = 0; i < 20; i++) {
              rows.push({ id: `u${i}`, kind: "user", version: 1, at: t0 + i * 10, text: `Question ${i}` });
              rows.push({
                id: `a${i}`,
                kind: "assistant",
                version: 1,
                at: t0 + i * 10 + 5,
                text: `Answer ${i}. `.repeat(30),
              });
            }
            rows.push({ id: "ulive", kind: "user", version: 1, at: t0 + 500, text: "Go on" });
            show(rows);
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            scroller.scrollTop = scroller.scrollHeight;
            let frame = 0;
            let added = 0;
            const scroll: number[] = [];
            // Turns like the replay's: a prompt, a call, then a tall reply, perStep frames apart.
            const turn = (n: number, step: number): Row[] => {
              const at = t0 + 1000 + n * 50;
              const out: Row[] = [{ id: `pu${n}`, kind: "user", version: 1, at, text: `Prompt ${n}` }];
              if (step >= 1)
                out.push({
                  id: `pc${n}`,
                  kind: "activity",
                  version: step,
                  at: at + 1,
                  items: [{ kind: "tool", text: "", tool: { id: `c${n}`, title: "ls", kind: "execute", status: step >= 2 ? "completed" : "in_progress", command: "ls", startedAt: at } }],
                });
              if (step >= 2) out.push({ id: `pa${n}`, kind: "assistant", version: 1, at: at + 2, text: `Reply ${n}.\n\n` + "A long paragraph of the reply. ".repeat(60) });
              if (step >= 3) out.push({ id: `ps${n}`, kind: "turnSummary", version: 1, at: at + 3, status: "completed", durationMs: 3000, toolCount: 1 });
              return out;
            };
            const done_: Row[] = [];
            let n = 0;
            let step = -1;
            window.cmuxAfterPaint(
              () => {
                frame += 1;
                scroll.push(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight);
                if (n >= 6) {
                  done({ total: w.__ls.reduce((s, e) => s + e.v, 0), shifts: w.__ls, scroll });
                  return false;
                }
              },
              () => {
                if (frame < 20 || frame % perStep !== 0) return;
                step += 1;
                if (step > 3) {
                  done_.push(...turn(n, 3));
                  n += 1;
                  step = 0;
                }
                added += 1;
                show([...rows, ...done_, ...turn(n, step)]);
              },
            );
            w.__ls.length = 0;
          }),
        { mode, perStep },
      );
      await page.close();
      const by = new Map<string, number>();
      for (const e of out.shifts) for (const s of e.s) by.set(s.split(" ")[0]!, (by.get(s.split(" ")[0]!) ?? 0) + e.v);
      console.log(
        `PROBE ${mode} per=${perStep} cls=${out.total.toFixed(4)} n=${out.shifts.length} gap=${Math.max(...out.scroll)}\n` +
          [...by.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([k, v]) => `  ${k} ${v.toFixed(4)}`).join("\n") +
          "\n" +
          out.shifts.slice(0, 6).map((e) => `  ${e.v.toFixed(4)} ${e.s.join(" | ")}`).join("\n"),
      );
      expect(out.total).toBeGreaterThanOrEqual(0);
    });
