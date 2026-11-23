import { expect, test } from "bun:test";
import { curatedSections, modelSections } from "../src/agent-session/acpmux/modelSections";

const ids = (rows: readonly { id: string }[]) => rows.map((row) => row.id);

// Nov 9: Claude Code's live list named every model it can run (Fable 5.2 to Opus 4.8) as its menu.
// The composer's picker took that whole menu as its top section, so nothing reached Legacy, and
// Fable 5.2, which the catalog did not know yet, sat beside Fable 5.1.
test("a live menu that lists older versions keeps only each line's newest on top", () => {
  const rows = [
    { id: "claude-opus-5-5", name: "Opus 5.5", family: "Opus" },
    { id: "claude-fable-5-2", name: "Claude Fable 5.2" },
    { id: "claude-fable-5-1", name: "Fable 5.1", family: "Fable" },
    { id: "claude-fable-5", name: "Fable 5", family: "Fable" },
    { id: "claude-sonnet-5-5", name: "Sonnet 5.5", family: "Sonnet" },
    { id: "claude-haiku-5-5", name: "Haiku 5.5", family: "Haiku" },
    { id: "claude-opus-5", name: "Opus 5", family: "Opus" },
    { id: "claude-opus-4-8", name: "Opus 4.8", family: "Opus" },
  ];
  const { latest, older } = curatedSections(modelSections(rows, "Claude Code"), ids(rows));
  expect(ids(latest)).toEqual(["claude-opus-5-5", "claude-fable-5-2", "claude-sonnet-5-5", "claude-haiku-5-5"]);
  expect(new Set(ids(older))).toEqual(
    new Set(["claude-fable-5-1", "claude-fable-5", "claude-opus-5", "claude-opus-4-8"]),
  );
});
