// l10n-allow-file: bench output labels, not shipped UI.
// Scrolling up a long agent chat, page by page, at 1k, 10k and 100k rows (Leo, 2026-11-16: "i scroll up and it
// loads the shit"). The target (cmuxterm-hq docs/design/chat-instant-under-load.md): no loading row or blank; each
// older page drawn in under 50 ms p95; 100k rows within 1.2x of 1k. This runs bench/transcript-scroll-up.bench.ts
// once per size on the 100k-row chat's fixture (FIXTURE=flat ROWS=N, the chat of chat-100k-flat.bench.ts), the
// reader wheeling up from the latest message, and reads its summary per older page:
//   older_page_drawn  each older page the transcript asked for, from the ask to the first painted frame with its
//                     rows (ms p50/p95, max in the summary line); target 50 ms (TARGET_PAGE_MS)
//   loading_frames    frames the reader wheeled up and the view could not move with history left above: the wait
//                     for a page, what a person sees as loading; target 0
//   blank_frames      frames whose view showed no row, a missing row, a band no row covers or an edge gap past 8 px;
//                     target 0
//   anchor_shift      the largest move of the row under the pointer beyond what the wheel asked (px); target under 1
//   undrawn_pages     asks never drawn within 1 s of settling; target 0
//   older_page_drawn_scale  p95 at the largest size / p95 at the smallest (x); target 1.2 (TARGET_SCALE)
// The page's wire time (ask to reply from the in-page stand-in acpmux) is printed beside it; the stand-in is not
// the daemon, so the daemon's own page read (acpmux hub/paging.rs) is not a row here.
//   bun bench/transcript-scroll-up-scale.bench.ts
//   SIZES=1000,10000,100000 PAGES=16 MODE=wheel ENGINES=chromium bun bench/transcript-scroll-up-scale.bench.ts
// Prints one summary line per size and PERF_ROW lines (bench/perfRow.ts); bench/web-ui-suite.ts runs it as
// `transcript-scroll-up-scale` (perf-cron.py part web-ui-scroll-up). Exits 1 only when a size printed no summary
// (a missed target is a row over its target, not a failed bench).
/// <reference types="bun" />
import path from "node:path";
import { perfRow } from "./perfRow";

const SIZES = (process.env.SIZES ?? "1000,10000,100000").split(",").filter(Boolean).map(Number);
const PAGES = process.env.PAGES ?? "16";
const MODE = process.env.MODE ?? "wheel";
const ENGINES = (process.env.ENGINES ?? "chromium").split(",").filter(Boolean);
/// Each older page drawn within 50 ms p95, and the largest chat within 1.2x of the smallest.
export const TARGET_PAGE_MS = 50;
export const TARGET_SCALE = 1.2;
/// Per size; a 100k-row chat's fixture build and open take most of it.
const SIZE_TIMEOUT_MS = Number(process.env.SIZE_TIMEOUT_MS ?? 300_000);

export type ScrollUpSummary = Record<string, number | boolean | string | null>;

/// The summary keys of transcript-scroll-up.bench.ts for one engine (pure): its `transcript-scroll-up <engine>
/// <key>: <json>` lines.
export function parseSummary(stdout: string, engine: string): ScrollUpSummary {
  const out: ScrollUpSummary = {};
  const prefix = `transcript-scroll-up ${engine} `;
  for (const line of stdout.split("\n")) {
    if (!line.startsWith(prefix)) continue;
    const match = /^([A-Za-z0-9]+): (.*)$/.exec(line.slice(prefix.length));
    if (!match) continue;
    try {
      out[match[1]!] = JSON.parse(match[2]!) as ScrollUpSummary[string];
    } catch {
      out[match[1]!] = match[2]!;
    }
  }
  return out;
}

/// `1000` -> `1k`, `100000` -> `100k` (row names).
export const sizeLabel = (rows: number) => (rows % 1000 === 0 ? `${rows / 1000}k` : String(rows));

