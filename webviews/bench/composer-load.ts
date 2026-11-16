// l10n-allow-file: benchmark diagnostics, not shipped UI.
import type { Frame, Page } from "playwright";

type Surface = Page | Frame;
type LoadReceipt = {
  running: boolean;
  started_epoch_ms: number;
  deltas: number;
  toolLines: number;
  elapsedMs: number;
  maxGapMs: number;
  error?: string;
};
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const quantile = (xs: number[], q: number) => [...xs].sort((a, b) => a - b)[Math.round((xs.length - 1) * q)] ?? null;

export async function seedComposer(surface: Surface, turns: number) {
  await surface.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const receipt = await surface.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  );
  if (receipt.error) throw new Error(`loadSeed: ${receipt.error}`);
  await surface.locator(PROMPT).first().waitFor({ timeout: 30_000 });
  return Number(receipt.rows);
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
  },
) {
  const { port, mode, length, keys, gap } = options;
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  const rows = await seedComposer(page, Math.ceil((mode === "L3" ? 100000 : length) / 3));
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
  const readLoads = () =>
    Promise.all(
      loads.map(
        (surface) => surface.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad()) as Promise<LoadReceipt>,
      ),
    );
  const before = await readLoads();
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
  const expected = Array.from({ length: keys }, (_, i) => "abcdefghijklmnopqrstuvwxyz"[i % 26]).join("");
  const late: number[] = [];
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
    };
  });
  const samples = result.typing.samples as {
    key: string;
    frame_timestamp_ms: number;
    paint: number;
    frame: number;
    paint_epoch_ms: number;
  }[];
  const frames = new Map<number, number>();
  for (const sample of samples) frames.set(sample.frame_timestamp_ms, (frames.get(sample.frame_timestamp_ms) ?? 0) + 1);
  const errors: string[] = [];
  if (
    samples.length !== keys ||
    result.typing.composer_text !== expected ||
    samples.map((s) => s.key).join("") !== expected
  )
    errors.push("key count, order or final text mismatch");
  if (mode === "L3" && rows < 100000) errors.push("fixture has fewer than 100000 rows");
  if ((quantile(late, 0.95) ?? Infinity) > gap) errors.push("driver missed input cadence");
  if (
    loadRates.some(
      (r) =>
        !r.running ||
        r.error ||
        !Number.isFinite(r.chunks_per_second) ||
        r.chunks_per_second < rate * 0.9 ||
        r.tool_lines_per_second < lines * 0.9 ||
        r.maxGapMs > 250 ||
        r.started_epoch_ms + r.elapsedMs < (samples.at(-1)?.paint_epoch_ms ?? Infinity) - 250,
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
    rows,
    keys: samples.length,
    valid: errors.length === 0,
    errors,
    measurement: "DOM-keydown-to-rAF; after-frame is a paint proxy; mock daemon",
    load_topology:
      mode === "L2" ? "5 visible + 5 hidden same-origin iframe documents; not native host tabs" : "focused document",
    to_frame_p50: result.typing.to_frame.p50_ms,
    to_frame_p95: result.typing.to_frame.p95_ms,
    to_frame_p99: result.typing.to_frame.p99_ms,
    to_frame_max: result.typing.to_frame.max_ms,
    to_paint_p95: result.typing.to_paint.p95_ms,
    to_paint_p99: result.typing.to_paint.p99_ms,
    to_listener_p95: result.typing.to_listener.p95_ms,
    to_work_p95: result.typing.to_work.p95_ms,
    frames_over_16_ms: result.watch.frames.filter((ms: number) => ms > 16).length,
    longest_observed_task_ms: result.watch.longest_observed_task_ms,
    long_task_supported: result.watch.long_task_supported,
    task_observation_threshold_ms: result.watch.task_observation_threshold_ms,
    keys_sharing_frame: [...frames.values()].filter((n) => n > 1).reduce((sum, n) => sum + n, 0),
    driver_late_p95_ms: quantile(late, 0.95),
    load_rates: loadRates,
    budget_p95_ms: 16,
    budget_p99_ms: 33,
    budget_policy: "report-only",
    target_met:
      errors.length === 0 && keys >= 200 && result.typing.to_paint.p95_ms <= 16 && result.typing.to_paint.p99_ms <= 33,
    renders: result.renders,
    samples,
  };
}
