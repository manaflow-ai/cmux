// A turn that ends on tool rows alone, no reply (Leo, 2026-11-27: "that's fine btw. but we do have a
// slightly awkward rendering situation here"): its closed "Worked for" draws no rule over the empty
// band under it (turns.ts `workedAlone`, TurnRows.tsx `data-alone`, conversation.css). A turn with a
// reply keeps its rule.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { WorkedFor } from "./TurnRows";
import { WORKED, turnView } from "./turns";

const run = (id: string, at: number): AcpmuxRow =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    toolCount: 2,
    items: [
      {
        kind: "tool",
        text: "cmux-gh land 60053 60188",
        tool: { id: `${id}-a`, title: "Queue lands", kind: "execute", status: "completed", command: "cmux-gh land" },
      },
      {
        kind: "tool",
        text: "Sent a message",
        tool: { id: `${id}-b`, title: "SendMessage", kind: "other", status: "completed" },
      },
    ],
  }) as AcpmuxRow;

function chat(reply: boolean): AcpmuxRow[] {
  return [
    { id: "ask", version: 1, at: 1_000, kind: "user", text: "Land both and hand off the rest" },
    run("work", 1_500),
    ...(reply ? [{ id: "reply", version: 1, at: 3_000, kind: "assistant", text: "Queued both." } as AcpmuxRow] : []),
    { id: "sum", version: 1, at: 3_800, kind: "turnSummary", status: "completed", durationMs: 2_800, toolCount: 2 },
  ];
}

const worked = (rows: AcpmuxRow[], family: string) =>
  turnView(rows, new Set(), { now: 10_000, agentFamily: family }).find((row) => row.kind === WORKED);

for (const family of ["claude", "codex"])
  test(`${family}: a turn with tool rows and no reply marks its Worked for alone; one with a reply does not`, () => {
    const alone = worked(chat(false), family);
    expect(alone?.workedAlone).toBe(true);
    expect(worked(chat(true), family)?.workedAlone).toBeUndefined();
  });

test("the alone line carries data-alone, so its closed rule goes; a replied turn's line does not", () => {
  const draw = (row: AcpmuxRow) => renderToStaticMarkup(<WorkedFor row={row} expanded={false} onToggle={() => {}} />);
  const base = { id: "w", version: 1, at: 0, kind: WORKED, status: "completed", durationMs: 2_800 } as AcpmuxRow;
  expect(draw({ ...base, workedAlone: true })).toContain('data-alone=""');
  expect(draw(base)).not.toContain("data-alone");
});
