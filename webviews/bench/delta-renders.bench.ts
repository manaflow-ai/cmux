// l10n-allow-file: benchmark output, not shipped UI.
// Renders per streamed delta, by component, at transcript lengths of 50, 500 and 5,000 rows (Leo,
// 2026-11-07: "if we think about our app (the agent chat/whatever) part of it like 'a website' then
// we can think about react and next.js..."). A delta should render its own row and what truly reads
// it (the live line, the scroll follow), and that count should not grow with the transcript.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) from the agent
// pane's Vite dev config, so the React Compiler pass the shipped bundle gets runs here too. Each
// length is a light chat (`cmuxAcpmuxDebug.loadSeed(turns, { light: true })`: a prompt, a reply
// and its worked line per turn, three rows, opened whole) with Session Info shown, then two streams in it, nothing scrolled:
//   text   one reply streamed in 24-character chunks every 12 ms (`loadRun`, no tool calls)
//   tool   one command whose output grows every 50 ms (`loadTick`, no other chat changes)
// Counts come from `acpmuxPerf.renders`: the pane root (AcpmuxPane), the transcript
// (VirtualTranscript), the header (ChatHeaderTools), the composer, Session Info's parts, and every
// row (`row:<id>`, its renderer) and row frame (`frame:<id>`). Each is printed per delta.
//   bun bench/delta-renders.bench.ts [--lengths 50,500,5000] [--seconds 3]
// The sidebar is native (Swift) and draws nothing in this page, so it has no row here.
/// <reference types="bun" />
import path from "node:path";
import { chromium, type Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "50,500,5000").split(",").map(Number);
const SECONDS = Number(flag("--seconds") ?? 3);
const webviews = path.resolve(import.meta.dir, "..");

type Renders = Record<string, number>;

/// One stream's renders per delta: the named components, and the rows (all row renders, and how
/// many distinct rows rendered at all).
function perDelta(renders: Renders, deltas: number) {
  const per = (value: number) => Math.round((value / Math.max(1, deltas)) * 100) / 100;
  const sum = (prefix: string) =>
    Object.entries(renders)
      .filter(([name]) => name.startsWith(prefix))
      .reduce((total, [, value]) => total + value, 0);
  const distinct = (prefix: string) => Object.keys(renders).filter((name) => name.startsWith(prefix)).length;
  return {
    deltas,
    pane: per(renders.pane ?? 0),
    transcript: per(renders.transcript ?? 0),
    header: per(renders.header ?? 0),
    composer: per(renders.composer ?? 0),
    sessionInfo: per(
      (renders["session-info:presence"] ?? 0) +
        (renders["session-info:panel"] ?? 0) +
        (renders["session-info:sections"] ?? 0),
    ),
    rowRenders: per(sum("row:")),
    rowFrames: per(sum("frame:")),
    rowsTouched: distinct("row:"),
    // The busiest counters, for where the renders went.
    busiest: Object.entries(renders)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 6)
      .map(([name, value]) => `${name}=${value}`)
      .join(" "),
  };
}

async function openChat(page: Page, port: number, turns: number) {
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
  const toggle = page.locator("button.acpmux-session-info-toggle").first();
  await toggle.waitFor({ timeout: 10_000 });
  if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
  await page.waitForFunction(
    () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
  );
  return seeded.rows as number;
}

const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });
try {
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  const { port } = vite.httpServer!.address() as { port: number };
  const table: ({ rows: number; stream: string } & ReturnType<typeof perDelta>)[] = [];
  for (const length of LENGTHS) {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    const rows = await openChat(page, port, Math.max(1, Math.round(length / 3)));
    const text = (await page.evaluate(
      (seconds) =>
        (window as any).cmuxAcpmuxDebug.loadRun({
          seconds,
          chunk_chars: 24,
          chunk_ms: 12,
          tool_every: 0,
          scroll_speed: 0,
        }),
      SECONDS,
    )) as Record<string, any>;
    const tool = (await page.evaluate(
      (seconds) => (window as any).cmuxAcpmuxDebug.loadTick({ seconds, tick_ms: 50, sidebar_ms: 0, scroll_speed: 0 }),
      SECONDS,
    )) as Record<string, any>;
    await page.close();
    table.push({ rows, stream: "text", ...perDelta(text.renders ?? {}, text.deltas ?? 0) });
    table.push({ rows, stream: "tool", ...perDelta(tool.renders ?? {}, tool.ticks ?? 0) });
  }
  console.table(table.map(({ busiest: _, ...row }) => row));
  for (const row of table) console.log(`${row.rows} ${row.stream}: ${row.busiest}`);
  console.log(`DELTA-RENDERS ${JSON.stringify(table)}`);
} finally {
  await browser.close();
  await vite.close();
}
