// l10n-allow-file: test fixture text, not shipped UI.
// A background turn's row that comes after the next background turn began (a subagent it started,
// done later) draws as it came under the fold that turn already drew: never a second "Worked for"
// of the same id, which the layout read as one row jumping 334px (chat-sim replay-lane-session,
// d-shift at step 1714). Leo, on cmux#52785: "cuz 52785 we need to compare against current
// behaviour. current im still seeing a few weird folds/animations but we need to know if stuff
// fixes".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string, extra: Partial<AcpmuxRow> = {}) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "Ran tests", tool: { id, title: "bun test", kind: "execute", status: "completed" } }],
    ...extra,
  });
const line = (id: string) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, quiet: false, hasRows: true },
  });

const transcript = () => {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the suite and the lint in the background" }),
    row("started", "assistant", { text: "Both run in the background." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("a"),
    tool("read-a", { inBackground: "a" }),
    row("said-a", "assistant", { text: "The suite passed.", inBackground: "a" }),
    line("b"),
    tool("read-b", { inBackground: "b" }),
    row("said-b", "assistant", { text: "The lint passed.", inBackground: "b" }),
    // Turn a's late row, after turn b began.
    tool("late-a", { inBackground: "a" }),
  ];
};

for (const agentFamily of ["codex", "claude", undefined])
  test(`${agentFamily ?? "default"}: a background turn's late row draws no second fold of that turn`, () => {
    const view = turnView(transcript(), new Set(), { now: 60_000, agentFamily });
    const ids = view.map((entry) => entry.id);
    expect(
      ids.filter((id, index) => ids.indexOf(id) !== index),
      ids.join("\n"),
    ).toEqual([]);
  });
