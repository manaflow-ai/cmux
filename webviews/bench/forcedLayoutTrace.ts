// l10n-allow-file: benchmark output, not shipped UI.
// The layouts and style recalcs an older page pays (transcript-scroll-up.bench.ts TRACE=1): a Chromium trace
// of the run, cut into one window per older page (its ask to the first frame that drew it), and in each the
// Layout and UpdateLayoutTree events on the main thread. A forced one (script read or wrote geometry before the
// frame) carries the JS stack that forced it; the frame's own carries none. Printed per page and summed by the
// stack that forced them, so what a page pays twice shows by name.

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any };
type Frame = { functionName?: string; url?: string; lineNumber?: number; columnNumber?: number };
type Work = { kind: "layout" | "style"; start: number; ms: number; forced: string | undefined; size: number };

/// The page's clock to the trace's: the bench stamps each older-page phase with its page time
/// (`console.timeStamp("cmux-older <phase> <ask> <at>")`), so the offset is read off any stamp.
export function pageToTrace(events: Ev[]): ((at: number) => number) | undefined {
  for (const e of events) {
    if (e.name !== "TimeStamp") continue;
    const match = /^cmux-older \w+ \d+ ([\d.]+)$/.exec(String(e.args?.data?.message ?? ""));
    if (match) {
      const offset = e.ts / 1000 - Number(match[1]);
      return (at) => (at + offset) * 1000;
    }
  }
  return undefined;
}

export async function reportForcedLayouts(
  events: Ev[],
  windows: { from: number; to: number }[],
  lineAt: (url: string, line: number) => Promise<string>,
) {
  const out = (line: string) => console.log(`LAYOUT-TRACE ${line}`);
  const toTrace = pageToTrace(events);
  if (!toTrace) return out("no cmux-older stamps in the trace");
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const main = events.filter((e) => mains.has(`${e.pid}:${e.tid}`)).sort((a, b) => a.ts - b.ts);
  const names = new Map<string, string>();
  const frameName = async (f: Frame) => {
    const file =
      String(f.url ?? "")
        .split("/")
        .pop()
        ?.split("?")[0] ?? "";
    const key = `${f.functionName}|${f.url}|${f.lineNumber}`;
    if (!names.has(key)) {
      let label = `${f.functionName || "(anon)"}@${file}:${f.lineNumber ?? 0}`;
      if (!f.functionName && f.url && /^https?:/.test(f.url)) {
        const text = (await lineAt(f.url, Math.max(0, (f.lineNumber ?? 1) - 1))).trim();
        label += ` "${text.slice(0, 70)}"`;
      }
      names.set(key, label);
    }
    return names.get(key)!;
  };
  const stackOf = async (st: unknown) => {
    if (!Array.isArray(st) || !st.length) return undefined;
    const own = (st as Frame[]).filter((f) => !/react-dom|scheduler|chunk-|jsx-runtime/.test(String(f.url)));
    return (await Promise.all((own.length ? own : (st as Frame[])).slice(0, 3).map(frameName))).join(" < ");
  };
  const work: Work[] = [];
  const open = new Map<string, Ev>();
  for (const e of main) {
    if (e.name !== "Layout" && e.name !== "UpdateLayoutTree") continue;
    const kind = e.name === "Layout" ? "layout" : "style";
    const begin = e.ph === "E" ? open.get(e.name) : e;
    if (e.ph === "B") {
      open.set(e.name, e);
      continue;
    }
    if (!begin) continue;
    open.delete(e.name);
    const end = e.ph === "X" ? e.ts + (e.dur ?? 0) : e.ts;
    const data = begin.args?.beginData ?? {};
    work.push({
      kind,
      start: begin.ts,
      ms: (end - begin.ts) / 1000,
      forced: await stackOf(data.stackTrace),
      size:
        kind === "layout"
          ? Number(data.dirtyObjects ?? 0)
          : Number(e.args?.elementCount ?? begin.args?.elementCount ?? 0),
    });
  }
  const round = (v: number) => Math.round(v * 10) / 10;
  const byStack = new Map<string, { n: number; ms: number; size: number }>();
  let pages = 0;
  let forcedLayouts = 0;
  let forcedLayoutMs = 0;
  let allLayoutMs = 0;
  let styleMs = 0;
  for (const [index, window] of windows.entries()) {
    const from = toTrace(window.from);
    const to = toTrace(window.to);
    const inside = work.filter((w) => w.start >= from && w.start <= to);
    if (!inside.length) continue;
    pages += 1;
    for (const w of inside) {
      const key = `${w.kind} ${w.forced ?? "(frame)"}`;
      const v = byStack.get(key) ?? { n: 0, ms: 0, size: 0 };
      v.n += 1;
      v.ms += w.ms;
      v.size += w.size;
      byStack.set(key, v);
      if (w.kind === "layout") {
        allLayoutMs += w.ms;
        if (w.forced) {
          forcedLayouts += 1;
          forcedLayoutMs += w.ms;
        }
      } else styleMs += w.ms;
    }
    // The first pages' work in order, the big ones (over 2 ms) by name.
    if (index < 4)
      for (const w of inside.filter((each) => each.ms >= 2))
        out(
          `PAGE ${index} +${round((w.start - from) / 1000)}ms ${w.kind} ${round(w.ms)}ms size ${w.size} ${w.forced ?? "(frame)"}`,
        );
  }
  const per = (v: number) => round(pages ? v / pages : 0);
  out(
    `SUMMARY ${JSON.stringify({
      pages,
      forcedLayoutsPerPage: per(forcedLayouts),
      forcedLayoutMsPerPage: per(forcedLayoutMs),
      layoutMsPerPage: per(allLayoutMs),
      styleMsPerPage: per(styleMs),
    })}`,
  );
  for (const [key, v] of [...byStack].sort((a, b) => b[1].ms - a[1].ms).slice(0, 25))
    out(`BY ${JSON.stringify({ perPage: per(v.n), msPerPage: per(v.ms), sizePerPage: per(v.size) })} ${key}`);
}
