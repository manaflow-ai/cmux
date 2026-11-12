// l10n-allow-file: transcript fixture replies and paths, not shipped UI.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { toggleTurnFold, turnViewFrom, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at: 1_000,
  version: 1,
  ...extra,
});
const read = (id: string) =>
  row(id, "activity", {
    items: [
      { kind: "tool", text: `Read ${id}.ts`, tool: { id, title: `Read ${id}.ts`, kind: "read", status: "completed" } },
    ],
  });
const prompt = row("prompt", "user", { text: "Check the two callers" });
const first = read("first");
const second = read("second");
const final = row("final", "assistant", { text: "Both callers are correct.", assistantPhase: "final_answer" });
const summary = row("summary", "turnSummary", { status: "completed" });
const foldId = `${WORKED}-prompt`;

function expectSeparate(rows: AcpmuxRow[], text: string) {
  const content = rows.filter((row) => row.kind === "activity" || row.kind === "assistant");
  expect(content.slice(0, 3).map((row) => [row.id, row.kind])).toEqual([
    ["first", "activity"],
    ["commentary", "assistant"],
    ["second", "activity"],
  ]);
  expect(content[1]?.text).toBe(text);
  expect(
    content
      .filter((row) => row.kind === "activity")
      .flatMap((row) => row.items ?? [])
      .map((item) => item.tool?.id),
  ).toEqual(["first", "second"]);
}

for (const family of ["codex", "claude", "gemini", "muse", undefined])
  for (const phase of ["commentary", undefined] as const)
    test(`${family ?? "default"}: ${phase ?? "unphased"} prose keeps consecutive tool groups separate while live and in an opened turn`, () => {
      for (const text of [
        "I'll check the other caller.",
        "This longer commentary remains its own paragraph. ".repeat(5),
      ]) {
        const commentary = row("commentary", "assistant", { text, assistantPhase: phase });
        const source = [prompt, first, commentary, second];
        const options = { working: true, agentFamily: family };
        const live = turnViewFrom(source, new Set(), options);
        expectSeparate(live.rows, text);
        const concluding = [...source, final];
        const expanded = toggleTurnFold(concluding, new Set(), foldId);
        const opened = turnViewFrom(concluding, expanded, options, live);
        expectSeparate(opened.rows, text);
        expect(opened.rows.find((row) => row.id === foldId)?.foldOpen).toBe(true);
        expect(opened.rows.filter((row) => row.id === "final")).toHaveLength(1);
        expect(opened.rows.findIndex((row) => row.id === "final")).toBeGreaterThan(
          opened.rows.findIndex((row) => row.id === "second"),
        );
        const completed = turnViewFrom([...concluding, summary], expanded, { ...options, working: false }, opened);
        expectSeparate(completed.rows, text);
        expect(completed.rows.filter((row) => row.id === "final")).toHaveLength(1);
        const closed = toggleTurnFold([...concluding, summary], expanded, foldId);
        const folded = turnViewFrom([...concluding, summary], closed, { ...options, working: false });
        expect(
          folded.rows.filter((row) => row.kind === "activity" || row.kind === "assistant").map((row) => row.id),
        ).toEqual(["final"]);
        const reopened = toggleTurnFold([...concluding, summary], closed, foldId);
        expectSeparate(turnViewFrom([...concluding, summary], reopened, { ...options, working: false }).rows, text);
      }
    });

for (const family of ["codex", "claude"])
  test(`${family}: adjacent calls coalesce on each side of a commentary paragraph`, () => {
    const third = read("third");
    const fourth = read("fourth");
    const commentary = row("commentary", "assistant", {
      text: "Checking the second pair.",
      assistantPhase: "commentary",
    });
    const source = [prompt, first, third, commentary, second, fourth, final, summary];
    const expanded = toggleTurnFold(source, new Set(), foldId);
    const opened = turnViewFrom(source, expanded, { working: false, agentFamily: family });
    const content = opened.rows.filter((entry) => entry.kind === "activity" || entry.kind === "assistant");
    expect(content.map((entry) => entry.id)).toEqual(["first", "commentary", "second", "final"]);
    expect(content[0]?.items?.map((item) => item.tool?.id)).toEqual(["first", "third"]);
    expect(content[2]?.items?.map((item) => item.tool?.id)).toEqual(["second", "fourth"]);
    expect(content[0]?.joined).toEqual(["first", "third"]);
    expect(content[2]?.joined).toEqual(["second", "fourth"]);
    expect(content[1]?.text).toBe(commentary.text);
  });
