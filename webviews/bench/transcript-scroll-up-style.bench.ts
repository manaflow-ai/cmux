// l10n-allow-file: bench output labels, not shipped UI.
// What a fling frame restyles while flinging up a 100k-row chat (the setup of transcript-scroll-up.bench.ts
// FIXTURE=flat MODE=fling): the elements each frame mounted (a MutationObserver on the scroller, an added
// subtree's elements counted once) against the elements Chromium restyled (UpdateLayoutTree elementCount), from
// a trace with style invalidation tracking (styleInvalidationTrace.ts names what scheduled each restyle and the
// code that wrote it); then, in a second short fling, Chromium's selector stats (selectorStatsTrace.ts) and the
// stylesheet each top selector comes from.
//   FRAMES=24 bun bench/transcript-scroll-up-style.bench.ts
/// <reference types="bun" />
import { chromium } from "./browsers";
import type { Browser, Page } from "playwright";
import { papercutPane } from "../test/support/papercutChat";
import { traceUpwardAnchors } from "../test/support/upwardAnchorTrace";
import { reportTrace, traceWindow } from "./styleInvalidationTrace";
import { SELECTOR_STATS_CATEGORIES, reportRowCensus, reportSelectorStats } from "./selectorStatsTrace";

const ROWS = Number(process.env.ROWS ?? 100_000);
const FRAMES = Number(process.env.FRAMES ?? 24);
const STATS = process.env.STATS !== "0";
const chatTurns = Math.floor(ROWS / 2);
const out = (line: string) => console.log(`row-style ${line}`);

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any };

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

/// Elements added under the scroller per painted frame (a subtree counted once, its root and descendants).
async function watchAdded(page: Page) {
  await page.evaluate(() => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const frames: number[] = [];
    let added = 0;
    const observer = new MutationObserver((records) => {
      for (const record of records)
        for (const node of Array.from(record.addedNodes))
          if (node instanceof Element) added += 1 + node.getElementsByTagName("*").length;
    });
    observer.observe(scroller, { childList: true, subtree: true });
    let on = true;
    const tick = () => {
      if (!on) return;
      for (const record of observer.takeRecords())
        for (const node of Array.from(record.addedNodes))
          if (node instanceof Element) added += 1 + node.getElementsByTagName("*").length;
      frames.push(added);
      added = 0;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    (window as unknown as { __added: { frames: number[]; stop(): void } }).__added = {
      frames,
      stop: () => {
        on = false;
        observer.disconnect();
      },
    };
  });
}
async function stopAdded(page: Page) {
  return page.evaluate(() => {
    const held = (window as unknown as { __added: { frames: number[]; stop(): void } }).__added;
    held.stop();
    return held.frames;
  });
}
async function census(page: Page) {
  return page.evaluate(() => {
    const scroller = document.querySelector(".acpmux-scroll")!;
    const rows = document.querySelectorAll(".acpmux-row");
    return {
      documentElements: document.getElementsByTagName("*").length,
      scrollerElements: scroller.getElementsByTagName("*").length,
      rows: rows.length,
      rowElements: Array.from(rows).reduce((sum, row) => sum + 1 + row.getElementsByTagName("*").length, 0),
    };
  });
}

const pct = (values: number[], q: number) => {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))]!;
};
const sum = (values: number[]) => values.reduce((a, b) => a + b, 0);
const fling = (n: number) => Array.from({ length: n }, (_, frame) => -[1500, 2400, 1900, 3000, 2100][frame % 5]!);

try {
  const page = await pane.open({ width: 1100, height: 800 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const view = (await page.locator(".acpmux-scroll").boundingBox())!;
  await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
  // One fling round untraced: the first pages and caches warm.
  await page.evaluate(traceUpwardAnchors, { steps: fling(120), restFrames: 0 });
  out(`CENSUS before ${JSON.stringify(await census(page))}`);

  // (1) Invalidation tracking.
  await watchAdded(page);
  let painted = 0;
  const events = (await traceWindow(browser, page, async () => {
    const trace = await page.evaluate(traceUpwardAnchors, { steps: fling(FRAMES), restFrames: 0 });
    painted = trace.samples.length;
  })) as Ev[];
  const added = await stopAdded(page);
  const busy = added.filter((n) => n > 0);
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const ults: { ts: number; dur: number; el: number; forced: boolean }[] = [];
  const open = new Map<number, Ev>();
  for (const e of events) {
    if (!mains.has(`${e.pid}:${e.tid}`) || e.name !== "UpdateLayoutTree") continue;
    if (e.ph === "X")
      ults.push({
        ts: e.ts,
        dur: (e.dur ?? 0) / 1000,
        el: Number(e.args?.elementCount ?? 0),
        forced: !!e.args?.beginData?.stackTrace?.length,
      });
    else if (e.ph === "B") open.set(e.tid, e);
    else if (e.ph === "E" && open.has(e.tid)) {
      const b = open.get(e.tid)!;
      open.delete(e.tid);
      ults.push({
        ts: b.ts,
        dur: (e.ts - b.ts) / 1000,
        el: Number(e.args?.elementCount ?? b.args?.elementCount ?? 0),
        forced: !!b.args?.beginData?.stackTrace?.length,
      });
    }
  }
  ults.sort((a, b) => a.ts - b.ts);
  const restyled = sum(ults.map((u) => u.el));
  out(
    `FRAMES ${JSON.stringify({
      painted,
      rafFrames: added.length,
      framesThatMounted: busy.length,
      addedElements: sum(added),
      addedPerMountingFrame: { p50: pct(busy, 0.5), p95: pct(busy, 0.95), max: Math.max(0, ...busy) },
      ults: ults.length,
      forcedUlts: ults.filter((u) => u.forced).length,
      restyledElements: restyled,
      restyledPerPaintedFrame: Math.round(restyled / Math.max(1, painted)),
      addedPerPaintedFrame: Math.round(sum(added) / Math.max(1, painted)),
      restyledOverAdded: Math.round((restyled / Math.max(1, sum(added))) * 100) / 100,
      elementsPerUlt: {
        p50: pct(
          ults.map((u) => u.el),
          0.5,
        ),
        p95: pct(
          ults.map((u) => u.el),
          0.95,
        ),
      },
      styleMs: Math.round(sum(ults.map((u) => u.dur))),
      forcedStyleMs: Math.round(sum(ults.filter((u) => u.forced).map((u) => u.dur))),
      forcedElements: sum(ults.filter((u) => u.forced).map((u) => u.el)),
    })}`,
  );
  out(`ADDED-SEQ ${added.slice(0, 60).join(" ")}`);
  out(
    `ULT-SEQ ${ults
      .slice(0, 80)
      .map((u) => `${u.el}${u.forced ? "f" : ""}/${u.dur.toFixed(1)}`)
      .join(" ")}`,
  );
  out(`CENSUS after ${JSON.stringify(await census(page))}`);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("DOM.getDocument", { depth: -1 });
  await reportTrace("fling", events, { tokens: Math.max(1, painted) }, (file, line) => `${file}:${line + 1}`, cdp);

  // (2) Selector stats over a second short fling.
  if (STATS) {
    await browser.startTracing(page, { categories: SELECTOR_STATS_CATEGORIES });
    await page.evaluate(traceUpwardAnchors, { steps: fling(Math.max(8, Math.floor(FRAMES / 2))), restFrames: 0 });
    const raw = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: Ev[] };
    reportSelectorStats(raw.traceEvents, 40);
    await reportRowCensus(page);
  }
} finally {
  await pane.close();
  await browser?.close();
}
