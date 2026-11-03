// The Subagents head and its running limit's line read one tally (SubagentsSection.tsx
// `subagentTally`). Leo saw "2 running · 13 done" over "Running 1 / 1000 max" (2026-11-02: "yeah idk
// what's going on there"): the head counted the subagents and the chats, the limit only the chats.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "../subagents/subagentFold";
import { slotCounts, subagentCounts, subagentTally } from "./SubagentsSection";
import { NativeInfoActions } from "./native/model";
import { subagentsSection } from "./native/subagents";

const t = translatorFor("en");
const agent = (id: string, state: string): Subagent => ({ id, parent: null, name: id, state, startedAt: 1 });
const agents: Subagent[] = [
  agent("a-1", "running"),
  ...Array.from({ length: 13 }, (_, index) => agent(`done-${index}`, "completed")),
];
const sessions: StartedSession[] = [
  { sessionId: "c-1", title: "Run the suite", state: "running", createdAt: 1 },
  { sessionId: "c-2", title: "Audit the strings", state: "idle", waitsForSlot: true, createdAt: 2 },
];
const limits = { maxRunning: 1000, maxRunningSource: "default" as const };

test("the head and the limit count the same running set", () => {
  const tally = subagentTally(agents, new Set(), sessions, limits);
  expect(subagentCounts(t, tally)).toBe("2 running · 1 queued · 13 done");
  expect(slotCounts(tally)).toEqual({ running: 2, queued: 1 });
});

test("the native panel's limit row says the head's running count", () => {
  const section = subagentsSection(
    { open: true, agents, waiting: new Set(), sessions, limits, now: 2 },
    new NativeInfoActions(),
    t,
  )!;
  expect(section.meta).toBe("2 running · 1 queued · 13 done");
  const limit = section.rows.find((row) => row.id === "limit")!;
  expect(limit.title).toBe("Running 2 / 1000 max");
  expect(limit.detail).toBe("1 queued");
});

test("before the list names a chat, acpmux's own counts stand in for both", () => {
  const tally = subagentTally([agent("a-1", "running")], new Set(), [], { ...limits, running: 3, queued: 2 });
  expect(subagentCounts(t, tally)).toBe("4 running · 2 queued");
  expect(slotCounts(tally)).toEqual({ running: 4, queued: 2 });
});
