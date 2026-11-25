// l10n-allow-file: benchmark output, not shipped UI.
// What a key's frame waits on (composer-typing.bench.ts --frames; Leo, 2026-11-17: "why should typing... wait on
// rendering???"). A Chromium trace over the typed keys, read per key from its keydown to its paint
// (perf.ts marks `acpmux:key-frame` in the key's frame callback and `acpmux:key-paint` in the task after it):
//   own      the key's own task (keydown, beforeinput, input, the edit's microtasks), ms
//   between  main-thread work after the key's task and before its frame's task (stream deltas, timers), ms
//   idle     the rest of that gap: the main thread waiting for the display tick, ms
//   ahead    the key's frame task before the key's own callback: other frame callbacks (by function), ms
//   render   the frame task after the callback: style, layout, prepaint, paint, layerize, commit, observers, ms
//   after    from the frame task's end to the paint mark (what ran in between), ms
// It prints per-part p50 / p95, the functions ahead of the key and the work between by total ms per key, and a
// histogram of main-thread tasks over the window (the long-task breakdown).
import type { Browser, Page } from "playwright";

export const FRAME_CATEGORIES = [
  "toplevel",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.frame",
  "blink.user_timing",
];

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any; cat?: string };
type Span = { name: string; start: number; end: number; args?: any; depth: number };

export async function traceFrames(browser: Browser, page: Page, run: () => Promise<unknown>): Promise<Ev[]> {
  await browser.startTracing(page, { categories: FRAME_CATEGORIES });
  await run();
  return (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: Ev[] }).traceEvents;
}

const r2 = (v: number) => Math.round(v * 100) / 100;
const pct = (values: number[], q: number) => {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))]!;
};
const TASK = new Set(["ThreadControllerImpl::RunTask", "RunTask"]);
const RENDER = new Set([
  "UpdateLayoutTree",
  "Layout",
  "PrePaint",
  "Paint",
  "Layerize",
  "UpdateLayer",
  "CompositeLayers",
  "Commit",
  "IntersectionObserverController::computeIntersections",
  "ResizeObserverController::BroadcastObservations",
  "HitTest",
  "ScrollLayer",
]);

