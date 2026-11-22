// l10n-allow-file: benchmark output, not shipped UI.
// Where an older page's time goes while the reader flings up (transcript-scroll-up.bench.ts SPLIT=1, Chromium).
// Each drawn page, its ask to the first frame that drew it, is cut into:
//   wait       the ask to the page's records in hand (direct.ts `fetchOlder` after `olderPage`: the reply parsed,
//              or a page read ahead already held)
//   fold       `publish` in `fetchOlder`: prepend, `foldOlder`, the rows published (one synchronous block)
//   react      CPU-profile samples after the publish, to the frame, whose stack holds React's work loop or commit
//              (render and commit apart); native leaves under them (a forced read) are left to style/layout
//   style      the trace's UpdateLayoutTree and Layout after the publish, to the frame, forced ones apart
// and the frames over 16.7 ms and long tasks of the whole run, each by what filled it and whether it falls inside
// a page's fold-to-drawn window. Clocks: the page's (performance.now) reaches the trace's through the
// `console.timeStamp("cmux-older <phase> <ask> <at>")` stamps; the CPU profile and the trace share TimeTicks.

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any };
type Node = { id: number; callFrame: { functionName: string; url: string }; children?: number[] };
export type CpuProfile = { nodes: Node[]; samples: number[]; timeDeltas: number[]; startTime: number };
export type SplitInput = {
  asks: { askAt: number; settledAt: number; drawnAt: number }[];
  reply: number[];
  fold: number[];
  published: number[];
  commits: number[];
  /// Each round's painted frames (the wheel moving; the harness pauses between rounds).
  frames: number[][];
  longSpans: [number, number][];
};

const RENDER =
  /^(performWorkOnRoot|performSyncWorkOnRoot|performWorkOnRootViaSchedulerTask|renderRootSync|renderRootConcurrent|workLoopSync|workLoopConcurrent\w*|performUnitOfWork|beginWork|completeUnitOfWork|completeWork|flushSyncWorkAcrossRoots_impl|processRootScheduleInMicrotask)$/;
const COMMIT =
  /^(commitRoot|commitRootImpl|flushMutationEffects|flushLayoutEffects|flushPassiveEffects|flushSpawnedWork|commitMutationEffects\w*|commitLayoutEffects\w*|commitPassive\w*|commitHookEffectList\w*)$/;
const SPECIAL = new Set(["(program)", "(garbage collector)", "(idle)", "(root)"]);

const pct = (values: number[], q: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((q / 100) * sorted.length))]!;
};
const r1 = (v: number) => Math.round(v * 10) / 10;

