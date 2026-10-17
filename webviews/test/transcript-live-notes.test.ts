// l10n-allow-file: test fixture rows, not shipped UI.
// A running turn's text that a step or more text followed is a note between steps, not the answer:
// turnView marks it `settled`, as its copy in an open "Worked for" is, so the brain thought style
// draws it as a thought line while the turn runs (Lucas 2026-10-17). The newest text stays a reply,
// since it may be the answer.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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
