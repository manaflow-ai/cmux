// Team's reader (teamAuditModel.ts): today's audit answer reads as it did, and the usage export's
// fields (usageExport.ts) ride along on the same row only when they are real counts.
import { expect, test } from "bun:test";
import { readTeamAudit, teamAuditParams } from "./teamAuditModel";
import { usageGroupAllowed } from "./usageExport";

const NOW = Date.UTC(2026, 10, 9, 15);
const row = {
  key: "ada",
  inputTokens: 10,
  outputTokens: 5,
  cacheReadTokens: 90,
  cacheWriteTokens: 0,
  cacheHitRate: 0.9,
  turns: 3,
  toolCalls: 4,
  wallMs: 60_000,
  sessions: 1,
};

test("an audit answer reads with no export fields and no privacy level", () => {
  const answer = readTeamAudit({
    status: "ok",
    audit: { scope: "team", range: {}, groupBy: "person", totals: row, rows: [row] },
  });
  if (answer.kind !== "ready") throw new Error(answer.kind);
  expect(answer.reply.privacy).toBeUndefined();
  expect(answer.reply.rows[0]).toEqual({ ...row });
  expect("prsLanded" in answer.reply.totals).toBe(false);
});

test("an export answer keeps its groupings, privacy level and measures, and drops what is not a count", () => {
  const exportRow = {
    ...row,
    key: "others",
    prsLanded: 4,
    agentMinutes: 120,
    ciMinutes: -3,
    costAsTimeMinutes: "9",
    foldedPeople: 3,
    outlier: true,
  };
  const answer = readTeamAudit({
    status: "ok",
    audit: {
      scope: "team",
      privacy: "team",
      range: {},
      groupBy: "project",
      totals: { ...row, minutesPerPr: 30 },
      rows: [exportRow],
    },
  });
  if (answer.kind !== "ready") throw new Error(answer.kind);
  expect(answer.reply.groupBy).toBe("project");
  expect(answer.reply.privacy).toBe("team");
  expect(answer.reply.totals.minutesPerPr).toBe(30);
  const [read] = answer.reply.rows;
  expect(read?.prsLanded).toBe(4);
  expect(read?.agentMinutes).toBe(120);
  expect(read?.foldedPeople).toBe(3);
  expect(read?.outlier).toBe(true);
  expect(read?.ciMinutes).toBeUndefined();
  expect(read?.costAsTimeMinutes).toBeUndefined();
});

test("a drill-down slice goes as where, and an empty one not at all", () => {
  expect(teamAuditParams("30d", "person", NOW, "json", { team: "platform" })).toEqual({
    since: "2026-10-11",
    until: "2026-11-09",
    groupBy: "person",
    format: "json",
    where: { team: "platform" },
  });
  expect("where" in teamAuditParams("30d", "person", NOW, "json", {})).toBe(false);
});

test("a privacy level hides the groupings finer than it", () => {
  expect(usageGroupAllowed("person", "team")).toBe(false);
  expect(usageGroupAllowed("project", "team")).toBe(true);
  expect(usageGroupAllowed("team", "org")).toBe(false);
  expect(usageGroupAllowed("session", "person")).toBe(false);
  expect(usageGroupAllowed("session", undefined)).toBe(true);
});
