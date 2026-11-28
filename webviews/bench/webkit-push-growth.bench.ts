// Run from webviews/: [ENGINE=webkit|chromium] MODE=A|B|C|D MINUTES=12 bun bench/webkit-push-growth.bench.ts
// (PLAYWRIGHT_BROWSERS_PATH with the engine).
// RFD 0062 renderer idle growth: does the web process grow when every push is a new script text?
// ENGINE=chromium measures the renderer processes instead: the Chromium page host pushes with
// DevTools `Runtime.evaluate` (ChromiumPageHostBridge), which is what MODE=A does there.
// The Mac agent pane's default host pushes each frame batch as
// evaluateJavaScript("window.cmuxAcpmuxTransport?.receive({...json...});") (AgentPaneTransportTypes.swift `script`).
// MODE=A  page.evaluate(<unique script string>)          (what the host does)
// MODE=B  page.evaluate(fn, data)                          (same data, one fixed function)
// MODE=C  in-page (0, eval)(<unique script string>)        (JSC only, no inspector in the loop)
// MODE=D  in-page JSON.parse(<same string>)                (control for C)
import { chromium, webkit } from "playwright";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";

const MODE = process.env.MODE ?? "A";
const ENGINE = process.env.ENGINE === "chromium" ? "chromium" : "webkit";
const RATE = Number(process.env.RATE ?? 20);
const BYTES = Number(process.env.BYTES ?? 2048);
const MINUTES = Number(process.env.MINUTES ?? 10);
const OUT = process.env.OUT_JSON;

function pssMb(pid: number): number {
  try {
    const m = /^Pss:\s+(\d+)/m.exec(readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"));
    return m ? Number(m[1]) / 1024 : 0;
  } catch {
    return 0;
  }
}
function isWebProcess(pid: number, name: string): boolean {
  if (ENGINE === "webkit") return /(WebKit|WPE)WebProces/.test(name);
  try {
    return readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("--type=renderer");
  } catch {
    return false;
  }
}
function webProcessPssMb(): number {
  const parent = new Map<number, number>(),
    comm = new Map<number, string>();
  for (const d of readdirSync("/proc")) {
    if (!/^\d+$/.test(d)) continue;
    try {
      const stat = readFileSync(`/proc/${d}/stat`, "utf8");
      const r = stat.lastIndexOf(")");
      comm.set(Number(d), stat.slice(stat.indexOf("(") + 1, r));
      parent.set(Number(d), Number(stat.slice(r + 2).split(" ")[1]));
    } catch {}
  }
  let total = 0;
  for (const [pid] of parent) {
    if (!isWebProcess(pid, comm.get(pid) ?? "")) continue;
    let p = pid;
    while (p > 1 && p !== process.pid) p = parent.get(p) ?? 1;
    if (p === process.pid) total += pssMb(pid);
  }
  return total;
}
function slope(pts: { t: number; y: number }[]): number {
  const n = pts.length,
    mt = pts.reduce((a, p) => a + p.t, 0) / n,
    my = pts.reduce((a, p) => a + p.y, 0) / n;
  const num = pts.reduce((a, p) => a + (p.t - mt) * (p.y - my), 0),
    den = pts.reduce((a, p) => a + (p.t - mt) ** 2, 0);
  return den ? (num / den) * 60_000 : 0;
}

let seq = 0;
function batch(): string {
  seq++;
  const frame = JSON.stringify({
    jsonrpc: "2.0",
    method: "session/update",
    params: { sessionId: `s${seq % 7}`, seq, update: { text: `chunk ${seq} `.padEnd(BYTES - 120, "x") } },
  });
  return JSON.stringify({ connection: 1, seq, frames: [frame] });
}

const browser = await (ENGINE === "chromium" ? chromium : webkit).launch({ headless: true });
const page = await browser.newPage();
await page.setContent(`<html><body><div id=n>0</div><script>
  let got = 0; window.cmuxAcpmuxTransport = { receive(e) { got++; if (got % 100 === 0) document.getElementById('n').textContent = got + ' ' + e.seq; } };
</script></body></html>`);

if (MODE === "C" || MODE === "D") {
  await page.evaluate(
    ({ MODE, RATE, BYTES }) => {
      let s = 0;
      setInterval(() => {
        s++;
        const frame = JSON.stringify({
          jsonrpc: "2.0",
          method: "session/update",
          params: { sessionId: `s${s % 7}`, seq: s, update: { text: `chunk ${s} `.padEnd(BYTES - 120, "x") } },
        });
        const json = JSON.stringify({ connection: 1, seq: s, frames: [frame] });
        if (MODE === "C") (0, eval)(`window.cmuxAcpmuxTransport?.receive(${json});`);
        else (window as any).cmuxAcpmuxTransport.receive(JSON.parse(json));
      }, 1000 / RATE);
    },
    { MODE, RATE, BYTES },
  );
} else {
  const timer = setInterval(() => {
    const json = batch();
    if (MODE === "A") void page.evaluate(`window.cmuxAcpmuxTransport?.receive(${json});`).catch(() => {});
    else void page.evaluate((j) => (window as any).cmuxAcpmuxTransport?.receive(JSON.parse(j)), json).catch(() => {});
  }, 1000 / RATE);
  process.on("exit", () => clearInterval(timer));
}

const start = Date.now(),
  samples: { t: number; pssMb: number }[] = [];
while (Date.now() - start < MINUTES * 60_000) {
  await new Promise((r) => setTimeout(r, 15_000));
  samples.push({ t: Date.now() - start, pssMb: webProcessPssMb() });
  console.log(
    `${ENGINE} ${MODE} t=${Math.round((Date.now() - start) / 1000)}s pss=${samples.at(-1)!.pssMb.toFixed(1)}MB`,
  );
}
const after90 = samples.filter((s) => s.t >= 90_000).map((s) => ({ t: s.t, y: s.pssMb }));
const result = {
  engine: ENGINE,
  mode: MODE,
  rate: RATE,
  bytes: BYTES,
  pssPerMin: slope(after90),
  first: samples[0],
  last: samples.at(-1),
  samples,
};
console.log(
  `RESULT ${ENGINE} ${MODE}: ${result.pssPerMin.toFixed(2)} MB/min (${samples[0]!.pssMb.toFixed(1)} -> ${samples.at(-1)!.pssMb.toFixed(1)})`,
);
if (OUT) writeFileSync(OUT, JSON.stringify(result));
await browser.close();
process.exit(0);
