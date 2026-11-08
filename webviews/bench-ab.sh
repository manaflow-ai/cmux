#!/bin/bash
# Scratch (not committed): base and fixed source, same machine, same harness.
cd "$(dirname "$0")"
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/manaflow-ai/cmux.git
summary() { bun -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
for (const x of r.results) console.log(process.argv[2], x.id, "p50", x.latencyMs?.p50?.toFixed(1), "p95", x.latencyMs?.p95?.toFixed(1), "max", x.latencyMs?.max?.toFixed(1), "work", x.workMs ?? x.work ?? "", "commits", JSON.stringify(x.reactCommits ?? null), "trace/run", x.trace ? ["script","style","layout"].map((k) => k + "=" + (x.trace[k + "Ms"] / x.samples.length).toFixed(1)).join(" ") : "", "longTasks", JSON.stringify(x.longTasks), "event", JSON.stringify(x.samples[0]?.eventTiming?.slice(0, 4)));
for (const e of r.errors ?? []) console.log(process.argv[2], "ERROR", e);
' "$1" "$2"; }
run() {
  CMUX_LATENCY_DRAFTS=1 bun scripts/latency/run.ts --no-fail --engine chromium --runs "${RUNS:-15}" --base HEAD --page "chat draft typing" --json "/tmp/$1-drafts.json" > "/tmp/$1-drafts.log" 2>&1 || tail -20 "/tmp/$1-drafts.log"
  bun scripts/latency/run.ts --no-fail --engine chromium --runs "${RUNS:-15}" --base HEAD --page "chat flows" --action "type a character" --json "/tmp/$1-empty.json" > "/tmp/$1-empty.log" 2>&1 || tail -20 "/tmp/$1-empty.log"
  summary "/tmp/$1-empty.json" "$1"; summary "/tmp/$1-drafts.json" "$1"
}
git apply -R fix.patch && run before
git apply fix.patch && run after