const num = (summary: ScrollUpSummary, key: string) => {
  const value = summary[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
};

async function measure(rows: number, engine: string) {
  const webviews = path.resolve(import.meta.dir, "..");
  const proc = Bun.spawn(["bun", path.join("bench", "transcript-scroll-up.bench.ts")], {
    cwd: webviews,
    env: {
      ...process.env,
      FIXTURE: "flat",
      ROWS: String(rows),
      PAGES,
      MODE,
      ENGINES: engine,
    },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  const timer = setTimeout(() => proc.kill("SIGKILL"), SIZE_TIMEOUT_MS);
  const [stdout, stderr, exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  return { summary: parseSummary(stdout, engine), stdout, stderr, exit };
}

let failed = false;
for (const engine of ENGINES) {
  const drawn = new Map<number, number>();
  for (const rows of SIZES) {
    const label = sizeLabel(rows);
    const { summary, stdout, stderr, exit } = await measure(rows, engine);
    const p95 = num(summary, "askToDrawnP95");
    const asks = num(summary, "asks") ?? 0;
    if (p95 === undefined || asks === 0) {
      failed = true;
      console.log(`transcript-scroll-up-scale ${engine} ${label}: no older page drawn (exit ${exit})`);
      const tail = [...stdout.split("\n"), ...stderr.split("\n")].filter((line) => line.trim()).slice(-20);
      for (const line of tail) console.log(`transcript-scroll-up-scale ${engine} ${label}! ${line}`);
      continue;
    }
    drawn.set(rows, p95);
    const pick = (key: string) => num(summary, key) ?? 0;
    console.log(
      `transcript-scroll-up-scale ${engine} ${label} ${MODE}: pages ${asks} drawn p50/p95/max ${pick("askToDrawnP50")}/${p95}/${pick("askToDrawnMax")} ms` +
        `, undrawn ${pick("undrawnAsks")}, loading frames ${pick("loadingFrames")}, blank frames ${pick("blankFrames")}` +
        ` (empty ${pick("emptyFrames")}), anchor shift max ${pick("driftMax")} px on ${pick("driftFrames")} frames` +
        `, wire p50/p95 ${pick("wireMsP50")}/${pick("wireMsP95")} ms (${pick("wireKiBP50")} KiB p50)` +
        `, frame p95 ${pick("frameP95")} ms, long tasks ${summary.longTasks ?? "n/a"} (${summary.longTaskMs ?? 0} ms)` +
        `, frames ${pick("frames")}`,
    );
    const base = `transcript_scroll_up_scale.${engine}.${MODE}.${label}`;
    perfRow({ name: `${base}.older_page_drawn`, p50: pick("askToDrawnP50"), p95, target: TARGET_PAGE_MS });
    perfRow({ name: `${base}.loading_frames`, p95: pick("loadingFrames"), unit: "frames", target: 0, floor: 1 });
    perfRow({ name: `${base}.blank_frames`, p95: pick("blankFrames"), unit: "frames", target: 0, floor: 1 });
    perfRow({ name: `${base}.anchor_shift`, p95: pick("driftMax"), unit: "px", target: 1, floor: 1 });
    perfRow({ name: `${base}.undrawn_pages`, p95: pick("undrawnAsks"), unit: "pages", target: 0, floor: 1 });
  }
  const smallest = Math.min(...SIZES);
  const largest = Math.max(...SIZES);
  const low = drawn.get(smallest);
  const high = drawn.get(largest);
  if (low !== undefined && high !== undefined && largest > smallest) {
    // A page drawn in under a frame at both sizes is flat whatever the ratio of two small numbers says.
    const ratio = Math.round((high / Math.max(low, 1)) * 100) / 100;
    console.log(
      `transcript-scroll-up-scale ${engine} ${MODE}: older page p95 ${sizeLabel(largest)} / ${sizeLabel(smallest)} = ${ratio}x (target ${TARGET_SCALE}x)`,
    );
    perfRow({
      name: `transcript_scroll_up_scale.${engine}.${MODE}.older_page_drawn_scale`,
      p95: ratio,
      unit: "x",
      target: TARGET_SCALE,
      floor: 0.2,
    });
  }
}
process.exit(failed ? 1 : 0);