export function reportFrames(
  label: string,
  events: Ev[],
  map: (url: string, line: number, column: number) => string,
): Record<string, number> {
  const out = (line: string) => console.log(`KEY-FRAMES ${label} ${line}`);
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const onMain = events.filter((e) => mains.has(`${e.pid}:${e.tid}`)).sort((a, b) => a.ts - b.ts);
  // Spans from X events and B/E pairs, each with its nesting depth under the tasks.
  const spans: Span[] = [];
  const open = new Map<string, Ev[]>();
  for (const e of onMain) {
    if (e.ph === "X") spans.push({ name: e.name, start: e.ts, end: e.ts + (e.dur ?? 0), args: e.args, depth: 0 });
    else if (e.ph === "B") {
      const k = `${e.pid}:${e.tid}`;
      open.set(k, [...(open.get(k) ?? []), e]);
    } else if (e.ph === "E") {
      const k = `${e.pid}:${e.tid}`;
      const stack = open.get(k) ?? [];
      const b = stack.pop();
      if (b) spans.push({ name: b.name, start: b.ts, end: e.ts, args: { ...b.args, ...e.args }, depth: 0 });
    }
  }
  spans.sort((a, b) => a.start - b.start || b.end - a.end);
  const tasks = spans.filter((s) => TASK.has(s.name) && s.end > s.start);
  const marks = onMain.filter((e) => e.ph === "R" || e.ph === "I" || e.ph === "i" || e.ph === "n" || e.ph === "b");
  const markTimes = (name: string) =>
    onMain.filter((e) => e.name === name && e.cat?.includes("blink.user_timing")).map((e) => e.ts);
  const keyFrames = markTimes("acpmux:key-frame");
  const keyPaints = markTimes("acpmux:key-paint");
  void marks;
  const keydowns = spans.filter((s) => s.name === "EventDispatch" && s.args?.data?.type === "keydown");
  const taskAt = (ts: number) => tasks.find((t) => t.start <= ts && t.end >= ts);
  const within = (t: { start: number; end: number }) => spans.filter((s) => s.start >= t.start && s.end <= t.end);
  const fnOf = (s: Span) => {
    const d = s.args?.data ?? s.args?.beginData ?? {};
    const file =
      String(d.url ?? "")
        .split("/")
        .pop()
        ?.split("?")[0] ?? "";
    const where = file ? map(file, Math.max(0, (d.lineNumber ?? 1) - 1), Math.max(0, (d.columnNumber ?? 1) - 1)) : "";
    return `${d.functionName || "(anon)"}${where ? `@${where}` : ""}`;
  };
  /// What a task did: its first script entry (function and where), else its biggest child's name.
  const whatTask = (t: Span) => {
    const inner = within(t).filter((s) => s !== t);
    const call = inner.find(
      (s) => s.name === "FunctionCall" || s.name === "TimerFire" || s.name === "FireAnimationFrame",
    );
    if (call) {
      const fn = inner.find((s) => s.name === "FunctionCall" && s.start >= call.start && s.end <= call.end) ?? call;
      return `${call.name}:${fnOf(fn)}`;
    }
    const ev = inner.find((s) => s.name === "EventDispatch");
    if (ev) return `EventDispatch:${ev.args?.data?.type}`;
    const big = [...inner].sort((a, b) => b.end - b.start - (a.end - a.start))[0];
    return big ? big.name : t.name;
  };
  type Row = {
    own: number;
    between: number;
    idle: number;
    ahead: number;
    render: number;
    after: number;
    total: number;
  };
  const rows: Row[] = [];
  const aheadBy = new Map<string, number>();
  const betweenBy = new Map<string, number>();
  const renderBy = new Map<string, number>();
  const afterBy = new Map<string, number>();
  const add = (m: Map<string, number>, k: string, v: number) => m.set(k, (m.get(k) ?? 0) + v);
  for (const kd of keydowns) {
    const keyTask = taskAt(kd.start);
    const frameMark = keyFrames.find((ts) => ts >= kd.start);
    if (!keyTask || frameMark === undefined) continue;
    const paintMark = keyPaints.find((ts) => ts >= frameMark);
    const frameTask = taskAt(frameMark);
    if (!frameTask || paintMark === undefined || frameTask === keyTask) continue;
    // A key whose frame mark belongs to the next key (two keys in one frame) is skipped.
    const nextKd = keydowns.find((k) => k.start > kd.start);
    if (nextKd && nextKd.start < frameMark) continue;
    const own = (keyTask.end - keyTask.start) / 1000;
    const gapTasks = tasks.filter((t) => t.start >= keyTask.end && t.end <= frameTask.start);
    const between = gapTasks.reduce((s, t) => s + (t.end - t.start), 0) / 1000;
    for (const t of gapTasks) add(betweenBy, whatTask(t), (t.end - t.start) / 1000);
    const idle = Math.max(0, (frameTask.start - keyTask.end) / 1000 - between);
    const inFrame = within(frameTask).filter((s) => s !== frameTask);
    // The frame callbacks that ran before the key's own (FireAnimationFrame ending before its mark).
    const aheadSpans = inFrame.filter((s) => s.name === "FireAnimationFrame" && s.end <= frameMark);
    const ahead = (frameMark - frameTask.start) / 1000;
    for (const s of aheadSpans) {
      const fn = inFrame.find((c) => c.name === "FunctionCall" && c.start >= s.start && c.end <= s.end);
      add(aheadBy, fn ? fnOf(fn) : "FireAnimationFrame", (s.end - s.start) / 1000);
    }
    const aheadOther = ahead - aheadSpans.reduce((s, a) => s + (a.end - a.start), 0) / 1000;
    if (aheadOther > 0) add(aheadBy, "(frame start, not a callback)", aheadOther);
    const render = (frameTask.end - frameMark) / 1000;
    for (const s of inFrame.filter((c) => c.start >= frameMark && RENDER.has(c.name)))
      add(renderBy, s.name, (s.end - s.start) / 1000);
    for (const s of inFrame.filter((c) => c.start >= frameMark && c.name === "FireAnimationFrame"))
      add(renderBy, "FireAnimationFrame after the key's", (s.end - s.start) / 1000);
    const after = Math.max(0, (paintMark - frameTask.end) / 1000);
    for (const t of tasks.filter((t) => t.start >= frameTask.end && t.end <= paintMark))
      add(afterBy, whatTask(t), (t.end - t.start) / 1000);
    rows.push({ own, between, idle, ahead, render, after, total: (paintMark - kd.start) / 1000 });
  }
  const n = rows.length || 1;
  const parts = ["own", "between", "idle", "ahead", "render", "after", "total"] as const;
  const summary: Record<string, number> = { keys: rows.length };
  for (const p of parts) {
    summary[`${p}_p50`] = r2(
      pct(
        rows.map((x) => x[p]),
        0.5,
      ),
    );
    summary[`${p}_p95`] = r2(
      pct(
        rows.map((x) => x[p]),
        0.95,
      ),
    );
    summary[`${p}_mean`] = r2(rows.reduce((s, x) => s + x[p], 0) / n);
  }
  out(`SUMMARY ${JSON.stringify(summary)}`);
  const top = (m: Map<string, number>, k = 12) =>
    [...m.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, k)
      .map(([name, ms]) => `${r2(ms / n)}ms ${name}`)
      .join(" | ");
  out(`AHEAD per key: ${top(aheadBy)}`);
  out(`BETWEEN per key: ${top(betweenBy)}`);
  out(`RENDER per key: ${top(renderBy)}`);
  out(`AFTER per key: ${top(afterBy)}`);
  // Worst keys, whole.
  const worst = rows
    .map((x, i) => ({ i, ...x }))
    .sort((a, b) => b.total - a.total)
    .slice(0, 6)
    .map((x) => parts.map((p) => `${p}=${r2(x[p])}`).join(" "));
  out(`WORST ${JSON.stringify(worst)}`);
  // Long-task breakdown over the whole window: every main-thread task by duration, and what the big ones were.
  const first = keydowns[0]?.start ?? 0;
  const last = keyPaints[keyPaints.length - 1] ?? Number.POSITIVE_INFINITY;
  const windowTasks = tasks.filter((t) => t.start >= first && t.end <= last);
  const buckets = [1, 4, 8, 16, 50, Number.POSITIVE_INFINITY];
  const hist: Record<string, { n: number; ms: number }> = {};
  for (const t of windowTasks) {
    const ms = (t.end - t.start) / 1000;
    const b = buckets.find((edge) => ms < edge)!;
    const k = `<${b === Number.POSITIVE_INFINITY ? "inf" : b}`;
    hist[k] = { n: (hist[k]?.n ?? 0) + 1, ms: r2((hist[k]?.ms ?? 0) + ms) };
  }
  const busy = windowTasks.reduce((s, t) => s + (t.end - t.start), 0) / 1000;
  const span = (last - first) / 1000;
  out(
    `TASKS ${JSON.stringify({ window_ms: r2(span), busy_ms: r2(busy), busy_pct: r2((busy / Math.max(1, span)) * 100), hist })}`,
  );
  const bigBy = new Map<string, number>();
  for (const t of windowTasks.filter((t) => t.end - t.start >= 4000)) add(bigBy, whatTask(t), (t.end - t.start) / 1000);
  out(`TASKS >=4ms by what, ms per key: ${top(bigBy, 15)}`);
  return summary;
}
