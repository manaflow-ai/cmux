// Scoreboard for agent evals: rows.jsonl -> RESULTS.md tables.
// A row: { agent, surface, task, pass, score, category?, wall_ms, calls }.
// Rows whose category is no_login are reported as skipped, not scored.

const SKIP = new Set(["no_login"]);

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

export function renderResults({ run, date, rows, notes = [] }) {
  const s = summarize(rows);
  const lines = [`## Run ${run} (${date})`, ""];
  lines.push("| Agent | Surface | Passed | Mean score | Median cmux calls | Median time (s) | Top failures |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- |");
  for (const x of s) {
    if (x.skipped) {
      lines.push(`| ${x.agent} | ${x.surface} | skipped (${x.skipped}) | | | | |`);
      continue;
    }
    const fails = x.top_failures.map(([c, n]) => `${c} ${n}`).join(", ");
    lines.push(
      `| ${x.agent} | ${x.surface} | ${x.passed}/${x.n} | ${x.mean_score.toFixed(2)} | ${x.median_calls} | ${x.median_wall_s} | ${fails} |`,
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
  if (notes.length) lines.push("", ...notes.map((n) => `- ${n}`));
  return `${lines.join("\n")}\n`;
}
