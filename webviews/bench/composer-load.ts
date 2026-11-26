// l10n-allow-file: benchmark diagnostics, not shipped UI.
import type { Frame, Page } from "playwright";
import { waitForPageHook, watchPageErrors } from "./support/benchPage";
import leoNightly from "./profiles/leo-nightly.json";

type Surface = Page | Frame;
type LoadReceipt = {
  running: boolean;
  started_epoch_ms: number;
  epoch_clock_error_ms: number;
  deltas: number;
  toolLines: number;
  elapsedMs: number;
  maxGapMs: number;
  maxScheduleOffsetMs: number;
  /// The maxima since the `mark` taken when the typing window opened (see runComposerLoad).
  windowMaxGapMs: number;
  windowMaxScheduleOffsetMs: number;
  windowMaxGapEndMs: number;
  error?: string;
};
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
/// The page's percentile (perf.ts `summary`): the nearest rank, rounded to 0.01 ms.
const stage = (xs: number[], p: number) => {
  const sorted = [...xs].sort((a, b) => a - b);
  if (!sorted.length) return 0;
  return Math.round(sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! * 100) / 100;
};
const quantile = (xs: number[], q: number) => [...xs].sort((a, b) => a - b)[Math.round((xs.length - 1) * q)] ?? null;

/// The typing budgets on the app's display: a key on screen within 16 ms at p95 and 33 ms at p99 (#44416) on Leo's
/// 120 Hz display (bench/profiles/leo-nightly.json metrics.display_hz, the 11-26 profile; #58092 draws the sim ladder at
/// it for the same reason).
export const APP_BUDGET_P95_MS = 16;
export const APP_BUDGET_P99_MS = 33;
export const APP_DISPLAY_HZ = Number(leoNightly.metrics?.display_hz) || 120;

/// The app's budgets as read on a harness whose display refreshes every `refreshMs` (pure). A key waits for the
/// display's next refresh before its frame starts, a wait spread evenly over one refresh, so its keydown to paint
/// carries up to one refresh the work did not cause: on the app's 120 Hz display 8.3 ms, on headless Chromium and
/// Playwright's WebKit, both locked at 60 Hz, 16.7 ms. A 60 Hz harness read 16 ms at p95 against that wait alone
/// (its p95 is 15.8 ms with no work at all: WebKit's L0 keys read 18), so the budget measured the display, not the
/// page. The same allowance for the work, past one refresh of the harness's display instead of the app's, is the
/// budget plus the difference of the two refreshes: 24.3 and 41.3 ms at 60 Hz, the app's own at 120 Hz. A harness as
/// fast as the app or faster keeps the app's budgets.
export function displayBudgets(refreshMs: number, appHz = APP_DISPLAY_HZ): { p95: number; p99: number } {
  const extra = Number.isFinite(refreshMs) ? Math.max(0, refreshMs - 1000 / appHz) : 0;
  const round = (ms: number) => Math.round(ms * 100) / 100;
  return { p95: round(APP_BUDGET_P95_MS + extra), p99: round(APP_BUDGET_P99_MS + extra) };
}

/// The refresh of the display a page drew at, from its frame intervals (pure): their 10th percentile. A dropped
/// frame makes an interval longer and never shorter, so even a busy page's fastest intervals are its display's
/// refresh; with no intervals, Chromium's own 60 Hz.
export function displayRefreshMs(intervals: readonly number[]): number {
  const sorted = intervals.filter((ms) => Number.isFinite(ms) && ms > 0).sort((a, b) => a - b);
  if (sorted.length < 10) return 1000 / 60;
  return sorted[Math.floor((sorted.length - 1) * 0.1)]!;
}

export async function seedComposer(surface: Surface, turns: number, errors?: string[]) {
  // Not a bare waitForFunction: a page that threw while it mounted installs no hook, and the wait
  // then reads as `Timeout ... log: []` with nothing to point at (bench/support/benchPage.ts).
  await waitForPageHook(surface, "cmuxAcpmuxDebug", { timeout: 60_000, errors });
  const receipt = await surface.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  );
  if (receipt.error) throw new Error(`loadSeed: ${receipt.error}`);
  await surface.locator(PROMPT).first().waitFor({ timeout: 30_000 });
  return {
    rows: Number(receipt.rows),
    logicalRows: Number(receipt.logical_rows ?? receipt.rows),
    // The whole chat in the log the transcript pages from, and whether the held window is at its end (loadDebug.ts).
    modelRows: Number(receipt.model_rows),
    modelReady: receipt.model_ready === true,
    windowAtLatest: receipt.window_at_latest === true,
    seedReady: receipt.seed_ready === true,
    seedTimedOut: receipt.seed_timed_out === true,
    seedDeadlineMs: Number(receipt.seed_deadline_ms ?? 25_000),
  };
}

