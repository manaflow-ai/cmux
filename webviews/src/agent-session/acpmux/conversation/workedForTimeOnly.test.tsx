// l10n-allow-file: test fixtures.
// A closed "Worked for" reads its time alone by default: no "Ran 2 commands", "Finished 2" or "Read 3
// files" after it. Those counts live inside the fold, on its run lines (Leo, 2026-11-07,
// ask-db01e91a83: "inside the worked for, then you wouldn't need to have, like, the top-level finished
// two and ran eight"; 2026-11-25, on "23s · Ran 2 commands": "did we remove these yet"). #49934 brought
// them back by shipping workedLine's `outcome` arm; this pins every default that could do it again.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { setExperimentSwitches } from "../../../experiments/switches";
import { WORKED, turnView } from "./turns";
import { WorkedFor } from "./TurnRows";
import { workedLine } from "./workedLine.experiment";
import { turnFoldSteered } from "./turnFoldSteered.experiment";

type ArmHost = { cmuxExperiments?: Record<string, string> };
afterEach(() => {
  setExperimentSwitches({});
  delete (globalThis as ArmHost).cmuxExperiments;
});

let next = 0;
const call = (kind: string, extra: Record<string, unknown> = {}) => ({
  kind: "tool",
  text: "Step",
  tool: { id: `c${next++}`, title: "Step", kind, status: "completed", ...extra },
});
const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "Fix it" };
const work = (id: string, at: number, items: ReturnType<typeof call>[]) =>
  ({ id, version: 1, at, kind: "activity", items }) as AcpmuxRow;
const say = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const end: AcpmuxRow = {
  id: "s",
  version: 1,
  at: 23_000,
  kind: "turnSummary",
  status: "completed",
  durationMs: 23_000,
};
const turn = (items: ReturnType<typeof call>[]): AcpmuxRow[] => [
  prompt,
  work("w", 1_000, items),
  say("a", 20_000, "Done."),
  end,
];
const commands = (n: number, failed = 0) =>
  Array.from({ length: n }, (_, i) => call("execute", i < failed ? { status: "failed" } : {}));
const reads = (...paths: string[]) => paths.map((path) => call("read", { locations: [{ path }] }));
const edits = (...paths: string[]) => paths.map((path) => call("edit", { locations: [{ path }] }));

/// The closed line's words, as the person reads them.
function closedLine(rows: AcpmuxRow[], agentFamily: string): string {
  const row = turnView(rows, new Set(), { now: 30_000, agentFamily }).find((each) => each.kind === WORKED);
  expect(row).toBeDefined();
  const html = renderToStaticMarkup(<WorkedFor row={row!} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("cv-disclosure-chevron");
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

const TURNS: [string, ReturnType<typeof call>[]][] = [
  ["two commands", commands(2)],
  ["commands, one failed", commands(3, 1)],
  ["reads and edits", [...reads("a.ts", "b.ts", "c.ts"), ...edits("a.ts")]],
  ["a long mixed turn", [...commands(8), ...reads("a.ts"), ...edits("b.ts", "c.ts")]],
];

for (const family of ["claude", "codex", "opencode"])
  for (const [name, items] of TURNS)
    test(`${family}, ${name}: the closed Worked for reads its time alone`, () => {
      expect(closedLine(turn(items), family)).toBe("Worked for 23s");
    });

test("the defaults that would name the work on the line stay off", () => {
  // workedLine's every arm but `time` puts counts on the line (#49934 shipped `outcome`).
  expect(workedLine.defaultArm).toBe("time");
  // turnFoldSteered's `header` arm names the work on the line ("· Finished 2 background tasks and ran 8 commands").
  expect(turnFoldSteered.defaultArm).not.toBe("header");
});

test("an arm that names the work still can, so the guard above is what keeps the default clean", () => {
  (globalThis as ArmHost).cmuxExperiments = { "worked-line": "outcome" };
  expect(closedLine(turn(commands(2)), "claude")).not.toBe("Worked for 23s");
});