export function reportOlderSplit(events: Ev[], profile: CpuProfile | undefined, input: SplitInput) {
  const out = (line: string) => console.log(`OLDER-SPLIT ${line}`);
  // Page ms -> trace ms.
  let offset: number | undefined;
  for (const e of events) {
    if (e.name !== "TimeStamp") continue;
    const match = /^cmux-older \w+ -?\d+ ([\d.]+)$/.exec(String(e.args?.data?.message ?? ""));
    if (match) {
      offset = e.ts / 1000 - Number(match[1]);
      break;
    }
  }
  if (offset === undefined) return out("no cmux-older stamps in the trace");
  const at = (page: number) => page + offset!;
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const main = events.filter((e) => mains.has(`${e.pid}:${e.tid}`)).sort((a, b) => a.ts - b.ts);
  // Style and layout spans (trace ms), forced ones carry the script stack that forced them.
  type Span = { from: number; to: number; kind: "style" | "layout"; forced: boolean };
  const work: Span[] = [];
  const paint: { from: number; to: number }[] = [];
  const open = new Map<string, Ev>();
  for (const e of main) {
    const isWork = e.name === "Layout" || e.name === "UpdateLayoutTree";
    const isPaint = e.name === "Paint" || e.name === "PrePaint" || e.name === "Layerize" || e.name === "Commit";
    if (!isWork && !isPaint) continue;
    if (e.ph === "B") {
      open.set(e.name, e);
      continue;
    }
    const begin = e.ph === "E" ? open.get(e.name) : e;
    if (!begin) continue;
    open.delete(e.name);
    const to = (e.ph === "X" ? e.ts + (e.dur ?? 0) : e.ts) / 1000;
    if (isPaint) {
      paint.push({ from: begin.ts / 1000, to });
      continue;
    }
    const stack = begin.args?.beginData?.stackTrace;
    work.push({
      from: begin.ts / 1000,
      to,
      kind: e.name === "Layout" ? "layout" : "style",
      forced: Array.isArray(stack) && stack.length > 0,
    });
  }
  const overlap = (a: number, b: number, from: number, to: number) => Math.max(0, Math.min(b, to) - Math.max(a, from));
  const spanMs = (
    spans: { from: number; to: number }[],
    a: number,
    b: number,
    keep: (s: any) => boolean = () => true,
  ) => spans.reduce((sum, s) => (keep(s) ? sum + overlap(a, b, s.from, s.to) : sum), 0);
  // CPU samples (trace ms), each classified once.
  type Sample = {
    at: number;
    ms: number;
    kind: "fold" | "render" | "commit" | "reactNative" | "js" | "program" | "gc";
  };
  const samples: Sample[] = [];
  if (profile) {
    const byId = new Map(profile.nodes.map((node) => [node.id, node]));
    const parents = new Map<number, Node>();
    for (const node of profile.nodes) for (const child of node.children ?? []) parents.set(child, node);
    const kindOf = new Map<number, Sample["kind"] | "idle">();
    let clock = profile.startTime / 1000;
    profile.samples.forEach((id, index) => {
      const ms = (profile.timeDeltas[index + 1] ?? profile.timeDeltas[index] ?? 0) / 1000;
      clock += (profile.timeDeltas[index] ?? 0) / 1000;
      let kind = kindOf.get(id);
      if (kind === undefined) {
        const leaf = byId.get(id)!;
        const name = leaf.callFrame.functionName;
        if (name === "(idle)") kind = "idle";
        else if (name === "(program)") kind = "program";
        else if (name === "(garbage collector)") kind = "gc";
        else {
          let render = false;
          let commit = false;
          let fold = false;
          for (let node: Node | undefined = leaf; node; node = parents.get(node.id)) {
            const fn = node.callFrame.functionName;
            if (fn === "foldOlder" || fn === "publishPage" || fn === "prependOlderEventRecords") fold = true;
            if (COMMIT.test(fn)) commit = true;
            else if (RENDER.test(fn)) render = true;
          }
          const native = !leaf.callFrame.url && !SPECIAL.has(name);
          kind = fold ? "fold" : commit || render ? (native ? "reactNative" : commit ? "commit" : "render") : "js";
        }
        kindOf.set(id, kind);
      }
      if (kind !== "idle") samples.push({ at: clock, ms, kind });
    });
  }
  const sampleMs = (a: number, b: number, kinds: Sample["kind"][]) =>
    samples.reduce((sum, s) => (s.at >= a && s.at < b && kinds.includes(s.kind) ? sum + s.ms : sum), 0);
  const before = (list: number[], limit: number) => list.filter((v) => v <= limit).at(-1);
  // Each drawn page.
  type Row = Record<string, number>;
  const rows: Row[] = [];
  const windows: [number, number][] = [];
  for (const ask of input.asks) {
    const published = before(input.published, ask.settledAt);
    if (published === undefined) continue;
    const fold = before(input.fold, published)!;
    const reply = before(input.reply, fold) ?? fold;
    const commit = input.commits.find((c) => c >= published) ?? ask.drawnAt;
    const a = at(published);
    const b = at(ask.drawnAt);
    const askToDrawn = ask.drawnAt - ask.askAt;
    windows.push([at(fold), b]);
    rows.push({
      askToDrawn,
      wait: Math.max(0, reply - ask.askAt),
      replyToFold: fold - reply,
      fold: published - fold,
      publishedToDrawn: ask.drawnAt - published,
      publishedToCommit: Math.max(0, commit - published),
      react: sampleMs(a, b, ["render", "commit"]),
      render: sampleMs(a, b, ["render"]),
      commit: sampleMs(a, b, ["commit"]),
      reactNative: sampleMs(a, b, ["reactNative"]),
      style: spanMs(work, a, b, (s) => s.kind === "style"),
      layout: spanMs(work, a, b, (s) => s.kind === "layout"),
      forced: spanMs(work, a, b, (s) => s.forced),
      styleLayout: spanMs(work, a, b),
      paint: spanMs(paint, a, b),
      otherJs: sampleMs(a, b, ["js"]),
      gc: sampleMs(a, b, ["gc"]),
      // While the page was out: what the main thread did meanwhile.
      waitBusyJs: sampleMs(at(ask.askAt), at(reply), ["js", "render", "commit", "reactNative", "fold"]),
      waitStyleLayout: spanMs(work, at(ask.askAt), at(reply)),
    });
  }
  const keys = rows.length ? Object.keys(rows[0]!) : [];
  out(`pages ${rows.length} of ${input.asks.length} drawn asks; samples ${samples.length}`);
  for (const key of keys) {
    const values = rows.map((row) => row[key]!);
    const share = rows.reduce((sum, row) => sum + row[key]! / row.askToDrawn, 0) / rows.length;
    out(
      `PAGE ${key} median ${r1(pct(values, 50))} p95 ${r1(pct(values, 95))} mean ${r1(values.reduce((s, v) => s + v, 0) / values.length)} share ${Math.round(share * 100)}%`,
    );
  }
  for (const [index, row] of rows.slice(0, 30).entries())
    out(
      `ROW ${index} ${Object.entries(row)
        .map(([k, v]) => `${k}=${r1(v)}`)
        .join(" ")}`,
    );
  // Frames over 16.7 ms (the painted frames' intervals) and long tasks, by what filled them.
  const inside = (a: number, b: number) => windows.some(([from, to]) => overlap(a, b, from, to) > 0);
  const fill = (a: number, b: number) => ({
    fold: sampleMs(a, b, ["fold"]),
    react: sampleMs(a, b, ["render", "commit"]),
    styleLayout: spanMs(work, a, b),
    paint: spanMs(paint, a, b),
    js: sampleMs(a, b, ["js"]),
    gc: sampleMs(a, b, ["gc"]),
    program: sampleMs(a, b, ["program"]),
  });
  const sumFill = (spans: [number, number][]) => {
    const total: Record<string, number> = {};
    for (const [a, b] of spans) for (const [k, v] of Object.entries(fill(a, b))) total[k] = (total[k] ?? 0) + v;
    return Object.entries(total)
      .map(([k, v]) => `${k}=${Math.round(v)}`)
      .join(" ");
  };
  const long: [number, number][] = [];
  const intervals: number[] = [];
  const rounds: [number, number][] = [];
  for (const round of input.frames) {
    if (round.length > 1) rounds.push([at(round[0]!), at(round.at(-1)!)]);
    for (let index = 1; index < round.length; index++) {
      const a = at(round[index - 1]!);
      const b = at(round[index]!);
      intervals.push(b - a);
      if (b - a > 1000 / 60 + 0.5) long.push([a, b]);
    }
  }
  const longIn = long.filter(([a, b]) => inside(a, b));
  const lost = (spans: [number, number][]) => spans.reduce((s, [a, b]) => s + Math.max(0, b - a - 1000 / 60), 0);
  out(
    `FRAMES ${intervals.length} intervals (p50 ${r1(pct(intervals, 50))} p95 ${r1(pct(intervals, 95))}), ${long.length} over 16.7 ms (${Math.round(lost(long))} ms past budget), ${longIn.length} inside a page's fold-to-drawn (${Math.round(lost(longIn))} ms)`,
  );
  const longMs = long.map(([a, b]) => b - a);
  out(`FRAMES-LONG ms p50 ${r1(pct(longMs, 50))} p95 ${r1(pct(longMs, 95))} max ${r1(Math.max(0, ...longMs))}`);
  out(`FRAMES-LONG fill ${sumFill(long)}`);
  out(`FRAMES-LONG-INSIDE fill ${sumFill(longIn)}`);
  out(`FRAMES-LONG-OUTSIDE fill ${sumFill(long.filter(([a, b]) => !inside(a, b)))}`);
  const tasks = input.longSpans.map(([a, b]) => [at(a), at(b)] as [number, number]);
  const tasksIn = tasks.filter(([a, b]) => inside(a, b));
  const ms = (spans: [number, number][]) => Math.round(spans.reduce((s, [a, b]) => s + b - a, 0));
  out(`LONGTASKS ${tasks.length} (${ms(tasks)} ms), ${tasksIn.length} inside (${ms(tasksIn)} ms)`);
  out(`LONGTASKS fill ${sumFill(tasks)}`);
  // The rounds' totals (the wheel moving).
  out(`RUN ${Math.round(rounds.reduce((s, [a, b]) => s + b - a, 0))} ms: ${sumFill(rounds)}`);
}