// Browser-only L2 puts five visible and five hidden documents in this renderer tree. Native
// tab/pane process placement and daemon/provider wakeups are measured by the Mac harness.
export async function runComposerLoad(
  page: Page,
  options: {
    port: number;
    mode: string;
    length: number;
    keys: number;
    gap: number;
    stream: number;
    toolLines: number;
    /// Around the typed keys only (a CPU profile of the window the keys wait in, not the setup).
    typing?: { start(): Promise<void>; stop(): Promise<void> };
  },
) {
  const { port, mode, length, keys, gap } = options;
  // Named apart from the acceptance `errors` list below: these are the page's own thrown/console errors,
  // collected from the goto onward so a pane that never installs its hook reports what it held instead.
  const pageErrors = watchPageErrors(page);
  const response = await page.goto(`http://127.0.0.1:${port}/?mock`);
  const status = response?.status();
  // A static server that answers `/` with a 404 body loads as a page: without this the bench waits
  // 60 s for hooks that page could never install (bench/support/benchPage.ts gotoBenchPage).
  if (status !== undefined && status >= 400)
    throw new Error(`runComposerLoad: http://127.0.0.1:${port}/?mock answered ${status}; the pane page is not there`);
  // A light turn reduces to prompt, reply and turnSummary (direct.ts turn_result).
  // Always report/check the actual model count too; the old fixture comment omits the summary.
  const requestedRows = mode === "L3" ? 100000 : length;
  const seed = await seedComposer(page, Math.ceil(requestedRows / 3), pageErrors);
  const rows = seed.rows;
  // L3's receipt, taken before any key: the model reports the full total and its own readiness.
  // The mounted window is diagnostic only; a paged transcript may not hold the newest row locally.
  const fullChat = seed.modelRows >= requestedRows && seed.modelReady;
  const backgrounds: Frame[] = [];
  if (mode === "L2") {
    await page.evaluate((port) => {
      document.body.style.width = "760px";
      for (let i = 0; i < 10; i++) {
        const frame = document.createElement("iframe");
        frame.name = `typing-background-${i}`;
        frame.src = `http://127.0.0.1:${port}/?mock`;
        frame.style.cssText = `position:fixed;right:0;top:${(i % 5) * 160}px;width:320px;height:160px;border:0`;
        document.body.append(frame);
      }
    }, port);
    // Resolve the documents only after all frame navigations install the app's debug surface.
    await page.waitForFunction(
      () => {
        const frames = [...document.querySelectorAll<HTMLIFrameElement>("iframe[name^='typing-background-']")];
        return (
          frames.length === 10 &&
          frames.every((frame) => frame.contentWindow && "cmuxAcpmuxDebug" in frame.contentWindow)
        );
      },
      null,
      { timeout: 60_000 },
    );
    // Sequential fixture creation bounds setup pressure; all streams start after all documents exist.
    for (let i = 0; i < 10; i++) {
      const element = page.locator(`iframe[name="typing-background-${i}"]`);
      const handle = await element.elementHandle();
      const frame = await handle?.contentFrame();
      if (!frame) throw new Error("background frame missing");
      await seedComposer(frame, 20);
      backgrounds.push(frame);
    }
    await page.evaluate(() => {
      document.querySelectorAll<HTMLIFrameElement>("iframe[name^='typing-background-']").forEach((frame, index) => {
        if (index >= 5) frame.style.display = "none";
      });
    });
  }
  const prompt = page.locator(PROMPT).first();
  await prompt.click();
  for (const key of "warm") await page.keyboard.press(key);
  for (let i = 0; i < 4; i++) await page.keyboard.press("Backspace");
  await page.waitForTimeout(500);
  const loads: Surface[] = mode === "L2" ? backgrounds : mode === "L0" ? [] : [page];
  const rate = mode === "L2" ? 30 : options.stream;
  const lines = mode === "L2" ? 0 : options.toolLines;
  for (const surface of loads) {
    const receipt = await surface.evaluate(
      ({ rate, lines }) =>
        (window as any).cmuxAcpmuxDebug.typingLoad({
          chunks_per_second: rate,
          tool_lines_per_second: lines,
          seconds: 120,
        }),
      { rate, lines },
    );
    if (receipt.error) throw new Error(receipt.error);
  }
  await page.waitForTimeout(500);
  const readLoads = (mark = false) =>
    Promise.all(
      loads.map(
        (surface) =>
          surface.evaluate(
            (mark) => (window as any).cmuxAcpmuxDebug.typingLoad(mark ? { mark: true } : undefined),
            mark,
          ) as Promise<LoadReceipt>,
      ),
    );
  // The rate and continuity checks below cover the window from here to the last key's paint: the
  // stream's first second (its tool row mounting, the page settling) is before any key is timed, so
  // a stall there says nothing about whether the keys were typed under the requested load.
  const before = await readLoads(true);
  await page.evaluate(() => {
    const debug = (window as any).cmuxAcpmuxDebug;
    debug.resetTyping();
    debug.renders();
    const frames: number[] = [];
    const tasks: number[] = [];
    let last: number | undefined;
    let raf = 0;
    const tick = (now: number) => {
      if (last !== undefined) frames.push(now - last);
      last = now;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    const supported = PerformanceObserver.supportedEntryTypes?.includes("longtask") ?? false;
    const record = (entries: PerformanceEntry[]) => {
      for (const entry of entries) tasks.push(entry.duration);
    };
    const observer = supported ? new PerformanceObserver((list) => record(list.getEntries())) : undefined;
    observer?.observe({ type: "longtask" });
    (window as any).__finishTypingWatch = () => {
      cancelAnimationFrame(raf);
      if (observer) record(observer.takeRecords());
      observer?.disconnect();
      // Long Tasks only observes >=50ms tasks. Zero observed is NOT a zero-cost main thread.
      return {
        frames,
        long_task_supported: supported,
        longest_observed_task_ms: supported ? Math.max(0, ...tasks) : null,
        task_observation_threshold_ms: supported ? 50 : null,
      };
    };
  });
  const clocksBefore = await readClocks(page, loads);
  const expected = Array.from({ length: keys }, (_, i) => "abcdefghijklmnopqrstuvwxyz"[i % 26]).join("");
  const late: number[] = [];
  await options.typing?.start();
  const started = performance.now();
  for (let i = 0; i < keys; i++) {
    const due = started + i * gap;
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, due - performance.now())));
    late.push(Math.max(0, performance.now() - due));
    await page.keyboard.press(expected[i]!);
  }
  // Flush only the final key's frame. Streams remain active through this read.
  await page.evaluate(
    () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
  );
  await options.typing?.stop();
  const result = await page.evaluate(() => {
    const debug = (window as any).cmuxAcpmuxDebug;
    return { typing: debug.typingStats(), renders: debug.renders(), watch: (window as any).__finishTypingWatch() };
  });
  const after = await readLoads();
  for (const surface of loads) await surface.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad({ stop: true }));
  const loadRates = after.map((receipt, i) => {
    const ms = receipt.elapsedMs - before[i]!.elapsedMs;
    return {
      ...receipt,
      chunks_per_second: (1000 * (receipt.deltas - before[i]!.deltas)) / ms,
      tool_lines_per_second: (1000 * (receipt.toolLines - before[i]!.toolLines)) / ms,
      max_schedule_offset_ms: receipt.maxScheduleOffsetMs,
      window_max_gap_ms: receipt.windowMaxGapMs,
      window_max_schedule_offset_ms: receipt.windowMaxScheduleOffsetMs,
      window_max_gap_end_ms: receipt.windowMaxGapEndMs,
    };
  });
  const samples = result.typing.samples as {
    key: string;
    frame_timestamp_ms: number;
    paint: number;
    frame: number;
    paint_epoch_ms: number;
    painted?: number;
    submitted?: number;
  }[];
  // Keydown to the paint of the frame that draws the key: that frame's own paint time where the page reports it
  // (Chromium's element timing, keyPresentation.ts `painted`), else the after-frame proxy (`paint`: a task posted
  // from the key's frame callback). Under a stream Chromium holds that posted task while input keeps coming: in a
  // traced L1 run the main thread sat idle for half of a 70 to 84 ms wait after the key's frame had painted (keydown
  // to that paint p95 18.4 ms, to the posted task 75 ms), so the proxy read the browser's task order, not the key.
  // WebKit reports no element timing and keeps the proxy.
  const toPaint = samples.map((s) => (Number.isFinite(s.painted) && s.painted! >= 0 ? s.painted! : s.paint));
  const presented = samples.flatMap((s) => (Number.isFinite(s.submitted) ? [s.submitted!] : []));
  const paintP95 = stage(toPaint, 0.95);
  const paintP99 = stage(toPaint, 0.99);
  const refreshMs = displayRefreshMs(result.watch.frames);
  const budgets = displayBudgets(refreshMs);
  const clocksAfter = await readClocks(page, loads);
  const frames = new Map<number, number>();
  for (const sample of samples) frames.set(sample.frame_timestamp_ms, (frames.get(sample.frame_timestamp_ms) ?? 0) + 1);
  const errors: string[] = [];
  if (
    samples.length !== keys ||
    result.typing.composer_text !== expected ||
    samples.map((s) => s.key).join("") !== expected
  )
    errors.push("key count, order or final text mismatch");
  // `rows` and `seedReady` describe the client's mounted window and are diagnostic only for L3.
  // The model receipt is the acceptance source: its total row count and model-ready bit prove the full chat.
  if (mode === "L3" && !fullChat) errors.push("model receipt does not report all 100000 rows ready");
  if ((quantile(late, 0.95) ?? Infinity) > gap) errors.push("driver missed input cadence");
  if (!clocksAgree(clocksBefore, clocksAfter)) errors.push("cross-document clocks do not agree within 2ms");
  const lastPaint = (samples.at(-1)?.paint_epoch_ms ?? Infinity) - clocksAfter.page_origin_ms;
  if (
    loadRates.some(
      (r, i) =>
        !r.running ||
        r.error ||
        !Number.isFinite(r.chunks_per_second) ||
        r.chunks_per_second < rate * 0.9 ||
        r.tool_lines_per_second < lines * 0.9 ||
        r.windowMaxGapMs > 250 ||
        r.windowMaxScheduleOffsetMs > 250 ||
        streamEndOnPageClock(r, clocksAfter.surfaces[i]) < lastPaint - 250,
    )
  )
    errors.push("requested stream rate or continuity not sustained");
  if (
    !samples.every(
      (s) =>
        Number.isFinite(s.frame) &&
        s.frame >= 0 &&
        Number.isFinite(s.paint) &&
        s.paint >= 0 &&
        Number.isFinite(s.frame_timestamp_ms),
    )
  )
    errors.push("missing or invalid timing samples");
  return {
    mode,
    requested_rows: requestedRows,
    logical_rows: seed.logicalRows,
    rows,
    seed_ready: seed.seedReady,
    seed_timed_out: seed.seedTimedOut,
    seed_deadline_ms: seed.seedDeadlineMs,
    model_rows: seed.modelRows,
    model_ready: seed.modelReady,
    window_at_latest: seed.windowAtLatest,
    full_chat_before_keys: fullChat,
    load_clock_offsets_ms: clocksAfter.surfaces.map((clock) => clock.offset_ms),
    keys: samples.length,
    valid: errors.length === 0,
    acceptance_eligible: errors.length === 0 && keys >= 200,
    minimum_acceptance_keys: 200,
    errors,
    measurement: samples.some((s) => Number.isFinite(s.painted))
      ? "DOM-keydown-to-rAF; to_paint is the key's frame's paint (element timing); mock daemon"
      : "DOM-keydown-to-rAF; after-frame is a paint proxy; mock daemon",
    painted_keys: samples.filter((s) => Number.isFinite(s.painted)).length,
    load_topology:
      mode === "L2" ? "5 visible + 5 hidden same-origin iframe documents; not native host tabs" : "focused document",
    to_frame_p50: result.typing.to_frame.p50_ms,
    to_frame_p95: result.typing.to_frame.p95_ms,
    to_frame_p99: result.typing.to_frame.p99_ms,
    to_frame_max: result.typing.to_frame.max_ms,
    to_paint_p95: paintP95,
    to_paint_p99: paintP99,
    // Report only: the after-frame proxy as before, and Chromium's presentation of the key's frame.
    to_paint_proxy_p95: result.typing.to_paint.p95_ms,
    to_paint_proxy_p99: result.typing.to_paint.p99_ms,
    to_presented_p95: presented.length ? stage(presented, 0.95) : undefined,
    to_listener_p95: result.typing.to_listener.p95_ms,
    to_work_p95: result.typing.to_work.p95_ms,
    frames_over_16_ms: result.watch.frames.filter((ms: number) => ms > 16).length,
    longest_observed_task_ms: result.watch.longest_observed_task_ms,
    long_task_supported: result.watch.long_task_supported,
    task_observation_threshold_ms: result.watch.task_observation_threshold_ms,
    keys_sharing_frame: [...frames.values()].filter((n) => n > 1).reduce((sum, n) => sum + n, 0),
    driver_late_p95_ms: quantile(late, 0.95),
    driver_late_max_ms: Math.max(0, ...late),
    driver_late_max_key: late.indexOf(Math.max(0, ...late)),
    load_rates: loadRates,
    display_refresh_ms: Math.round(refreshMs * 100) / 100,
    app_display_hz: APP_DISPLAY_HZ,
    app_budget_p95_ms: APP_BUDGET_P95_MS,
    app_budget_p99_ms: APP_BUDGET_P99_MS,
    budget_p95_ms: budgets.p95,
    budget_p99_ms: budgets.p99,
    budget_policy: "report-only",
    target_met: errors.length === 0 && keys >= 200 && paintP95 <= budgets.p95 && paintP99 <= budgets.p99,
    renders: result.renders,
    samples,
  };
}

