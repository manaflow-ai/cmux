// l10n-allow-file: test fixtures (sample sessions and repos), not shipped UI.
// Costs (ledger/ledgerModel.ts): the `_acpmux/ledger` read for each range, the answer read
// defensively, rows grouped by session or by any rollup and ranked by cost with their bars, and
// where each cost came from (reported by the agent, priced from the table, or no price).
import { expect, test } from "bun:test";
import {
  cacheHitRate,
  costSource,
  csvField,
  formatCost,
  groupLabel,
  LEDGER_GROUPS,
  ledgerCsv,
  ledgerFileName,
  ledgerJson,
  ledgerLines,
  ledgerParams,
  ledgerShortfall,
  readLedger,
  tokensIn,
} from "../src/agent-session/acpmux/ledger/ledgerModel";
import { historyPages } from "../src/agent-session/acpmux/queue/historyPages";
import { cacheReadShare } from "../src/agent-session/acpmux/usageStats";

const HOUR = 3_600_000;
const NOW = 1_800_000_000_000;

const totals = (over: Record<string, number> = {}) => ({
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
  sessions: 0,
  ...over,
});

const reply = readLedger({
  priceTable: { version: "2026-11-08", currency: "USD" },
  range: { since: NOW - 7 * 24 * HOUR, until: NOW },
  totals: totals({ costUsd: 12, harnessCostUsd: 9, tableCostUsd: 3, unpricedTurns: 2, turns: 40 }),
  rows: [
    {
      ...totals({ costUsd: 2, tableCostUsd: 2, turns: 10 }),
      sessionId: "s1",
      title: "Docs pass",
      models: ["model-a"],
      pullRequests: [],
      repo: "acme/app",
      branch: "lane/docs",
      account: "work",
    },
    {
      ...totals({ costUsd: 8, harnessCostUsd: 8, turns: 20 }),
      sessionId: "s2",
      title: "Upload retry",
      models: ["model-b"],
      pullRequests: ["https://example.com/pull/3"],
    },
    { ...totals({ unpricedTurns: 4, turns: 4 }), sessionId: "s3", title: "Local model", models: [], pullRequests: [] },
    // Not a row: no session id.
    { ...totals({ costUsd: 99 }), title: "nobody" },
  ],
  rollups: {
    repo: [
      { ...totals({ costUsd: 1, tableCostUsd: 1 }), key: "acme/web" },
      { ...totals({ costUsd: 5, harnessCostUsd: 4, tableCostUsd: 1 }), key: "acme/app", label: "App" },
    ],
    day: [{ ...totals({ costUsd: 3 }), key: "2026-11-07" }],
    vendor: "not a list",
  },
});

test("each range asks for its window and every rollup in one read", () => {
  expect(ledgerParams("24h", NOW)).toEqual({
    since: NOW - 24 * HOUR,
    until: NOW,
    limit: 200,
    groupBy: ["workspace", "repo", "pr", "day", "person", "account", "vendor", "model"],
  });
  expect(ledgerParams("7d", NOW, 5000).limit).toBe(5000);
  expect(ledgerParams("7d", NOW).since).toBe(NOW - 7 * 24 * HOUR);
  expect(ledgerParams("30d", NOW).since).toBe(NOW - 30 * 24 * HOUR);
  // All time starts at the epoch: acpmux reads a missing start as its own default window.
  expect(ledgerParams("all", NOW).since).toBe(0);
  expect(LEDGER_GROUPS[0]).toBe("session");
});

test("the answer is read defensively: whole rows only, missing numbers as zero", () => {
  expect(reply.rows.map((row) => row.sessionId)).toEqual(["s1", "s2", "s3"]);
  expect(reply.priceTable).toEqual({ version: "2026-11-08", currency: "USD" });
  expect(reply.rollups.vendor).toBeUndefined();
  const empty = readLedger({ totals: { costUsd: "lots", turns: -3 } });
  expect(empty.totals.costUsd).toBe(0);
  expect(empty.totals.turns).toBe(0);
  expect(empty.rows).toEqual([]);
  expect(empty.priceTable).toBeUndefined();
});

