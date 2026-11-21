// l10n-allow-file: test fixtures, not shipped UI.
// The run a running turn works in stays open until the agent's next paragraph (liveRunFold.experiment.ts
// `paragraph`). Before, it closed the moment its second call finished: a thought, a command and a
// thought, three lines, became one closed "Ran 2 commands" line mid-turn, 74px to 22px with nothing new
// under it (the chat simulator's Chrome lane, `b-mid-turn-shrink`, incoming-notice-turn step 33).
//
// Leo, 2026-11-21: "the messages and whatever collapsing and stuff, sometimes it does so too soon in the
// midst of a turn. thats not great."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { layoutConversation } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const armsBefore = globalThis.cmuxExperiments;
const withArm = <T,>(arm: string | undefined, run: () => T): T => {
  const saved = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { ...saved, ...(arm && { "live-run-fold": arm }) };
  try {
    return run();
  } finally {
    globalThis.cmuxExperiments = saved;
  }
};
beforeAll(() => {
  globalThis.cmuxExperiments = { ...armsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = armsBefore;
});

let clock = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (clock += 1_000),
  ...extra,
});
const command = (line: string, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: line,
  tool: { id: line, title: line, kind: "execute", status, command: line, startedAt: clock, endedAt: clock + 500 },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text, at: clock, endedAt: clock + 2_000 });

/// A running turn: the prompt, then the run the agent works in: a thought, a command, a thought, and a
/// second command, `second` its status. `reply`: the agent's next paragraph under it.
const turn = (version: number, second: string, reply = false) => [
  row("u", "user", { text: "Restart the broker on both hosts" }),
  row("work", "activity", {
    version,
    items: [
      thought("I'm checking whether restarting the broker is safe. ".repeat(2)),
      command("broker status"),
      thought("There's no restart subcommand; reading its help."),
      command("broker --help", second),
    ],
  }),
  ...(reply
    ? [row("said", "assistant", { text: "The broker has no restart; stopping and starting it instead. " })]
    : []),
];
const run = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true }).find((entry) => entry.id === "work")!;
const height = (entry: AcpmuxRow) => layoutConversation([entry], 720).heights[0]!;
const markup = (entry: AcpmuxRow) => renderToStaticMarkup(<ToolRows row={entry} />);
const closedLines = (entry: AcpmuxRow) =>
  (
    markup(entry).match(
      /aria-expanded="false"[^>]*data-tool-(group|run)|data-tool-(group|run)[^>]*aria-expanded="false"/g,
    ) ?? []
  ).length;

test("the run the agent works in keeps its lines when its second call finishes, mid-turn", () => {
  const before = run(turn(1, "in_progress"));
  const after = run(turn(2, "completed"));
  // Never shorter: the lines the reader was reading stay, the finished call joins them.
  expect(height(after)).toBeGreaterThanOrEqual(height(before));
  expect(after.runOpen).toBe(true);
  expect(closedLines(after)).toBe(0);
  expect(markup(after)).toContain("There&#x27;s no restart subcommand");
});

test("the agent's next paragraph closes the run, as before", () => {
  const closed = run(turn(3, "completed", true));
  expect(closed.runOpen).toBeUndefined();
  expect(closedLines(closed)).toBe(1);
});

test("`now` is the old look: the run closes as its second call finishes", () => {
  const after = withArm("now", () => run(turn(4, "completed")));
  expect(after.runOpen).toBeUndefined();
  expect(closedLines(after)).toBe(1);
});

test("`turn-end` keeps an earlier run open too, until the turn ends", () => {
  const earlier = withArm("turn-end", () =>
    run([...turn(5, "completed", true), row("next", "activity", { items: [command("broker stop")] })]),
  );
  expect(earlier.runOpen).toBe(true);
  expect(closedLines(earlier)).toBe(0);
});
