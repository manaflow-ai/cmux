/// <reference types="bun" />
// Scratch probe (not committed): fling a paged flat chat, count renders.
import { chromium } from "./browsers";
import { papercutPane } from "../test/support/papercutChat";
const ROWS = Number(process.env.ROWS ?? 20000);
const turns = ROWS / 2;
const browser = await chromium.launch({ headless: true });
const pane = await papercutPane(() => browser, {
  turns, running: false, lead: [], ready: ".acpmux-row", attachPage: 160,
  session: { turnCount: turns }, daemonIndexes: true, askedPageSize: true, production: { minify: false },
});
const page = await pane.open({ width: 1100, height: 800 });
await page.waitForTimeout(1500);
const cdp = await page.context().newCDPSession(page);
await cdp.send("Profiler.enable");
await cdp.send("Profiler.setSamplingInterval", { interval: 500 });
await cdp.send("Profiler.start");
const out = await page.evaluate(async () => {
  const d = (window as any).cmuxAcpmuxDebug;
  d.renders(); d.perfStats({ raw: true });
  const results: any[] = [];
  for (let i = 0; i < 2; i++) {
    d.renders();
    d.perfStats({ raw: true });
    const f = await d.startFling(3, { wait: true });
    const r = d.renders();
    const s = d.perfStats({ raw: true });
    const sum = (p: string) => Object.entries(r).filter(([k]) => k.startsWith(p)).reduce((a, [, v]) => a + (v as number), 0);
    results.push({ fling: f, row: sum("row:"), content: sum("content:"), mount: sum("mount:"), remount: sum("remount:"),
      other: Object.fromEntries(Object.entries(r).filter(([k]) => !/^(row|content|mount|remount):/.test(k))),
      samples: s.samples });
  }
  return results;
});
const { profile } = (await cdp.send("Profiler.stop")) as any;
(await import("node:fs")).writeFileSync("/tmp/flingprobe/prof.cpuprofile", JSON.stringify(profile));
{
  const self = new Map<string, number>();
  const byId = new Map<number, any>(profile.nodes.map((n: any) => [n.id, n]));
  const dt = profile.timeDeltas as number[];
  profile.samples.forEach((id: number, i: number) => {
    const n = byId.get(id)!; const f = n.callFrame;
    const k = `${f.functionName || "(anon)"} ${String(f.url).split("/").pop()}:${f.lineNumber}`;
    self.set(k, (self.get(k) ?? 0) + (dt[i] ?? 0) / 1000);
  });
  // inclusive by function name (stack walk)
  const parent = new Map<number, number>();
  for (const n of profile.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
  const incl = new Map<string, number>();
  profile.samples.forEach((id: number, i: number) => {
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const f = byId.get(at)!.callFrame; const k = f.functionName || "(anon)";
      if (seen.has(k)) continue; seen.add(k); incl.set(k, (incl.get(k) ?? 0) + (dt[i] ?? 0) / 1000);
    }
  });
  console.log("SELF", JSON.stringify([...self].sort((a, b) => b[1] - a[1]).slice(0, 40).map(([k, v]) => `${Math.round(v)} ${k}`)));
  console.log("INCL", JSON.stringify([...incl].sort((a, b) => b[1] - a[1]).slice(0, 80).map(([k, v]) => `${Math.round(v)} ${k}`)));
}
for (const r of out) {
  const s = r.samples as any[];
  const iv = s.map((x) => x.interval_ms).sort((a, b) => a - b);
  const pages = s.filter((x) => x.spans["app.rows"] !== undefined);
  console.log(JSON.stringify({ frames: s.length, p50: iv[Math.floor(iv.length / 2)], p95: iv[Math.floor(iv.length * 0.95)],
    rows_end: r.fling.rows, row: r.row, content: r.content, mount: r.mount, remount: r.remount, other: r.other, page_frames: pages.length,
    page_row_renders: pages.map((x) => x.spans["row.renders"]).slice(0, 12), plain_row_renders_p50: s.filter((x) => !x.spans["app.rows"]).map((x) => x.spans["row.renders"] ?? 0).sort((a, b) => a - b)[Math.floor(s.length / 4)] }));
}
await browser.close();
process.exit(0);