test("session rows rank by cost with bars against the largest, and each opens its chat", () => {
  const lines = ledgerLines(reply, "session");
  expect(lines.map((line) => [line.key, line.share, line.sessionId])).toEqual([
    ["s2", 1, "s2"],
    ["s1", 0.25, "s1"],
    ["s3", 0, "s3"],
  ]);
  expect(lines[1]!.detail).toBe("acme/app · lane/docs · model-a");
  expect(lines.map((line) => line.source)).toEqual(["harness", "table", "unpriced"]);
});

test("a rollup groups the same way, with its label; one acpmux did not send is empty", () => {
  const repos = ledgerLines(reply, "repo");
  expect(repos.map((line) => [line.label, line.share, line.source, line.sessionId])).toEqual([
    ["App", 1, "mixed", undefined],
    ["acme/web", 0.2, "table", undefined],
  ]);
  expect(ledgerLines(reply, "vendor")).toEqual([]);
  expect(ledgerLines(reply, "person")).toEqual([]);
});

test("where a cost came from", () => {
  const source = (over: Record<string, number>) => costSource(totals(over) as never);
  expect(source({ harnessCostUsd: 1 })).toBe("harness");
  expect(source({ tableCostUsd: 1 })).toBe("table");
  expect(source({ harnessCostUsd: 1, tableCostUsd: 1 })).toBe("mixed");
  // Some turns had no price: the cost is a floor.
  expect(source({ harnessCostUsd: 1, unpricedTurns: 1 })).toBe("mixed");
  expect(source({ tableCostUsd: 1, unpricedTurns: 1 })).toBe("mixed");
  expect(source({ unpricedTurns: 3 })).toBe("unpriced");
  expect(source({})).toBe("none");
});

test("money keeps its cents, and a positive amount under a cent never reads as nothing", () => {
  expect(formatCost(12.5, "en")).toBe("$12.50");
  expect(formatCost(0, "en")).toBe("$0.00");
  expect(formatCost(0.001, "en")).toBe("<$0.01");
  expect(formatCost(0.006, "en")).toBe("$0.01");
});

test("a day's key reads as a date; other keys as they are", () => {
  const [day] = ledgerLines(reply, "day");
  expect(groupLabel("day", day!, "en")).toBe("Sat, Nov 7");
  const [repo] = ledgerLines(reply, "repo");
  expect(groupLabel("repo", repo!, "en")).toBe("App");
});

test("ranking a long list stays one sort: 10,000 sessions group in one pass", () => {
  const rows = Array.from({ length: 10_000 }, (_, index) => ({
    ...totals({ costUsd: index % 97, turns: 1 }),
    sessionId: `s${index}`,
    title: `Session ${index}`,
    models: [],
    pullRequests: [],
  }));
  const big = readLedger({ totals: totals(), rows, rollups: {} });
  const started = performance.now();
  const lines = ledgerLines(big, "session");
  expect(performance.now() - started).toBeLessThan(500);
  expect(lines[0]!.totals.costUsd).toBe(96);
  expect(lines.at(-1)!.totals.costUsd).toBe(0);
});

test("tokens in counts uncached input and cache writes, never cache reads", () => {
  expect(tokensIn(totals({ inputTokens: 120, cacheWriteTokens: 30, cacheReadTokens: 90_000 }))).toBe(150);
  expect(tokensIn(totals())).toBe(0);
});

test("the cache hit rate is Session Info's prompt cache share: reads over uncached input, reads and writes", () => {
  const counts = totals({ inputTokens: 100, cacheReadTokens: 9_400, cacheWriteTokens: 500 });
  expect(cacheHitRate(counts as never)).toBe(0.94);
  expect(cacheHitRate(counts as never)).toBe(cacheReadShare(9_400, 100, 500));
  // Four places, as acpmux rounds `cacheReadShare24h`.
  expect(cacheHitRate(totals({ inputTokens: 2, cacheReadTokens: 1 }) as never)).toBe(0.3333);
  // No prompt tokens: unknown, never 0%.
  expect(cacheHitRate(totals() as never)).toBeUndefined();
});

