// Scoreboard for agent evals: rows.jsonl -> RESULTS.md tables.
// A row: { agent, surface, task, pass, score, category?, wall_ms, calls }.
// Rows whose category is no_login are reported as skipped, not scored.
// Every pass rate carries its Wilson 95% interval, and two columns compare as a paired per-task difference with a
// paired bootstrap interval. The known cases in report.test.mjs (Newcombe 1998, Table I) pin the math.

const SKIP = new Set(["no_login"]);
const Z95 = 1.959963984540054;

// Wilson score interval for k passes of n (Newcombe 1998, method 3). [0, 1] when n is 0.
export function wilson(k, n, z = Z95) {
  if (n <= 0) return [0, 1];
  if (k < 0 || k > n) throw new Error(`k=${k} is not within 0..n=${n}`);
  const p = k / n;
  const z2 = z * z;
  const centre = p + z2 / (2 * n);
  const half = z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n));
  const denom = 1 + z2 / n;
  return [k === 0 ? 0 : (centre - half) / denom, k === n ? 1 : (centre + half) / denom];
}

export function intervalText(k, n) {
  const [lo, hi] = wilson(k, n);
  return `${Math.round(lo * 100)}-${Math.round(hi * 100)}%`;
}

// A seeded generator (mulberry32), so a table regenerated from the same rows prints the same interval.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function percentile(sorted, q) {
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

// Mean per-item difference b - a over paired items (each a pass fraction in [0, 1]), with a 95% percentile interval
// from resampling items with replacement. "not distinguishable" when the interval spans zero.
export function pairedBootstrap(a, b, { nBoot = 10000, seed = 20261121 } = {}) {
  if (a.length !== b.length) throw new Error(`paired lists differ in length: ${a.length} and ${b.length}`);
  if (!a.length) throw new Error("no paired items");
  const d = a.map((x, i) => b[i] - x);
  const n = d.length;
  const next = rng(seed);
  const means = [];
  for (let i = 0; i < nBoot; i++) {
    let sum = 0;
    for (let j = 0; j < n; j++) sum += d[Math.floor(next() * n)];
    means.push(sum / n);
  }
  means.sort((x, y) => x - y);
  const lo = percentile(means, 0.025);
  const hi = percentile(means, 0.975);
  return {
    n,
    diff: d.reduce((s, x) => s + x, 0) / n,
    lo,
    hi,
    aWins: d.filter((x) => x < 0).length,
    bWins: d.filter((x) => x > 0).length,
    verdict: lo <= 0 && hi >= 0 ? "not distinguishable" : lo > 0 ? "B ahead" : "A ahead",
  };
}

// Two agent/surface columns on the tasks both ran: each task's pass fraction (passes over its runs), paired by task.
export function pairedComparison(rows, colA, colB) {
  const byTask = (col) => {
    const m = new Map();
    for (const r of rows) {
      if (`${r.agent}/${r.surface}` !== col || SKIP.has(r.category)) continue;
      const t = m.get(r.task) ?? [0, 0];
      m.set(r.task, [t[0] + (r.pass ? 1 : 0), t[1] + 1]);
    }
    return m;
  };
  const a = byTask(colA);
  const b = byTask(colB);
  const tasks = [...a.keys()].filter((t) => b.has(t)).sort();
  const r = pairedBootstrap(tasks.map((t) => a.get(t)[0] / a.get(t)[1]), tasks.map((t) => b.get(t)[0] / b.get(t)[1]));
  const s = (x) => `${x >= 0 ? "+" : ""}${Math.round(x * 100)}`;
  const verdict = r.verdict === "not distinguishable" ? r.verdict : r.lo > 0 ? `${colB} ahead` : `${colA} ahead`;
  return {
    ...r,
    text: `${colB} - ${colA}: ${s(r.diff)} pts per task (95% CI ${s(r.lo)} to ${s(r.hi)}, n=${r.n}, ${r.bWins} vs ${r.aWins} discordant): ${verdict}`,
  };
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length / 2) - 1];
}

export function summarize(rows) {
  const groups = new Map();
  for (const row of rows) {
    const key = `${row.agent}\u0000${row.surface}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return [...groups.values()]
    .map((group) => {
      const scored = group.filter((r) => !SKIP.has(r.category));
      const failures = {};
      for (const r of scored) if (!r.pass) failures[r.category] = (failures[r.category] ?? 0) + 1;
      return {
        agent: group[0].agent,
        surface: group[0].surface,
        n: scored.length,
        passed: scored.filter((r) => r.pass).length,
        mean_score: scored.length ? scored.reduce((s, r) => s + r.score, 0) / scored.length : null,
        median_calls: median(scored.map((r) => r.calls ?? 0)),
        median_wall_s: scored.length ? Math.round(median(scored.map((r) => r.wall_ms)) / 1000) : null,
        top_failures: Object.entries(failures).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 3),
        ...(scored.length === 0 && group.length ? { skipped: group[0].category } : {}),
      };
    })
    .sort((a, b) => (b.mean_score ?? -1) - (a.mean_score ?? -1) || `${a.agent}/${a.surface}`.localeCompare(`${b.agent}/${b.surface}`));
}

export function renderResults({ run, date, rows, notes = [], compare = [] }) {
  const s = summarize(rows);
  const lines = [`## Run ${run} (${date})`, ""];
  lines.push("| Agent | Surface | Passed | 95% CI | Mean score | Median cmux calls | Median time (s) | Top failures |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const x of s) {
    if (x.skipped) {
      lines.push(`| ${x.agent} | ${x.surface} | skipped (${x.skipped}) | | | | | |`);
      continue;
    }
    const fails = x.top_failures.map(([c, n]) => `${c} ${n}`).join(", ");
    lines.push(
      `| ${x.agent} | ${x.surface} | ${x.passed}/${x.n} | ${intervalText(x.passed, x.n)} | ${x.mean_score.toFixed(2)} | ${x.median_calls} | ${x.median_wall_s} | ${fails} |`,
    );
  }
  const columns = s.filter((x) => !x.skipped).map((x) => `${x.agent}/${x.surface}`);
  const tasks = [...new Set(rows.map((r) => r.task))];
  lines.push("", `| Task | ${columns.join(" | ")} |`, `| --- |${columns.map(() => " --- |").join("")}`);
  for (const task of tasks) {
    const cells = columns.map((col) => {
      const r = rows.find((row) => `${row.agent}/${row.surface}` === col && row.task === task);
      if (!r) return "";
      return r.pass ? "pass" : `${r.category} (${r.score.toFixed(2)})`;
    });
    lines.push(`| ${task} | ${cells.join(" | ")} |`);
  }
  // Paired comparisons: [colA, colB] pairs, e.g. ["claude/cli", "claude/mcp"].
  if (compare.length) lines.push("", ...compare.map(([a, b]) => `- ${pairedComparison(rows, a, b).text}`));
  if (notes.length) lines.push("", ...notes.map((n) => `- ${n}`));
  return `${lines.join("\n")}\n`;
}
