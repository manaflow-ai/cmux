// l10n-allow-file: benchmark diagnostics, not shipped UI.
import type { Frame, Page } from "playwright";

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
  error?: string;
};
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const quantile = (xs: number[], q: number) => [...xs].sort((a, b) => a - b)[Math.round((xs.length - 1) * q)] ?? null;
/// What the stream makes the direct client do while the keys are typed, by the client method that does it (as
/// test/agent-pane-older-paging-at-bottom.test.ts counts them): let go of its oldest held records, read an older
/// page, refold the held window. A heavy run that sheds 0 times did not reach the shed loop it is meant to price.
const CLIENT_COUNTS = {
  sheds: "shedOlderHeld",
  older_pages: "fetchOlder",
  refolds: "rebuildKeepingLiveState",
} as const;
type ClientCounts = Record<keyof typeof CLIENT_COUNTS, number>;

/// Finds the pane's direct client through React's fiber above the composer and wraps the counted methods; the counts
/// live on `window.__benchClientCounts`. Bench-only: it patches the live instance in the bench's page.
async function countClientWork(page: Page): Promise<string | undefined> {
  return page.evaluate(
    ({ selectors, methods }) => {
      const isClient = (value: any) =>
        !!value &&
        typeof value === "object" &&
        typeof value.lastSeq === "number" &&
        "selectedSessionId" in value &&
        typeof value.socket?.onmessage === "function";
      let client: any;
      for (const selector of selectors) {
        const element = document.querySelector(selector) as any;
        if (!element) continue;
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        for (let fiber = key ? element[key] : undefined; fiber && !client; fiber = fiber.return)
          for (let hook = fiber.memoizedState; hook && typeof hook === "object" && "next" in hook; hook = hook.next)
            if (isClient(hook.memoizedState?.current)) {
              client = hook.memoizedState.current;
              break;
            }
        if (client) break;
      }
      if (!client) return "no direct client found through the pane's fiber";
      const counts: Record<string, number> = {};
      for (const [name, method] of Object.entries(methods)) {
        const own = client[method];
        if (typeof own !== "function") return `the client has no ${method}`;
        counts[name] = 0;
        client[method] = function (this: unknown, ...args: unknown[]) {
          counts[name]! += 1;
          return own.apply(this, args);
        };
      }
      (window as any).__benchClient = client;
      (window as any).__benchClientCounts = counts;
      return undefined;
    },
    { selectors: [PROMPT, ".acpmux-scroll", ".acpmux-composer"], methods: CLIENT_COUNTS },
  );
}
const resetClientCounts = (page: Page) =>
  page.evaluate(() => {
    const counts = (window as any).__benchClientCounts as Record<string, number> | undefined;
    for (const name of Object.keys(counts ?? {})) counts![name] = 0;
  });
const readClientCounts = (page: Page) =>
  page.evaluate(() => {
    const counts = (window as any).__benchClientCounts as Record<string, number> | undefined;
    return counts ? { ...counts } : undefined;
  }) as Promise<ClientCounts | undefined>;