test("a session row keeps its account", () => {
  expect(reply.rows.find((row) => row.sessionId === "s1")!.account).toBe("work");
  expect(reply.rows.find((row) => row.sessionId === "s2")!.account).toBeUndefined();
});

/// A CSV parser that honors quotes (RFC 4180), so a test reads back what a spreadsheet would.
function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (quoted && c === '"' && text[i + 1] === '"') {
      field += '"';
      i++;
    } else if (quoted && c === '"') {
      quoted = false;
    } else if (quoted) {
      field += c;
    } else if (c === '"') {
      quoted = true;
    } else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\r" && text[i + 1] === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
      i++;
    } else {
      field += c;
    }
  }
  return rows;
}

test("a CSV field is quoted for commas, quotes and line breaks, and never runs as a formula", () => {
  expect(csvField("plain")).toBe("plain");
  expect(csvField("a, b")).toBe('"a, b"');
  expect(csvField('say "hi"')).toBe('"say ""hi"""');
  expect(csvField("one\ntwo")).toBe('"one\ntwo"');
  expect(csvField("one\r\ntwo")).toBe('"one\r\ntwo"');
  expect(csvField("=HYPERLINK(1)")).toBe("'=HYPERLINK(1)");
  expect(csvField("-rm, all")).toBe(`"'-rm, all"`);
  expect(csvField(0.25)).toBe("0.25");
  expect(csvField(undefined)).toBe("");
});

const titled = readLedger({
  priceTable: { version: "2026-11-08", currency: "USD" },
  range: { since: NOW - 7 * 24 * HOUR, until: NOW },
  totals: totals({ costUsd: 3, harnessCostUsd: 3, turns: 3, sessions: 3, inputTokens: 10, cacheReadTokens: 90 }),
  rows: [
    {
      ...totals({ costUsd: 0.1 + 0.2, harnessCostUsd: 0.1 + 0.2, turns: 1, inputTokens: 10, cacheReadTokens: 90 }),
      sessionId: "s1",
      title: 'Fix "quotes", commas\nand lines',
      models: ["model-a", "model-b"],
      pullRequests: ["https://example.com/pull/1"],
      repo: "acme/app",
      account: "work",
      lastAt: NOW,
    },
    {
      ...totals({ costUsd: 2, tableCostUsd: 2, turns: 1 }),
      sessionId: "s2",
      title: "Second",
      models: [],
      pullRequests: [],
    },
    { ...totals({ unpricedTurns: 1, turns: 1 }), sessionId: "s3", title: "Third", models: [], pullRequests: [] },
  ],
  rollups: { repo: [{ ...totals({ costUsd: 3, harnessCostUsd: 3 }), key: "acme/app" }] },
});

test("CSV holds every row of the grouping with its source, the range and the price table", () => {
  const csv = ledgerCsv(titled, "session");
  expect(csv.endsWith("\r\n")).toBe(true);
  const [header, ...rows] = parseCsv(csv);
  // Every row, not only the ones a screen shows, most expensive first.
  expect(rows.map((row) => row[header!.indexOf("sessionId")])).toEqual(["s2", "s1", "s3"]);
  const at = (row: string[], column: string) => row[header!.indexOf(column)];
  const first = rows[1]!;
  // The title round-trips through the quoting: commas, quotes and the line break intact.
  expect(at(first, "label")).toBe('Fix "quotes", commas\nand lines');
  expect(at(first, "costUsd")).toBe("0.3");
  expect(at(first, "costSource")).toBe("harness");
  expect(at(first, "cacheHitRate")).toBe("0.9");
  expect(at(first, "models")).toBe("model-a model-b");
  expect(at(first, "account")).toBe("work");
  expect(at(first, "priceTableVersion")).toBe("2026-11-08");
  expect(at(first, "rangeSince")).toBe(new Date(NOW - 7 * 24 * HOUR).toISOString());
  expect(at(first, "rangeUntil")).toBe(new Date(NOW).toISOString());
  expect(at(rows[0]!, "costSource")).toBe("table");
  expect(at(rows[2]!, "costSource")).toBe("unpriced");
  // No prompt tokens: an empty cell, not 0.
  expect(at(rows[2]!, "cacheHitRate")).toBe("");
  // A rollup has its own rows and no session fields.
  const [repoHeader, repo] = parseCsv(ledgerCsv(titled, "repo"));
  expect(repo![repoHeader!.indexOf("key")]).toBe("acme/app");
  expect(repo![repoHeader!.indexOf("sessionId")]).toBe("");
});

