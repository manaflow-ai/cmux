// l10n-allow-file: bench output labels, not shipped UI.
// Forced layouts while flinging up a 100k-row chat (the setup of transcript-scroll-up.bench.ts FIXTURE=flat
// MODE=fling): every Layout the page ran inside a script (a read of geometry with layout dirty), counted per
// fling frame and charged to the page function that asked, from a Chromium trace with stacks; and every
// getBoundingClientRect the page made, timed, so a batch of row reads shows whether only its first read paid
// (one layout for the batch) or each did (a write between reads).
//   ROUNDS=2 bun bench/transcript-scroll-up-layouts.bench.ts
/// <reference types="bun" />
import { chromium } from "./browsers";
import type { Browser } from "playwright";
import { papercutPane } from "../test/support/papercutChat";
import { traceUpwardAnchors } from "../test/support/upwardAnchorTrace";

const ROWS = Number(process.env.ROWS ?? 100_000);
const ROUNDS = Number(process.env.ROUNDS ?? 2);
const FRAMES = 120;
const chatTurns = Math.floor(ROWS / 2);

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  args?: {
    beginData?: { stackTrace?: { functionName: string }[] };
    data?: { stackTrace?: { functionName: string }[] };
  };
};

let browser: Browser | undefined;
browser = await chromium.launch({ headless: true });
const pane = await papercutPane(() => browser!, {
  turns: chatTurns,
  running: false,
  lead: [],
  attachPage: 160,
  session: { turnCount: chatTurns },
  daemonIndexes: true,
  askedPageSize: true,
  production: { minify: false },
});
try {
  const page = await pane.open({ width: 1100, height: 800 }, async (page) => {
    // Every getBoundingClientRect: its time and the page function that called it.
    await page.addInitScript(() => {
      const reads: { at: number; ms: number; by: string }[] = [];
      (window as unknown as { __reads: typeof reads; __readsOn: boolean }).__reads = reads;
      const own = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = function (this: Element) {
        const holder = window as unknown as { __readsOn: boolean };
        if (!holder.__readsOn) return own.call(this);
        const start = performance.now();
        const rect = own.call(this);
        const ms = performance.now() - start;
        const lines = (new Error().stack ?? "").split("\n").slice(2, 5);
        const by = lines.map((line) => /at (?:Element\.)?([\w$.]+)/.exec(line.trim())?.[1] ?? "?").join("<");
        reads.push({ at: start, ms, by });
        return rect;
      };
    });
  });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const view = (await page.locator(".acpmux-scroll").boundingBox())!;
  await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
  // One fling round untraced: the first pages and caches warm.
  const fling = Array.from({ length: FRAMES }, (_, frame) => -[1500, 2400, 1900, 3000, 2100][frame % 5]!);
  await page.evaluate(traceUpwardAnchors, { steps: fling, restFrames: 0 });
  const cdp = await page.context().newCDPSession(page);
  const events: TraceEvent[] = [];
  cdp.on("Tracing.dataCollected", (payload: { value: object[] }) => {
    for (const event of payload.value) events.push(event as TraceEvent);
  });
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: {
      includedCategories: [
        "devtools.timeline",
        "disabled-by-default-devtools.timeline",
        "disabled-by-default-devtools.timeline.stack",
      ],
      excludedCategories: ["*"],
    },
  });
  await page.evaluate(() => void ((window as unknown as { __readsOn: boolean }).__readsOn = true));
  let frames = 0;
  let blank = 0;
  let drift = 0;
  for (let round = 0; round < ROUNDS; round++) {
    const trace = await page.evaluate(traceUpwardAnchors, { steps: fling, restFrames: 0 });
    frames += trace.samples.length;
    for (const sample of trace.samples) {
      if (sample.drift !== null && Math.abs(sample.drift) > 1) drift += 1;
      if (
        sample.topRowId === null ||
        sample.missingRow ||
        sample.unexpectedRowBoxGap > 1 / 64 ||
        Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8
      )
        blank += 1;
    }
  }
  await page.evaluate(() => void ((window as unknown as { __readsOn: boolean }).__readsOn = false));
  const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
  await cdp.send("Tracing.end");
  await done;
  const reads = await page.evaluate(
    () => (window as unknown as { __reads: { at: number; ms: number; by: string }[] }).__reads,
  );

  // Forced layouts: Layout events on the main thread that carry a JS stack (a script asked for geometry).
  const layouts = events.filter((event) => event.name === "Layout" && event.ph === "X");
  const styles = events.filter((event) => event.name === "UpdateLayoutTree" && event.ph === "X");
  const stackOf = (event: TraceEvent) => event.args?.beginData?.stackTrace ?? event.args?.data?.stackTrace;
  const forced = layouts.filter((event) => (stackOf(event)?.length ?? 0) > 0);
  const forcedStyle = styles.filter((event) => (stackOf(event)?.length ?? 0) > 0);
  const byCaller = new Map<string, { count: number; ms: number }>();
  for (const event of forced) {
    const stack = stackOf(event)!;
    const key = stack
      .slice(0, 3)
      .map((frame) => frame.functionName || "(anon)")
      .join("<");
    const entry = byCaller.get(key) ?? { count: 0, ms: 0 };
    entry.count += 1;
    entry.ms += (event.dur ?? 0) / 1000;
    byCaller.set(key, entry);
  }
  const sum = (list: TraceEvent[]) => list.reduce((total, event) => total + (event.dur ?? 0) / 1000, 0);
  console.log(
    `layouts frames ${frames} blank ${blank} drift ${drift} layout ${layouts.length} (${sum(layouts).toFixed(0)} ms) forced ${forced.length} (${sum(forced).toFixed(0)} ms) forcedPerFrame ${(forced.length / frames).toFixed(2)} styleForced ${forcedStyle.length} (${sum(forcedStyle).toFixed(0)} ms)`,
  );
  for (const [key, entry] of [...byCaller].sort((a, b) => b[1].count - a[1].count).slice(0, 25))
    console.log(
      `layouts forced ${entry.count} (${(entry.count / frames).toFixed(2)}/frame, ${entry.ms.toFixed(0)} ms) ${key}`,
    );
  // Batches of reads: consecutive reads from the same caller with under 0.5 ms between them.
  const SLOW = 0.1;
  const batches: { by: string; reads: number; firstMs: number; restMs: number; slowAfterFirst: number }[] = [];
  let open: (typeof batches)[number] | undefined;
  let lastEnd = -Infinity;
  for (const read of reads) {
    if (open && open.by === read.by && read.at - lastEnd < 0.5) {
      open.reads += 1;
      open.restMs += read.ms;
      if (read.ms > SLOW) open.slowAfterFirst += 1;
    } else {
      open = { by: read.by, reads: 1, firstMs: read.ms, restMs: 0, slowAfterFirst: 0 };
      batches.push(open);
    }
    lastEnd = read.at + read.ms;
  }
  const byBatchCaller = new Map<
    string,
    { batches: number; reads: number; firstMs: number; restMs: number; slowAfterFirst: number; calls: number }
  >();
  for (const batch of batches) {
    const entry = byBatchCaller.get(batch.by) ?? {
      batches: 0,
      reads: 0,
      firstMs: 0,
      restMs: 0,
      slowAfterFirst: 0,
      calls: 0,
    };
    entry.batches += 1;
    entry.reads += batch.reads;
    entry.firstMs += batch.firstMs;
    entry.restMs += batch.restMs;
    entry.slowAfterFirst += batch.slowAfterFirst;
    byBatchCaller.set(batch.by, entry);
  }
  const allMs = reads.reduce((total, read) => total + read.ms, 0);
  console.log(`reads ${reads.length} (${allMs.toFixed(0)} ms) slow ${reads.filter((read) => read.ms > SLOW).length}`);
  for (const [key, entry] of [...byBatchCaller]
    .sort((a, b) => b[1].firstMs + b[1].restMs - a[1].firstMs - a[1].restMs)
    .slice(0, 20))
    console.log(
      `reads by ${key}: batches ${entry.batches} reads ${entry.reads} firstReadMs ${entry.firstMs.toFixed(0)} laterReadsMs ${entry.restMs.toFixed(0)} slowLaterReads ${entry.slowAfterFirst}`,
    );
} finally {
  await pane.close();
  await browser?.close();
}