type HostPushReceipt = LoadReceipt & { held_before_keys: number; ms_to_held: number; last_pushed_seq: number };
/// `--held N`: the load as the host's pacer pushes it, raw frames through the client's own socket with one record per
/// tool line (the mock daemon's load folds a tick's lines into one update, about 120 records a second, so a chat
/// never grows past direct.ts `HELD_RECORDS` inside a run and never sheds). One open turn: a reply at `rate` chunks/s
/// and a call printing `lines` lines/s, every frame due pushed once per ~16 ms on a fixed schedule from the first
/// frame; the keys start once the client holds `held` records, so with `held` past `HELD_RECORDS` (4,000) the chat
/// sheds while they are typed. The receipt has the mock load's shape (debug `typingLoad`), so the same rate and
/// continuity checks apply.
async function startHostPush(page: Page, options: { rate: number; lines: number; held: number }) {
  const error = await page.evaluate(({ rate, lines, held }) => {
    const client = (window as any).__benchClient;
    if (!client) return "no direct client to push to";
    type Socket = { readyState: number; onmessage: ((message: { data: string }) => void) | null };
    let seq = client.lastSeq as number;
    const startSeq = seq;
    const startHeld = (client.events?.length ?? 0) as number;
    const id = JSON.stringify(client.selectedSessionId);
    const event = (kind: string, msg: string) =>
      `{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":${id},"seq":${++seq},"at":${Date.now()},"dir":"mux","kind":"${kind}","msg":${msg}}}`;
    const update = (body: string) =>
      `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":${id},"update":${body},"_meta":{"acpmux":{"seq":${++seq},"at":${Date.now()}}}}}`;
    const call = "bench-held-load";
    let chunks = 0;
    let toolLines = 0;
    const chunk = () =>
      update(
        `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":${JSON.stringify(`word ${++chunks} `)}}}`,
      );
    const line = () =>
      update(
        `{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"in_progress","_meta":{"terminal_output":{"data":${JSON.stringify(`[${++toolLines}] compiling module${toolLines % 97}.ts ok\n`)}}}}`,
      );
    const push = (frames: string[]) => {
      const socket = client.socket as Socket | undefined;
      for (const data of frames) if (socket && socket.readyState === 1) socket.onmessage?.({ data });
    };
    push([
      event("user_message", `{"text":"Build it"}`),
      event("turn_started", "{}"),
      update(
        `{"sessionUpdate":"tool_call","toolCallId":"${call}","title":"Run bun run build","kind":"execute","status":"in_progress","rawInput":{"command":"bun run build"}}`,
      ),
    ]);
    const t0 = performance.now();
    const receipt = {
      running: true,
      started_epoch_ms: performance.timeOrigin + t0,
      deltas: 0,
      toolLines: 0,
      elapsedMs: 0,
      maxGapMs: 0,
      maxScheduleOffsetMs: 0,
      held_before_keys: 0,
      ms_to_held: 0,
      last_pushed_seq: seq,
    };
    const state = { stopped: false, filled: false, receipt };
    (window as any).__hostPush = state;
    // Paced from the first frame, as the test streams: the keys start once the client holds `held` records.
    let last = t0;
    let sentChunks = 0;
    let sentLines = 0;
    const pump = () => {
      if (state.stopped) {
        receipt.running = false;
        return;
      }
      const now = performance.now();
      const elapsed = (now - t0) / 1000;
      receipt.maxGapMs = Math.max(receipt.maxGapMs, now - last);
      last = now;
      const dueChunks = Math.floor(elapsed * rate);
      const dueLines = Math.floor(elapsed * lines);
      // How late the oldest frame pushed in this tick is against its due time.
      const oldest = Math.min(
        sentChunks < dueChunks ? (sentChunks + 1) / rate : Infinity,
        lines > 0 && sentLines < dueLines ? (sentLines + 1) / lines : Infinity,
      );
      if (Number.isFinite(oldest))
        receipt.maxScheduleOffsetMs = Math.max(receipt.maxScheduleOffsetMs, now - t0 - oldest * 1000);
      const frames: string[] = [];
      for (; sentChunks < dueChunks; sentChunks += 1) frames.push(chunk());
      for (; sentLines < dueLines; sentLines += 1) frames.push(line());
      push(frames);
      receipt.deltas = sentChunks;
      receipt.toolLines = sentLines;
      receipt.elapsedMs = now - t0;
      receipt.last_pushed_seq = seq;
      // Counted as records taken in (held at the start plus pushed), not as held now: a client that sheds past
      // `HELD_RECORDS` holds fewer than it took.
      if (!state.filled && startHeld + (seq - startSeq) >= held) {
        receipt.held_before_keys = client.events?.length ?? 0;
        receipt.ms_to_held = Math.round(now - t0);
        state.filled = true;
      }
      if (elapsed < 120) setTimeout(pump, 16);
      else receipt.running = false;
    };
    setTimeout(pump, 16);
    return undefined;
  }, options);
  if (error) throw new Error(`held load: ${error}`);
  await page.waitForFunction(() => (window as any).__hostPush?.filled === true, null, { timeout: 60_000 });
}
const readHostPush = (page: Page) =>
  page.evaluate(() => ({
    ...(window as any).__hostPush.receipt,
    epoch_clock_error_ms: Date.now() - (performance.timeOrigin + performance.now()),
  })) as Promise<HostPushReceipt>;
/// The client's state after the keys, to say why a run did or did not shed: records held, the newest seq it applied
/// against the newest pushed, whether the view follows and whether an older page is in flight.
const readClientState = (page: Page) =>
  page.evaluate(() => {
    const client = (window as any).__benchClient;
    if (!client) return undefined;
    return {
      held_after_keys: client.events?.length ?? null,
      last_seq: client.lastSeq ?? null,
      last_pushed_seq: (window as any).__hostPush?.receipt.last_pushed_seq ?? null,
      following: client.following ?? null,
      loading_older: client.loadingOlder !== undefined,
      shed_retry_at: client.shedRetryAt ?? null,
    };
  });

