// l10n-allow-file: gallery fixtures, public-safe sample sessions, repos and models.
// Costs (History > Costs, LedgerScreen.tsx): three looks of the same week of agent spend, and its
// states. `bars` ships: each row's share is a tonal fill behind it, the cost at the end. Every look
// shows cache reads, cache writes and the cache hit rate; Export saves the range as CSV or JSON.
import type { ComponentProps } from "react";
import { minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import type { LedgerScreen } from "./LedgerScreen";

type Props = ComponentProps<typeof LedgerScreen>;

const zero = {
  costUsd: 0,
  harnessCostUsd: 0,
  tableCostUsd: 0,
  unpricedTurns: 0,
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  turns: 0,
  toolCalls: 0,
  wallMs: 0,
  sessions: 1,
};

const HOUR = 3_600_000;
const session = (
  sessionId: string,
  title: string,
  cost: number,
  extra: Partial<typeof zero> & { repo?: string; branch?: string; models?: string[]; harness?: string } = {},
) => ({
  ...zero,
  costUsd: cost,
  harnessCostUsd: cost,
  inputTokens: Math.round(cost * 180_000),
  outputTokens: Math.round(cost * 21_000),
  cacheReadTokens: Math.round(cost * 900_000),
  cacheWriteTokens: Math.round(cost * 30_000),
  turns: Math.max(1, Math.round(cost * 6)),
  toolCalls: Math.round(cost * 40),
  wallMs: Math.round(cost * 0.4 * HOUR),
  models: ["model-large"],
  pullRequests: [],
  harness: "claude",
  lastAt: minutesAgo(Math.round(100 / (cost + 1))),
  sessionId,
  title,
  ...extra,
});

const rows = [
  session("s1", "Port the sidebar to the new layout", 14.82, { repo: "acme/app", branch: "lane/sidebar" }),
  session("s2", "Fix the flaky upload test", 6.4, {
    repo: "acme/app",
    branch: "lane/upload-retry",
    harness: "codex",
    harnessCostUsd: 0,
    tableCostUsd: 6.4,
    models: ["model-code"],
  }),
  session("s3", "Profile cold startup", 3.15, {
    repo: "acme/app",
    branch: "lane/startup",
    models: ["model-large", "model-small"],
  }),
  session("s4", "Review the docs for the 1.0 launch", 1.02, {
    repo: "acme/docs",
    // A cold cache: the prompt written again more often than read.
    cacheReadTokens: 40_000,
    cacheWriteTokens: 160_000,
    harnessCostUsd: 0.6,
    tableCostUsd: 0.2,
    unpricedTurns: 3,
  }),
  session("s5", "Try the local model on the parser", 0, {
    repo: "acme/parser",
    harnessCostUsd: 0,
    unpricedTurns: 12,
    turns: 12,
    models: ["local-model"],
    harness: "opencode",
  }),
];

const sum = (key: keyof typeof zero) => rows.reduce((total, row) => total + (row[key] as number), 0);
const totals = Object.fromEntries(Object.keys(zero).map((key) => [key, sum(key as keyof typeof zero)])) as typeof zero;

const rollup = (key: string, members: typeof rows, label?: string) => ({
  ...Object.fromEntries(
    Object.keys(zero).map((field) => [
      field,
      members.reduce((total, row) => total + (row[field as keyof typeof zero] as number), 0),
    ]),
  ),
  key,
  ...(label ? { label } : {}),
});

const reply = {
  priceTable: { version: "2026-11-08", currency: "USD" },
  range: { since: minutesAgo(7 * 24 * 60), until: minutesAgo(0) },
  totals,
  rows,
  rollups: {
    repo: [rollup("acme/app", rows.slice(0, 3)), rollup("acme/docs", [rows[3]!]), rollup("acme/parser", [rows[4]!])],
    model: [
      rollup("model-large", [rows[0]!, rows[2]!, rows[3]!]),
      rollup("model-code", [rows[1]!]),
      rollup("local-model", [rows[4]!]),
    ],
    day: [
      rollup("2026-11-06", [rows[2]!, rows[3]!]),
      rollup("2026-11-07", [rows[0]!]),
      rollup("2026-11-08", [rows[1]!, rows[4]!]),
    ],
    person: [rollup("you@studio", rows)],
    account: [rollup("work", rows.slice(0, 3)), rollup("personal", rows.slice(3))],
    workspace: [rollup("w1", rows.slice(0, 2), "App"), rollup("w2", rows.slice(2), "Research")],
    pr: [rollup("https://example.com/acme/app/pull/412", [rows[1]!], "acme/app #412")],
    vendor: [
      rollup("vendor-a", [rows[0]!, rows[2]!, rows[3]!], "Vendor A"),
      rollup("vendor-b", [rows[1]!], "Vendor B"),
    ],
  },
};

/// A busy month: 2,000 sessions, windowed so a frame draws only the rows on screen.
const many = {
  ...reply,
  rows: Array.from({ length: 2000 }, (_, index) =>
    session(`m${index}`, `Session ${index + 1}`, Math.round(((index * 7919) % 2000) / 10) / 10, {
      repo: index % 3 ? "acme/app" : "acme/web",
    }),
  ),
};

const base: Props = { load: async () => reply, openSession: () => undefined, save: async () => "saved" };

/// A week whose cache went cold: most prompt tokens written again, few read.
const coldRows = rows.map((row) => ({
  ...row,
  cacheReadTokens: Math.round(row.cacheReadTokens / 20),
  cacheWriteTokens: Math.round(row.cacheReadTokens / 4),
}));
const cold = {
  ...reply,
  rows: coldRows,
  totals: {
    ...totals,
    cacheReadTokens: coldRows.reduce((sum, row) => sum + row.cacheReadTokens, 0),
    cacheWriteTokens: coldRows.reduce((sum, row) => sum + row.cacheWriteTokens, 0),
  },
};

export default componentEntry<Props>({
  id: "agent-pane.costs",
  title: "Costs",
  area: "Agent pane",
  covers: ["agent-session/acpmux/ledger/LedgerScreen.tsx#LedgerScreen"],
  styles: () => Promise.all([import("../styles.css"), import("./ledger.css")]),
  load: () => import("./LedgerScreen").then((module) => module.LedgerScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 560,
  anchors: [{ selector: ".cst" }],
  variants: {
    bars: {
      note: "Shipped: each session's share is a tonal fill behind its row, the cost at the end with its source mark. The strip and each row's detail line show the cache hit rate.",
      props: base,
    },
    table: {
      note: "Alternative: a column per measure (cache reads, cache writes and hit rate beside tokens in), the share as a thin line under the row.",
      props: { ...base, look: "table" },
    },
    "export-open": {
      note: "Export's menu open: CSV for a spreadsheet or JSON for a script, the range and grouping on screen, every row.",
      props: { ...base, initialExportOpen: true },
    },
    "cold-cache": {
      note: "A week whose prompt cache went cold: writes outnumber reads and the hit rate drops, in the strip and on every row.",
      props: { ...base, load: async () => cold },
    },
    "table-cold-cache": {
      note: "The table look over the cold week: the hit rate column reads low.",
      props: { ...base, look: "table", load: async () => cold },
    },
    "by-account": {
      note: "Grouped by the agent account each session ran on.",
      props: { ...base, initialGroup: "account" },
    },
    stacked: {
      note: "Alternative: two-line labels with the share bar beneath.",
      props: { ...base, look: "stacked" },
    },
    "by-repo": {
      note: "Grouped by repository: one rollup row each.",
      props: { ...base, initialGroup: "repo" },
    },
    "by-day": {
      note: "Grouped by day, in the page's language.",
      props: { ...base, initialGroup: "day" },
    },
    many: {
      note: "2,000 sessions: the list is windowed, so a frame costs the visible rows.",
      props: { ...base, load: async () => many },
    },
    loading: {
      note: "The first read is on its way: the strip holds its place with dashes.",
      props: { ...base, load: () => new Promise(() => {}) },
    },
    empty: {
      note: "No spend in the range.",
      props: { ...base, load: async () => ({ ...reply, totals: zero, rows: [], rollups: {} }) },
    },
    older: {
      note: "This Mac's acpmux predates the ledger: it says so instead of failing.",
      props: { ...base, load: async () => Promise.reject({ code: -32601, message: "Method not found" }) },
    },
  },
});
