// l10n-allow-file: test fixture rows, not shipped UI.
// A running turn's text that a step or more text followed is a note between steps, not the answer:
// turnView marks it `settled`, as its copy in an open "Worked for" is, so the brain thought style
// draws it as a thought line while the turn runs (Lucas 2026-10-17). The newest text stays a reply,
// since it may be the answer.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { STARTED_SESSIONS } from "../src/agent-session/acpmux/started/startedSessions";

const user: AcpmuxRow = { id: "u1", version: 1, at: 1_000, kind: "user", text: "check the flow" };
const note = (id: string, at: number): AcpmuxRow => ({ id, version: 3, at, kind: "assistant", text: `note ${id}` });
const step = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "activity",
  items: [
    { kind: "tool", text: "", tool: { id: `${id}-t`, title: "Run git log", kind: "execute", status: "completed" } },
  ],
});

test("a running turn's earlier notes are settled; its newest text is not", () => {
  const rows = turnView([user, note("a1", 2_000), step("s1", 3_000), note("a2", 4_000)], new Set(), {
    working: true,
    now: 5_000,
  });
  const byId = new Map(rows.map((row) => [row.id, row]));
  expect(byId.get("a1")?.settled).toBe(true);
  expect(byId.get("a1")?.version).toBe(7);
  expect(byId.get("a2")?.settled).toBeUndefined();
  expect(byId.get("a2")?.version).toBe(3);
});

test("a note that the turn's work follows is settled while that work runs", () => {
  const rows = turnView([user, note("a1", 2_000), step("s1", 3_000)], new Set(), { working: true, now: 5_000 });
  expect(rows.find((row) => row.id === "a1")?.settled).toBe(true);
});

test("a started chats card after the newest reply leaves it an answer, not a thought note", () => {
  const answer = note("answer", 4_000);
  const card: AcpmuxRow = { id: "started", version: 1, at: 5_000, kind: STARTED_SESSIONS };
  for (const sessionStatus of [false, true]) {
    const rows = turnView([user, note("a1", 2_000), step("s1", 3_000), answer, card], new Set(), {
      working: true,
      sessionStatus,
    });
    expect(rows.find((row) => row.id === "a1")?.settled).toBe(true);
    expect(rows.find((row) => row.id === answer.id)).toBe(answer);
    expect(rows).toContain(card);
  }
});

test("the activity line under a plan keeps earlier notes settled and the newest thought live", () => {
  const plan: AcpmuxRow = {
    id: "plan",
    version: 1,
    at: 3_000,
    kind: "plan",
    plan: [{ content: "Check the flow", status: "in_progress" }],
  };
  const thought: AcpmuxRow = {
    id: "thought",
    version: 2,
    at: 4_000,
    kind: "activity",
    items: [{ kind: "thought", text: "Checking the flow" }],
  };
  const card: AcpmuxRow = { id: "started", version: 1, at: 5_000, kind: STARTED_SESSIONS };
  const rows = turnView([user, note("a1", 2_000), plan, thought, card], new Set(), {
    working: true,
    sessionStatus: true,
    liveRuns: true,
  });
  expect(rows.find((row) => row.id === "a1")?.settled).toBe(true);
  expect(rows.find((row) => row.id === thought.id)).toMatchObject({ live: true, inFlight: true });
  expect(rows.slice(-2).map((row) => row.kind)).toEqual(["plan", "activityLine"]);
  expect(rows).toContain(card);
});
