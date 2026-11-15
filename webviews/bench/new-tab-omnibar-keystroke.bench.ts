// l10n-allow-file: benchmark output, not shipped UI.
// What one keystroke costs the New Tab omnibar's rows (screenModel `screenRows`, the pure pass the field runs on
// every key; launchRows.ts adds the chats, folders and agents). Lawrence 2026-11-13: the omnibar searches
// workspaces, tabs, history, chats and starts agents in folders, and keystroke latency must stay flat.
//
// A stress fixture at the hosts' caps: 40 tabs, 40 workspaces, 40 visited pages, 2,000 palette actions, 500 chats,
// 200 folders, 3 agents. Each query is typed a letter at a time (each prefix is one key), many times over; per key
// the time of `screenRows` is recorded. Prints p50 / p95 / p99 / max in µs, with and without the agent sources
// (`--no-agents` measures the rows as they were before them, on the same code).
//   bun bench/new-tab-omnibar-keystroke.bench.ts [--rounds 200] [--no-agents] [--json FILE]
/// <reference types="bun" />
import fs from "node:fs";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import { screenRows } from "../src/agent-session/acpmux/newtab/screenModel";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const ROUNDS = Number(flag("--rounds") ?? 200);
const AGENTS_ON = !argv.includes("--no-agents");
const JSON_OUT = flag("--json");

const words = ["cmux", "omnibar", "sidebar", "release", "fix", "perf", "terminal", "browser", "notes", "site"];
const pick = (index: number) => words[index % words.length]!;
const omnibar: OmnibarContext = {
  ...EMPTY_OMNIBAR,
  tabs: Array.from({ length: 40 }, (_, i) => ({
    id: `t${i}`,
    kind: i % 3 === 0 ? ("browser" as const) : ("terminal" as const),
    title: i % 3 === 0 ? `${pick(i)} docs - Site` : `${pick(i)} ${i}`,
    detail: i % 3 === 0 ? `https://${pick(i)}.example.com/page/${i}` : `~/fun/${pick(i)}`,
    workspace: `ws-${pick(i + 1)}`,
  })),
  workspaces: Array.from({ length: 40 }, (_, i) => ({
    id: `w${i}`,
    name: `${pick(i)}-${i}`,
    detail: `~/fun/${pick(i)}`,
  })),
  history: Array.from({ length: 40 }, (_, i) => ({
    url: `https://www.${pick(i)}${i}.com/a/b?utm_source=x`,
    title: `${pick(i)} page ${i}`,
  })),
  actions: Array.from({ length: 2000 }, (_, i) => ({
    id: `a${i}`,
    title: `${pick(i)} action ${i}`,
    detail: "Section",
    keywords: [pick(i + 3), `kw${i}`],
  })),
  uses: Object.fromEntries(Array.from({ length: 200 }, (_, i) => [`action:a${i}`, i])),
};
const agentSources = AGENTS_ON
  ? {
      chats: Array.from({ length: 500 }, (_, i) => ({
        id: `s${i}`,
        title: `${pick(i)} chat about ${pick(i + 2)} ${i}`,
        harness: i % 2 ? "codex" : "claude",
        cwd: `/Users/me/fun/${pick(i)}`,
        at: i,
      })),
      folders: Array.from({ length: 200 }, (_, i) => `/Users/me/${i % 2 ? "fun" : "code"}/${pick(i)}-${i}`),
      agents: [
        { id: "claude", name: "Claude Code" },
        { id: "codex", name: "Codex" },
        { id: "opencode", name: "OpenCode" },
      ],
      defaultAgent: "claude",
      listing: { parent: "/Users/me/fun", folders: Array.from({ length: 200 }, (_, i) => `${pick(i)}-${i}`) },
    }
  : {};
const context = {
  omnibar,
  home: "/Users/me",
  ask: { harness: "claude", agent: "Claude Code" },
  create: ["terminal", "browser", "chat"] as const,
  ...agentSources,
};
const queries = [
  "codex ~/fun/cmux",
  "omnibar ranking",
  "release notes",
  "~/fun/si",
  "cmux.com",
  "claude why is it slow",
];

// Warm the JIT as typing does before the measured keys.
for (let round = 0; round < 20; round += 1)
  for (const query of queries)
    for (let end = 1; end <= query.length; end += 1) screenRows(query.slice(0, end), context);

const samples: number[] = [];
let rows = 0;
for (let round = 0; round < ROUNDS; round += 1) {
  for (const query of queries) {
    for (let end = 1; end <= query.length; end += 1) {
      const start = Bun.nanoseconds();
      rows += screenRows(query.slice(0, end), context).length;
      samples.push((Bun.nanoseconds() - start) / 1000);
    }
  }
}
samples.sort((a, b) => a - b);
const at = (q: number) => samples[Math.min(samples.length - 1, Math.floor(q * samples.length))]!;
const report = {
  bench: "new-tab-omnibar-keystroke",
  agents: AGENTS_ON,
  keys: samples.length,
  rows_per_key: +(rows / samples.length).toFixed(2),
  us: {
    p50: +at(0.5).toFixed(1),
    p95: +at(0.95).toFixed(1),
    p99: +at(0.99).toFixed(1),
    max: +samples.at(-1)!.toFixed(1),
  },
};
console.log(JSON.stringify(report));
if (JSON_OUT) fs.writeFileSync(JSON_OUT, `${JSON.stringify(report, null, 2)}\n`);
