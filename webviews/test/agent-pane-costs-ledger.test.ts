// l10n-allow-file: test fixtures (sample sessions and repos), not shipped UI.
// Costs (ledger/ledgerModel.ts): the `_acpmux/ledger` read for each range, the answer read
// defensively, rows grouped by session or by any rollup and ranked by cost with their bars, and
// where each cost came from (reported by the agent, priced from the table, or no price).
import { expect, test } from "bun:test";
import {
  cacheShare,
  costSource,
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
  cacheSavedUsd: 0,
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
    groupBy: ["workspace", "repo", "pr", "day", "person", "vendor", "model", "account"],
  });
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

test("cache reads: what they saved, and their share of all input", () => {
  const read = readLedger({
    totals: totals({ cacheSavedUsd: 3.8, inputTokens: 10, cacheReadTokens: 80, cacheWriteTokens: 10 }),
  });
  expect(read.totals.cacheSavedUsd).toBe(3.8);
  expect(cacheShare(read.totals)).toBe(0.8);
  // No input at all: no share, never 0% of nothing.
  expect(cacheShare(totals())).toBeUndefined();
  // An older acpmux sends no saving: it reads as zero.
  expect(readLedger({ totals: totals() }).totals.cacheSavedUsd).toBe(0);
});

test("Copy CSV: the rows shown, ranked as shown, spreadsheet-safe", () => {
  const sessions = ledgerCsv(reply, "session").split("\n");
  expect(sessions[0]).toBe(
    "session,label,harness,repo,branch,models,costUsd,harnessCostUsd,tableCostUsd,unpricedTurns,inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,cacheSavedUsd,turns,toolCalls,wallMs,sessions",
  );
  expect(sessions[1]!.startsWith("s2,Upload retry,,,,model-b,8,8,0,")).toBe(true);
  expect(sessions[2]!.startsWith("s1,Docs pass,,acme/app,lane/docs,model-a,2,0,2,")).toBe(true);
  expect(sessions.at(-1)).toBe("");
  const repos = ledgerCsv(reply, "repo").split("\n");
  expect(repos[0]!.startsWith("repo,label,costUsd,")).toBe(true);
  expect(repos[1]!.startsWith("acme/app,App,5,4,1,")).toBe(true);
  const tricky = readLedger({
    totals: totals(),
    rows: [],
    rollups: { account: [{ ...totals({ costUsd: 1 }), key: '=cmd|"x", y' }] },
  });
  // A tab or line break would split the cell on paste and leave `=1+1` a cell of its own.
  const tabbed = readLedger({
    totals: totals(),
    rows: [],
    rollups: { account: [{ ...totals(), key: "audit\t=1+1\nend" }] },
  });
  expect(ledgerCsv(tabbed, "account").split("\n")[1]!.startsWith("audit =1+1 end,audit =1+1 end,")).toBe(true);
  expect(ledgerCsv(tricky, "account").split("\n")[1]!.startsWith(`"'=cmd|""x"", y","'=cmd|""x"", y",1,`)).toBe(true);
});

test("Save's read asks for acpmux's most sessions, and a session row keeps its account", () => {
  expect(ledgerParams("7d", NOW, 5000).limit).toBe(5000);
  expect(reply.rows.find((row) => row.sessionId === "s1")!.account).toBe("work");
  expect(reply.rows.find((row) => row.sessionId === "s2")!.account).toBeUndefined();
});

test("JSON holds the range, the price table, the totals and every row with its cost source", () => {
  const read = readLedger({
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
    ],
    rollups: {},
  });
  const body = JSON.parse(ledgerJson(read, "7d", "session"));
  expect(body.range).toEqual({
    name: "7d",
    since: new Date(NOW - 7 * 24 * HOUR).toISOString(),
    until: new Date(NOW).toISOString(),
  });
  expect(body.groupBy).toBe("session");
  expect(body.priceTable).toEqual({ version: "2026-11-08", currency: "USD" });
  // The share from cache is the page's (`cacheShare`), to four places.
  expect(body.totals.cacheShare).toBe(0.9);
  expect(body.rows.map((row: { key: string }) => row.key)).toEqual(["s2", "s1"]);
  const [second, first] = body.rows;
  expect(second.costSource).toBe("table");
  expect("cacheShare" in second).toBe(false);
  expect(first.costSource).toBe("harness");
  expect(first.costUsd).toBe(0.3);
  // JSON keeps a title whole: quotes, commas and the line break.
  expect(first.label).toBe('Fix "quotes", commas\nand lines');
  expect(first.models).toBe("model-a model-b");
  expect(first.account).toBe("work");
  expect(first.lastAt).toBe(new Date(NOW).toISOString());
  // A rollup row has no session fields.
  const repos = JSON.parse(ledgerJson(reply, "7d", "repo"));
  expect(repos.rows[0]).toMatchObject({ key: "acme/app", label: "App", costSource: "mixed" });
  expect("harness" in repos.rows[0]).toBe(false);
  const day = new Date(NOW).toISOString().slice(0, 10);
  expect(ledgerFileName(read, "7d", "repo")).toBe(`cmux-costs-7d-by-repo-${day}`);
});

test("Save writes through the host's save panel, and copies when the host cannot save", async () => {
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
  expect(await save("a,b\n", "cmux-costs", "csv")).toBe("saved");
  expect(calls[0]).toEqual({
    method: "pane.saveFile",
    params: { text: "a,b\n", suggestedName: "cmux-costs", kind: "csv" },
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

test("a session file short of the range's sessions says how many it holds, and a rollup never is", () => {
  const short = { ...reply, totals: { ...reply.totals, sessions: 7 } };
  expect(ledgerShortfall(short, "session")).toEqual({ shown: 3, total: 7 });
  expect(ledgerShortfall(reply, "session")).toBeUndefined();
  expect(ledgerShortfall(short, "repo")).toBeUndefined();
  const body = JSON.parse(ledgerJson(short, "7d", "session"));
  expect(body.truncated).toBe(true);
  expect(body.sessionsTotal).toBe(7);
  expect(JSON.parse(ledgerJson(reply, "7d", "session")).truncated).toBe(false);
  // A rollup holds every group: no such fields.
  expect("truncated" in JSON.parse(ledgerJson(short, "7d", "repo"))).toBe(false);
});
