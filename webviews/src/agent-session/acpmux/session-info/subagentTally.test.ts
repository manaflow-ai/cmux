// The Subagents head and its running limit's line read one tally (SubagentsSection.tsx
// `subagentTally`). Leo saw "2 running · 13 done" over "Running 1 / 1000 max" (2026-11-02: "yeah idk
// what's going on there"): the head counted the subagents and the chats, the limit only the chats.
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "../subagents/subagentFold";
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
