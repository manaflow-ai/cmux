// l10n-allow-file: benchmark output, not shipped UI.
// Does a long-animation-frame observer keep an idle page drawing? N plain pages of one site in one renderer
// (--process-per-site, as the app's cmux-page), nothing on them changing, each with or without an empty
// PerformanceObserver of type long-animation-frame; one browser-wide trace of IDLE_S seconds counts the renderers'
// main-thread frames (BeginMainThreadFrame) and their CPU, per arm, arms interleaved.
//   bun bench/loaf-frames.bench.ts [pages=20] [rounds=2]
import { chromium } from "./browsers";

const PAGES = Number(process.argv[2] ?? 20);
const ROUNDS = Number(process.argv[3] ?? 2);
const IDLE_S = Number(process.env.IDLE_S ?? 10);

const html = (observe: boolean) =>
  `<!doctype html><html><body><p>An idle page.</p>${
    observe
      ? `<script>new PerformanceObserver(() => {}).observe({ type: "long-animation-frame", buffered: true });</script>`
      : ""
  }</body></html>`;
const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch(request) {
    const observe = new URL(request.url).pathname === "/loaf";
    return new Response(html(observe), { headers: { "content-type": "text/html" } });
  },
});

type Arm = { name: string; path: string; pages: number };
const arms: Arm[] = [
  { name: `plain x${PAGES}`, path: "/plain", pages: PAGES },
  { name: `loaf x${PAGES}`, path: "/loaf", pages: PAGES },
  { name: "plain x1", path: "/plain", pages: 1 },
  { name: "loaf x1", path: "/loaf", pages: 1 },
];

try {
  for (let round = 0; round < ROUNDS; round++)
    for (const arm of arms) {
      const browser = await chromium.launch({ headless: true, args: ["--process-per-site"] });
      try {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        for (let i = 0; i < arm.pages; i++) {
          const page = await context.newPage();
          await page.goto(`http://127.0.0.1:${server.port}${arm.path}`);
        }
        // fixed-wait: the pages' first frames end.
        await new Promise((resolve) => setTimeout(resolve, 3000));
        const cdp = await browser.newBrowserCDPSession();
        const events: {
          name: string;
          ph: string;
          pid: number;
          tid: number;
          dur?: number;
          tdur?: number;
          args?: { name?: string };
        }[] = [];
        cdp.on("Tracing.dataCollected", (payload: { value: object[] }) => {
          for (const event of payload.value) events.push(event as (typeof events)[number]);
        });
        await cdp.send("Tracing.start", {
          transferMode: "ReportEvents",
          traceConfig: {
            includedCategories: ["__metadata", "toplevel", "disabled-by-default-devtools.timeline.frame"],
            excludedCategories: ["*"],
          },
        });
        // fixed-wait: the window itself.
        await new Promise((resolve) => setTimeout(resolve, IDLE_S * 1000));
        const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
        await cdp.send("Tracing.end");
        await done;
        const threads = new Map<string, string>();
        const renderers = new Set<number>();
        for (const event of events) {
          if (event.ph !== "M") continue;
          if (event.name === "thread_name" && event.args?.name)
            threads.set(`${event.pid}:${event.tid}`, event.args.name);
          if (event.name === "process_name" && event.args?.name === "Renderer") renderers.add(event.pid);
        }
        let frames = 0;
        let mainMs = 0;
        for (const event of events) {
          if (!renderers.has(event.pid) || threads.get(`${event.pid}:${event.tid}`) !== "CrRendererMain") continue;
          if (event.name === "BeginMainThreadFrame") frames += 1;
          if (event.name === "ThreadControllerImpl::RunTask" && event.ph === "X")
            mainMs += (event.tdur ?? event.dur ?? 0) / 1000;
        }
        console.log(
          `loaf-frames: round ${round + 1} ${arm.name}: ${(frames / IDLE_S).toFixed(1)} main frames/s, ` +
            `main thread ${(mainMs / IDLE_S).toFixed(1)} ms/s, ${renderers.size} renderer(s)`,
        );
      } finally {
        await browser.close();
      }
    }
} finally {
  server.stop(true);
}
