import { test } from "bun:test";
import { retryTargetIn } from "../src/agent-session/acpmux/conversation/turns";
import { findMatchesIncremental } from "../src/agent-session/acpmux/conversation/chatFind";
import { measure } from "./support/dsaBench";
const row = (i: number, kind: string, extra: any = {}) => ({ id: `r${i}`, kind, text: `lorem ipsum ${i}`, version: 1, ...extra }) as any;
function chat(n: number, mode: "peer" | "longturn" | "normal") {
  const rows: any[] = [];
  for (let i = 0; i < n; i++) {
    if (mode === "longturn") rows.push(i === 0 ? row(i, "user") : row(i, "assistant"));
    else if (i % 10 === 0) rows.push(row(i, "user", mode === "peer" ? { incoming: true } : {}));
    else if (i % 10 === 9) rows.push(row(i, "turnSummary"));
    else rows.push(row(i, "assistant"));
  }
  return rows;
}
test("probe", () => {
  for (const n of [1000, 10_000, 100_000, 1_000_000]) {
    for (const mode of ["peer", "longturn", "normal"] as const) {
      const rows = chat(n, mode);
      const t = measure(() => retryTargetIn(rows), 15);
      console.log(`retry ${mode} n=${n} p50=${t.p50.toFixed(4)} p95=${t.p95.toFixed(4)}`);
    }
    const rows = chat(n, "normal");
    let cache = findMatchesIncremental(rows, "ipsum 1").cache;
    let cur = rows;
    const t = measure(() => {
      const next = cur.slice(); next[next.length - 1] = { ...next[next.length - 1], text: next[next.length - 1].text + " x" };
      const r = findMatchesIncremental(next, "ipsum 1", cache); cache = r.cache; cur = next; return r;
    }, 15);
    const copy = measure(() => { const next = cur.slice(); return next; }, 15);
    console.log(`find tail-edit n=${n} p50=${t.p50.toFixed(4)} p95=${t.p95.toFixed(4)} (slice alone ${copy.p50.toFixed(4)}) matches=${cache.matches.length}`);
  }
});
