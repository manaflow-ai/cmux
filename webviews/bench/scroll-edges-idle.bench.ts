// What a scroll-edge fade (src/ui/scrollEdges.ts) costs while the content it follows changes: a scroller of ROWS
// rows, followed as the summary card's body is, takes EDITS text edits a frame, each in its own task (as a running
// chat's clocks and live rows arrive), for FRAMES frames. It counts the edge reads (scrollHeight on the scroller),
// and the page's layouts and their time (CDP Performance.getMetrics). A read in an edit's task forces a layout of
// the tree that edit dirtied; a read at the frame shares the layout the frame does anyway.
//   bun bench/scroll-edges-idle.bench.ts [MODULE ...]
// Each MODULE is a copy of scrollEdges.ts to measure (default: this checkout's), so the base's copy
// (git show BASE:webviews/src/ui/scrollEdges.ts > base.ts) reads beside it in one run.
// l10n-allow-file: benchmark output, not shipped UI.
import path from "node:path";
import { chromium } from "./browsers";
import { perfRow } from "./perfRow";

const SIZES = (process.env.ROWS ?? "2000,20000").split(",").map(Number);
const FRAMES = Number(process.env.FRAMES ?? 60);
const EDITS = Number(process.env.EDITS ?? 8);
const modules = process.argv.slice(2);
if (modules.length === 0) modules.push(path.join(import.meta.dir, "../src/ui/scrollEdges.ts"));

async function bundle(file: string): Promise<string> {
  const built = await Bun.build({
    entrypoints: [path.resolve(file)],
    format: "esm",
    // The hook's React imports are not measured; the page has no React.
    plugins: [
      {
        name: "no-react",
        setup(build) {
          build.onResolve({ filter: /^react$/ }, () => ({ path: "react", namespace: "stub" }));
          build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({
            contents: "export const useCallback = (f) => f; export const useRef = (v) => ({ current: v });",
            loader: "js",
          }));
        },
      },
    ],
  });
  if (!built.success) throw new Error(built.logs.join("\n"));
  return built.outputs[0]!.text();
}

type Result = { reads: number; layouts: number; layoutMs: number; scriptMs: number };

const browser = await chromium.launch({ headless: true });
try {
  console.log(`rows | module | edge reads | layouts | layout ms | script ms   (${FRAMES} frames x ${EDITS} edits)`);
  for (const rows of SIZES) {
    for (const file of modules) {
      const code = await bundle(file);
      const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Performance.enable");
      await page.setContent(`<!doctype html><style>
        #scroller { height: 400px; overflow: auto; font: 13px sans-serif }
        .row { padding: 2px 8px }
      </style><div id="scroller"></div>`);
      await page.evaluate(
        async ({ code, rows }) => {
          const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
          const { followScrollEdges } = await import(url);
          const scroller = document.getElementById("scroller")!;
          const body = document.createElement("div");
          for (let at = 0; at < rows; at += 1) {
            const row = document.createElement("div");
            row.className = "row";
            row.textContent = `row ${at} 0s`;
            body.append(row);
          }
          scroller.append(body);
          const height = Object.getOwnPropertyDescriptor(Element.prototype, "scrollHeight")!.get!;
          const probe = window as unknown as { reads: number };
          probe.reads = 0;
          Object.defineProperty(scroller, "scrollHeight", {
            get() {
              probe.reads += 1;
              return height.call(this);
            },
          });
          followScrollEdges(scroller);
          await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        },
        { code, rows },
      );
      const metrics = async () =>
        Object.fromEntries(
          ((await cdp.send("Performance.getMetrics")).metrics as { name: string; value: number }[]).map((m) => [
            m.name,
            m.value,
          ]),
        );
      const before = await metrics();
      await page.evaluate(
        ({ frames, edits }) =>
          new Promise<void>((done) => {
            const probe = window as unknown as { reads: number };
            probe.reads = 0;
            const list = document.querySelector("#scroller > div")!.children;
            const channel = new MessageChannel();
            let edit = 0;
            channel.port1.onmessage = () => {
              const row = list[(edit * 7919) % list.length]!.firstChild as Text;
              row.data = `row ${edit} ${edit}s`;
              edit += 1;
            };
            let frame = 0;
            const tick = () => {
              if (frame++ >= frames) return done();
              for (let at = 0; at < edits; at += 1) channel.port2.postMessage(0);
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          }),
        { frames: FRAMES, edits: EDITS },
      );
      const after = await metrics();
      const result: Result = {
        reads: await page.evaluate(() => (window as unknown as { reads: number }).reads),
        layouts: after.LayoutCount! - before.LayoutCount!,
        layoutMs: (after.LayoutDuration! - before.LayoutDuration!) * 1000,
        scriptMs: (after.ScriptDuration! - before.ScriptDuration!) * 1000,
      };
      const name = path.basename(file, ".ts");
      console.log(
        `${rows} | ${name} | ${result.reads} | ${result.layouts} | ${result.layoutMs.toFixed(1)} | ${result.scriptMs.toFixed(1)}`,
      );
      if (modules.length === 1)
        perfRow({ name: `scroll_edges.idle_layout.${rows}`, p50: result.layoutMs, p95: result.layoutMs, clock: "cpu" });
      await page.close();
    }
  }
} finally {
  await browser.close();
}