export async function seedComposer(surface: Surface, turns: number) {
  await surface.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const receipt = await surface.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  );
  if (receipt.error) throw new Error(`loadSeed: ${receipt.error}`);
  await surface.locator(PROMPT).first().waitFor({ timeout: 30_000 });
  return {
    rows: Number(receipt.rows),
    logicalRows: Number(receipt.logical_rows ?? receipt.rows),
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
    /// `--held N` (L1 only): the load pushed as the host does, after filling the chat to N held records (`startHostPush`).
    held?: number;
  },
) {
  const { port, mode, length, keys, gap, held } = options;
  if (held !== undefined && mode !== "L1") throw new Error("--held applies to the focused stream (L1 / stream) only");
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  // A light turn reduces to prompt, reply and turnSummary (direct.ts turn_result).
  // Always report/check the actual model count too; the old fixture comment omits the summary.
  const requestedRows = mode === "L3" ? 100000 : length;
  const seed = await seedComposer(page, Math.ceil(requestedRows / 3));
  const rows = seed.rows;
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
  // Counted on the focused document's client; L2's load runs in other documents.
  const countError = await countClientWork(page);
  if (held !== undefined) await startHostPush(page, { rate, lines, held });
  for (const surface of held !== undefined ? [] : loads) {
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
  const readLoads = (): Promise<LoadReceipt[]> =>
    held !== undefined
      ? Promise.all([readHostPush(page)])
      : Promise.all(
          loads.map(
            (surface) => surface.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad()) as Promise<LoadReceipt>,
          ),
        );
  const before = await readLoads();
  // What the load made the client do before the first key (the stream's start), then counted again over the keys.
  const countsBeforeKeys = countError ? undefined : await readClientCounts(page);
  if (!countError) await resetClientCounts(page);
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
  const counts = countError ? undefined : await readClientCounts(page);
  const clientState = countError ? undefined : await readClientState(page);
  const after = await readLoads();
  if (held !== undefined) await page.evaluate(() => void ((window as any).__hostPush.stopped = true));
  else
    for (const surface of loads)
      await surface.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad({ stop: true }));
  const loadRates = after.map((receipt, i) => {
    const ms = receipt.elapsedMs - before[i]!.elapsedMs;
    return {
      ...receipt,
      chunks_per_second: (1000 * (receipt.deltas - before[i]!.deltas)) / ms,
      tool_lines_per_second: (1000 * (receipt.toolLines - before[i]!.toolLines)) / ms,
      max_schedule_offset_ms: receipt.maxScheduleOffsetMs,
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
  if (mode === "L3" && seed.logicalRows < 100000) errors.push("fixture requested fewer than 100000 logical rows");
  if (mode === "L3" && (!seed.seedReady || rows === 0))
    errors.push("fixture did not reach stable nonempty row readiness before deadline");
  if ((quantile(late, 0.95) ?? Infinity) > gap) errors.push("driver missed input cadence");
  if (
    !Number.isFinite(result.typing.epoch_clock_error_ms) ||
    Math.abs(result.typing.epoch_clock_error_ms) >= 2 ||
    loadRates.some((r) => !Number.isFinite(r.epoch_clock_error_ms) || Math.abs(r.epoch_clock_error_ms) >= 2)
  )
    errors.push("cross-document epoch clocks do not match wall time within 2ms");
  if (
    loadRates.some(
      (r) =>
        !r.running ||
        r.error ||
        !Number.isFinite(r.chunks_per_second) ||
        r.chunks_per_second < rate * 0.9 ||
        r.tool_lines_per_second < lines * 0.9 ||
        r.maxGapMs > 250 ||
        r.maxScheduleOffsetMs > 250 ||
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
  // A stream that never let go of a held record measured typing under that stream, not the shed loop.
  const shed =
    mode === "L0" || mode === "L2"
      ? "no focused stream"
      : !counts
        ? `not counted: ${countError}`
        : counts.sheds > 0
          ? "reached shed"
          : "did not reach shed";
  return {
    mode,
    requested_rows: requestedRows,
    logical_rows: seed.logicalRows,
    rows,
    seed_ready: seed.seedReady,
    seed_timed_out: seed.seedTimedOut,
    seed_deadline_ms: seed.seedDeadlineMs,
    keys: samples.length,
    valid: errors.length === 0,
    acceptance_eligible: errors.length === 0 && keys >= 200,
    minimum_acceptance_keys: 200,
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
    load_path: held !== undefined ? "host push, a record per tool line" : "mock daemon load",
    held_records: held ?? null,
    held_before_keys: held !== undefined ? ((after[0] as HostPushReceipt).held_before_keys ?? null) : null,
    sheds: counts?.sheds ?? null,
    older_pages: counts?.older_pages ?? null,
    refolds: counts?.refolds ?? null,
    shed,
    counts_before_keys: countsBeforeKeys ?? null,
    ms_to_held: held !== undefined ? ((after[0] as HostPushReceipt).ms_to_held ?? null) : null,
    client_after_keys: clientState ?? null,
    budget_p95_ms: 16,
    budget_p99_ms: 33,
    budget_policy: "report-only",
    target_met:
      errors.length === 0 && keys >= 200 && result.typing.to_paint.p95_ms <= 16 && result.typing.to_paint.p99_ms <= 33,
    renders: result.renders,
    samples,
  };
}
