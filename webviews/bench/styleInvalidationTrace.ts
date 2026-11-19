// l10n-allow-file: benchmark output, not shipped UI.
// A Chromium trace with style invalidation tracking over a window, and what restyled (composer-typing.bench.ts
// --trace): UpdateLayoutTree count / elements / ms per key or per streamed token, then the invalidation sources (the
// element whose change scheduled the invalidation, what changed, the invalidation set, the JS stack that wrote it)
// and how many elements each marked. It found the scroll origin that restyled every mounted row per token
// (conversation/scrollCoordinates.ts). Traced times run high (the tracking slows the page); element counts hold.
import type { Browser, CDPSession, Page } from "playwright";

export const TRACE_CATEGORIES = [
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.invalidationTracking",
  "disabled-by-default-devtools.timeline.stack",
  "blink.debug",
];

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any; cat?: string };

export async function traceWindow(browser: Browser, page: Page, run: () => Promise<unknown>): Promise<Ev[]> {
  await browser.startTracing(page, { categories: TRACE_CATEGORIES });
  await run();
  const raw = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: Ev[] };
  return raw.traceEvents;
}

const round = (v: number) => Math.round(v * 100) / 100;
const pct = (values: number[], q: number) => {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))]!;
};

export async function reportTrace(
  label: string,
  events: Ev[],
  units: { keys?: number; tokens?: number },
  map: (url: string, line: number, column: number) => string,
  cdp: CDPSession,
) {
  const out = (line: string) => console.log(`STYLE-TRACE ${label} ${line}`);
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const main = events.filter((e) => mains.has(`${e.pid}:${e.tid}`)).sort((a, b) => a.ts - b.ts);
  const frameOf = (f: any) => {
    const file =
      String(f.url ?? "")
        .split("/")
        .pop()
        ?.split("?")[0] ?? "";
    const where = file ? map(file, Math.max(0, (f.lineNumber ?? 1) - 1), Math.max(0, (f.columnNumber ?? 1) - 1)) : "?";
    return `${f.functionName || "(anon)"}@${where}`;
  };
  const stackOf = (st: any, depth = 4) =>
    Array.isArray(st) && st.length
      ? st
          .filter((f: any) => !/react-dom|scheduler|chunk-|jsx-runtime/.test(String(f.url)))
          .slice(0, depth)
          .map(frameOf)
          .join(" < ") || st.slice(0, depth).map(frameOf).join(" < ")
      : "(no stack)";

  // UpdateLayoutTree: B/E pairs or X.
  type Ult = { start: number; end: number; elements: number; forced: string | undefined };
  const ults: Ult[] = [];
  const open = new Map<number, Ev>();
  for (const e of main) {
    if (e.name !== "UpdateLayoutTree") continue;
    if (e.ph === "X")
      ults.push({
        start: e.ts,
        end: e.ts + (e.dur ?? 0),
        elements: Number(e.args?.elementCount ?? e.args?.data?.elementCount ?? 0),
        forced: e.args?.beginData?.stackTrace ? stackOf(e.args.beginData.stackTrace, 3) : undefined,
      });
    else if (e.ph === "B") open.set(e.tid, e);
    else if (e.ph === "E") {
      const b = open.get(e.tid);
      open.delete(e.tid);
      if (!b) continue;
      ults.push({
        start: b.ts,
        end: e.ts,
        elements: Number(e.args?.elementCount ?? b.args?.elementCount ?? 0),
        forced: b.args?.beginData?.stackTrace ? stackOf(b.args.beginData.stackTrace, 3) : undefined,
      });
    }
  }
  const totalEl = ults.reduce((s, u) => s + u.elements, 0);
  const totalMs = ults.reduce((s, u) => s + (u.end - u.start) / 1000, 0);
  const per = (v: number, n?: number) => (n ? round(v / n) : null);
  out(
    `SUMMARY ${JSON.stringify({
      updateLayoutTree: ults.length,
      elements: totalEl,
      style_ms: round(totalMs),
      perKey: units.keys
        ? { ult: per(ults.length, units.keys), elements: per(totalEl, units.keys), ms: per(totalMs, units.keys) }
        : null,
      perToken: units.tokens
        ? { ult: per(ults.length, units.tokens), elements: per(totalEl, units.tokens), ms: per(totalMs, units.tokens) }
        : null,
      elementsPerUlt: {
        p50: pct(
          ults.map((u) => u.elements),
          0.5,
        ),
        p95: pct(
          ults.map((u) => u.elements),
          0.95,
        ),
        max: Math.max(0, ...ults.map((u) => u.elements)),
      },
      msPerUlt: {
        p50: round(
          pct(
            ults.map((u) => (u.end - u.start) / 1000),
            0.5,
          ),
        ),
        p95: round(
          pct(
            ults.map((u) => (u.end - u.start) / 1000),
            0.95,
          ),
        ),
      },
      forced: ults.filter((u) => u.forced).length,
      forcedElements: ults.filter((u) => u.forced).reduce((s, u) => s + u.elements, 0),
      keydowns: main.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown").length,
    })}`,
  );
  const forcedBy = new Map<string, { n: number; el: number; ms: number }>();
  for (const u of ults) {
    const k = u.forced ?? "(frame)";
    const v = forcedBy.get(k) ?? { n: 0, el: 0, ms: 0 };
    v.n += 1;
    v.el += u.elements;
    v.ms += (u.end - u.start) / 1000;
    forcedBy.set(k, v);
  }
  for (const [k, v] of [...forcedBy].sort((a, b) => b[1].el - a[1].el).slice(0, 10))
    out(`ULT-BY ${JSON.stringify({ n: v.n, elements: v.el, ms: round(v.ms), by: k })}`);

  function changeOf(d: any): string {
    if (d.changedClass !== undefined) return `class .${d.changedClass}`;
    if (d.changedAttribute !== undefined) return `attr [${d.changedAttribute}]`;
    if (d.changedId !== undefined) return `id #${d.changedId}`;
    if (d.changedPseudo !== undefined) return `pseudo :${d.changedPseudo}`;
    return `other ${JSON.stringify(Object.keys(d))}`;
  }
  // Large recalcs (> 500 elements): the marks and schedules between the previous recalc's end and this one's start.
  const large = ults.filter((u) => u.elements > 500).sort((a, b) => a.start - b.start);
  const byStart = [...ults].sort((a, b) => a.start - b.start);
  const before = new Map<string, { ults: number; elements: number }>();
  for (const u of large) {
    const prev = byStart.filter((x) => x.end <= u.start).at(-1);
    const from = prev ? prev.end : u.start - 50_000;
    const keys = new Set<string>();
    for (const e of main) {
      if (e.ts < from || e.ts > u.start) continue;
      const d = e.args?.data ?? {};
      if (e.name === "StyleRecalcInvalidationTracking")
        keys.add(`recalc ${d.reason} | ${String(d.nodeName ?? "").slice(0, 90)} | ${stackOf(d.stackTrace, 2)}`);
      else if (e.name === "ScheduleStyleInvalidationTracking")
        keys.add(`schedule ${String(d.nodeName ?? "").slice(0, 90)} | ${changeOf(d)}`);
    }
    if (!keys.size) keys.add("(no marks in the gap)");
    for (const k of keys) {
      const v = before.get(k) ?? { ults: 0, elements: 0 };
      v.ults += 1;
      v.elements += u.elements;
      before.set(k, v);
    }
  }
  out(`LARGE ${JSON.stringify({ ults: large.length, elements: large.reduce((s, u) => s + u.elements, 0) })}`);
  for (const [k, v] of [...before].sort((a, b) => b[1].ults - a[1].ults).slice(0, 15))
    out(`LARGE-PRECEDED-BY ${JSON.stringify(v)} ${k}`);

  // Raw shapes, a few of each, so unknown field names still show.
  const names = new Map<string, number>();
  for (const e of main)
    if (/Invalidation|ScheduleStyle|StyleRecalc/.test(e.name)) names.set(e.name, (names.get(e.name) ?? 0) + 1);
  out(`EVENT-NAMES ${JSON.stringify(Object.fromEntries(names))}`);
  for (const name of names.keys())
    for (const e of main.filter((x) => x.name === name).slice(0, 3))
      out(`SAMPLE ${name} ${JSON.stringify({ ...e.args?.data, stackTrace: undefined }).slice(0, 700)}`);

  // Schedules: which element changed what, which invalidation set it scheduled, and who wrote it.
  const scheduleBySet = new Map<string, string>();
  const scheduleCount = new Map<string, { n: number; node: number }>();
  for (const e of main) {
    if (e.name !== "ScheduleStyleInvalidationTracking") continue;
    const d = e.args?.data ?? {};
    const key = `${d.nodeName} | ${changeOf(d)} | set ${d.invalidationSet ? "" : "none"} | ${stackOf(d.stackTrace)}`;
    if (d.invalidationSet) scheduleBySet.set(String(d.invalidationSet), key);
    const v = scheduleCount.get(key) ?? { n: 0, node: d.nodeId };
    v.n += 1;
    scheduleCount.set(key, v);
  }
  // Invalidator: one event per element an invalidation set marked.
  const marked = new Map<string, number>();
  const markedWhat = new Map<string, number>();
  const setDesc = (item: any) =>
    JSON.stringify({
      classes: item.classes,
      attributes: item.attributes,
      tagNames: item.tagNames,
      ids: item.ids ?? item.id,
      all: item.allDescendantsMightBeInvalid || undefined,
      self: item.invalidatesSelf || undefined,
      sib: item.invalidationSetType ?? undefined,
    });
  for (const e of main) {
    if (e.name !== "StyleInvalidatorInvalidationTracking") continue;
    const d = e.args?.data ?? {};
    const list: any[] = d.invalidationList ?? [];
    const sources = list.map((item) => scheduleBySet.get(String(item.id)) ?? `(unscheduled set ${item.id})`);
    const key = `${d.reason} | via ${[...new Set(sources)].join(" + ").slice(0, 400)} | sets ${list.map(setDesc).join(" ").slice(0, 400)} | matched ${d.selectorPart ?? d.changedClass ?? d.changedAttribute ?? d.changedId ?? ""}`;
    marked.set(key, (marked.get(key) ?? 0) + 1);
    const what = String(d.nodeName ?? "")
      .replace(/ id='[^']*'/, "")
      .slice(0, 120);
    markedWhat.set(what, (markedWhat.get(what) ?? 0) + 1);
  }
  const n = (v: number) => ({ total: v, perKey: per(v, units.keys), perToken: per(v, units.tokens) });
  for (const [k, v] of [...marked].sort((a, b) => b[1] - a[1]).slice(0, 25)) out(`MARKED ${JSON.stringify(n(v))} ${k}`);
  for (const [k, v] of [...markedWhat].sort((a, b) => b[1] - a[1]).slice(0, 25))
    out(`MARKED-ELEMENT ${JSON.stringify(n(v))} ${k}`);
  // Direct recalc marks: inline style, animations, :has, sheet changes, subtree flags.
  const recalc = new Map<string, number>();
  for (const e of main) {
    if (e.name !== "StyleRecalcInvalidationTracking") continue;
    const d = e.args?.data ?? {};
    const key = `${d.reason} | ${String(d.nodeName ?? "").slice(0, 140)} | subtree=${d.subtree ?? ""} | ${d.extraData ?? ""} | ${stackOf(d.stackTrace)}`;
    recalc.set(key, (recalc.get(key) ?? 0) + 1);
  }
  for (const [k, v] of [...recalc].sort((a, b) => b[1] - a[1]).slice(0, 30))
    out(`RECALC-MARK ${JSON.stringify(n(v))} ${k}`);
  const describe = async (nodeId: number) => {
    try {
      const { node } = (await cdp.send("DOM.describeNode", { backendNodeId: nodeId })) as any;
      const attrs: string[] = node.attributes ?? [];
      const pairs: string[] = [];
      for (let i = 0; i < attrs.length; i += 2) pairs.push(`${attrs[i]}="${String(attrs[i + 1]).slice(0, 60)}"`);
      return `<${String(node.localName)} ${pairs.join(" ")}>`;
    } catch {
      return "(gone)";
    }
  };
  for (const [k, v] of [...scheduleCount].sort((a, b) => b[1].n - a[1].n).slice(0, 25))
    out(`SCHEDULE ${JSON.stringify(n(v.n))} ${k} | node ${await describe(v.node)}`);
}
