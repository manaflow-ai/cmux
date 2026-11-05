// l10n-allow-file: synthetic transcript fixtures.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED, toggleTurnFold } from "../src/agent-session/acpmux/conversation/turns";

beforeEach(() => {
  globalThis.cmuxExperiments = { "tool-activity-presentation": "t3" };
});
afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});
const row = (id: string, kind: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at,
  version: 1,
  ...fields,
});
const run = (id: string, at: number, status = "completed") =>
  row(id, "activity", at, {
    items: [{ kind: "tool", text: id, tool: { id, title: id, command: `echo ${id}`, kind: "execute", status } }],
  });
const prompt = row("prompt", "user", 0, { text: "Check the project" });
const prose = row("prose", "assistant", 2000, {
  text: "A substantial answer.\n\n- Keep all of this text.\n- Including the list.",
});
const final = row("final", "assistant", 4000, { text: "Done." });
const ended = row("end", "turnSummary", 5000, { status: "completed", durationMs: 5000 });
const source = [prompt, run("read", 1000), prose, run("test", 3000), final, ended];

for (const family of ["codex", "claude", "claude-sr2", "gemini", "muse", "opencode", undefined]) {
  test(`${family}: settled work and intermediate prose fold, with the last reply visible`, () => {
    const closed = turnView(source, new Set(), { agentFamily: family, liveRuns: true });
    expect(closed.map((r) => r.id)).toEqual(["prompt", "worked-prompt", "final", "end"]);
    expect(closed.find((r) => r.kind === WORKED)?.previous).toBeUndefined();
    const opened = turnView(source, new Set(["worked-prompt"]), { agentFamily: family, liveRuns: true });
    expect(opened.find((r) => r.id === "prose")?.text).toBe(prose.text);
    expect(
      opened
        .filter((r) => r.kind === "activity")
        .flatMap((r) => r.items ?? [])
        .map((i) => i.tool?.id),
    ).toEqual(["read", "test"]);
    expect(source[2]?.text).toBe(prose.text);
  });
}

for (const status of ["failed", "cancelled"])
  test(`${status}: keep the entire turn available without a turn fold`, () => {
    const rows = turnView([...source.slice(0, -1), { ...ended, status }], new Set(), {
      agentFamily: "claude",
      liveRuns: true,
    });
    expect(rows.some((r) => r.kind === WORKED)).toBe(false);
    expect(rows.find((r) => r.id === "prose")?.text).toBe(prose.text);
    expect(rows.find((r) => r.id === "test")).toBeDefined();
  });

test("live tools have an expandable activity row and keep every original tool", () => {
  const raw = [prompt, prose, run("one", 3000), run("two", 4000, "in_progress")];
  const options = { working: true, liveRuns: true, lineBelow: true, agentFamily: "claude" };
  const closed = turnView(raw, new Set(), options);
  const live = closed.find((r) => r.activityFold)!;
  expect(live?.activityFold).toBe("live-work-one");
  expect(live?.foldOpen).toBe(false);
  expect(closed.find((r) => r.id === "prose")?.text).toBe(prose.text);
  expect(closed.some((r) => r.kind === "activity")).toBe(false);
  const expanded = toggleTurnFold(raw, new Set(), live.activityFold!);
  const open = turnView(raw, expanded, options);
  expect(open.filter((r) => r.kind === "activity").map((r) => r.id)).toEqual(["one", "two"]);
  expect(open.find((r) => r.activityFold)?.foldOpen).toBe(true);
});

test("a final message before a trailing tool stays visible even when it is short", () => {
  const closed = turnView([prompt, prose, final, run("tail", 4500), ended], new Set(), { agentFamily: "claude" });
  expect(closed.find((r) => r.id === "final")?.text).toBe("Done.");
  expect(closed.find((r) => r.id === "prose")).toBeUndefined();
});