test("JSON holds the range, the price table, the totals with the hit rate, and every row", () => {
  const body = JSON.parse(ledgerJson(titled, "7d", "session"));
  expect(body.range).toEqual({
    name: "7d",
    since: new Date(NOW - 7 * 24 * HOUR).toISOString(),
    until: new Date(NOW).toISOString(),
  });
  expect(body.groupBy).toBe("session");
  expect(body.priceTable).toEqual({ version: "2026-11-08", currency: "USD" });
  expect(body.totals.cacheHitRate).toBe(0.9);
  expect(body.totals.costSource).toBe("harness");
  expect(body.rows).toHaveLength(3);
  expect(body.rows[1].label).toBe('Fix "quotes", commas\nand lines');
  expect(body.rows[1].pullRequests).toBe("https://example.com/pull/1");
  // An absent field is left out, not null.
  expect("cacheHitRate" in body.rows[2]).toBe(false);
  const day = new Date(NOW).toISOString().slice(0, 10);
  expect(ledgerFileName(titled, "7d", "repo")).toBe(`cmux-costs-7d-by-repo-${day}`);
});

test("Export saves through the host's save panel, and copies when the host cannot save", async () => {
  const calls: { method: string; params: Record<string, unknown> | undefined }[] = [];
  const copied: string[] = [];
  let host: "save" | "cancel" | "refuse" = "save";
  const pages = historyPages({
    client: () => undefined,
    callNative: async <T>(method: string, params?: Record<string, unknown>) => {
      calls.push({ method, params });
      if (host === "refuse") throw new Error("unsupported");
      return (host === "save") as unknown as T;
    },
    selectSession: () => {},
    asks: [],
    copy: async (text) => {
      copied.push(text);
      return text !== "refused";
    },
  });
  const save = pages.ledger.save!;
  expect(await save("a,b\r\n", "cmux-costs", "csv")).toBe("saved");
  expect(calls[0]).toEqual({
    method: "pane.saveFile",
    params: { text: "a,b\r\n", suggestedName: "cmux-costs", kind: "csv" },
  });
  host = "cancel";
  expect(await save("{}", "cmux-costs", "json")).toBe("cancelled");
  expect(copied).toEqual([]);
  // An app that predates the kind refuses it: the file goes to the clipboard instead.
  host = "refuse";
  expect(await save("{}", "cmux-costs", "json")).toBe("copied");
  expect(copied).toEqual(["{}"]);
  await expect(save("refused", "cmux-costs", "csv")).rejects.toThrow();
});

test("a session export short of the range's sessions says how many it holds, and a rollup never is", () => {
  const short = readLedger({ ...JSON.parse(JSON.stringify(titled)), totals: totals({ sessions: 7 }) });
  expect(ledgerShortfall(short, "session")).toEqual({ shown: 3, total: 7 });
  expect(ledgerShortfall(titled, "session")).toBeUndefined();
  expect(ledgerShortfall(short, "repo")).toBeUndefined();
  const body = JSON.parse(ledgerJson(short, "7d", "session"));
  expect(body.truncated).toBe(true);
  expect(body.sessionsTotal).toBe(7);
  expect(JSON.parse(ledgerJson(titled, "7d", "session")).truncated).toBe(false);
  // A rollup holds every group: no such fields.
  expect("truncated" in JSON.parse(ledgerJson(short, "7d", "repo"))).toBe(false);
});