/// Each load document's clock against the focused page's, read in one task in the page. An epoch time
/// (`performance.timeOrigin + now`) is not one clock across documents: each document pins its timeOrigin to the wall
/// clock once, when it is created, so two documents' epochs can disagree by the wall clock's steps and its 1 ms
/// grain, and neither matches `Date.now()` exactly. `performance.now()` in same-origin documents of one renderer
/// runs on one monotonic clock, so `offset_ms` (the document's now minus the page's) is constant; `read_ms` bounds it.
export type SurfaceClock = { offset_ms: number; origin_ms: number; read_ms: number };
export type LoadClocks = { page_origin_ms: number; surfaces: SurfaceClock[] };

async function readClocks(page: Page, loads: Surface[]): Promise<LoadClocks> {
  const names = loads.map((surface) => (surface === page ? null : (surface as Frame).name()));
  return page.evaluate((names) => {
    const surfaces = names.map((name) => {
      const other =
        name === null
          ? window
          : document.querySelector<HTMLIFrameElement>(`iframe[name="${CSS.escape(name)}"]`)?.contentWindow;
      if (!other) return { offset_ms: Number.NaN, origin_ms: Number.NaN, read_ms: Number.NaN };
      const before = performance.now();
      const theirs = other.performance.now();
      const after = performance.now();
      return {
        offset_ms: theirs - (before + after) / 2,
        origin_ms: other.performance.timeOrigin,
        read_ms: after - before,
      };
    });
    return { page_origin_ms: performance.timeOrigin, surfaces };
  }, names);
}

/// The clocks are one clock: every offset read within 2 ms, the same before the keys and after them.
export function clocksAgree(before: LoadClocks, after: LoadClocks): boolean {
  return (
    Number.isFinite(after.page_origin_ms) &&
    before.surfaces.length === after.surfaces.length &&
    before.surfaces.every((b, i) => {
      const a = after.surfaces[i]!;
      return (
        [b.offset_ms, a.offset_ms, b.read_ms, a.read_ms, a.origin_ms].every(Number.isFinite) &&
        b.read_ms < 2 &&
        a.read_ms < 2 &&
        Math.abs(a.offset_ms - b.offset_ms) < 2
      );
    })
  );
}

/// When a load's stream last made progress, on the focused page's `performance.now()` clock: its start in its own
/// document's clock (its epoch less that document's own timeOrigin), plus its elapsed time, less the offset.
export function streamEndOnPageClock(
  receipt: { started_epoch_ms: number; elapsedMs: number },
  clock: SurfaceClock | undefined,
): number {
  if (!clock) return Number.NaN;
  return receipt.started_epoch_ms - clock.origin_ms + receipt.elapsedMs - clock.offset_ms;
}
