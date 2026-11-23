// l10n-allow-file: subagent fixtures.
// A start line that names two dozen helpers drew two dozen chips sharing one line's width, each cut
// to its padding: empty grey pills between sparkles and commas (Leo, 2026-11-22, after a restart:
// "and more bullshit somehow happened here").
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SubagentStartedLine } from "../src/agent-session/acpmux/subagents/SubagentStartedLine";
import { STARTED_LINE_NAMES } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_STARTED } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const helper = (index: number): Subagent => ({
  id: `helper-${index}`,
  parent: null,
  name: `Helper ${index}`,
  task: `Audit package ${index}`,
  state: "completed",
  startedAt: 1_000,
  endedAt: 61_000,
});
const line = (count: number) => {
  const row: AcpmuxRow = {
    id: "started",
    kind: SUBAGENT_STARTED,
    at: 1_000,
    version: 1,
    subagents: Array.from({ length: count }, (_, index) => helper(index)),
    // As runningTray.ts startedLineModel decides it.
    startedNamed: Math.min(count, STARTED_LINE_NAMES),
  };
  return renderToStaticMarkup(<SubagentStartedLine row={row} />);
};
const chips = (html: string) => html.match(/class="cv-agent-tag[ "]/g)?.length ?? 0;

// Base draws a crowd of STARTED_CROWD_FROM or more as faces and a count (startedLineCrowd), and the
// chips arm names at most STARTED_LINE_NAMES (runningTray.ts): either way no chip is cut to a pill.
test("a start line of two dozen helpers never draws two dozen chips", () => {
  const html = line(24);
  expect(chips(html)).toBeLessThanOrEqual(STARTED_LINE_NAMES);
  expect(html).not.toContain(">Audit package 23<");
});

test("a start line of two helpers names both", () => {
  const html = line(2);
  expect(chips(html)).toBe(2);
  expect(html).toContain(">Audit package 0<");
  expect(html).toContain(">Audit package 1<");
  expect(html).not.toContain("more");
});
