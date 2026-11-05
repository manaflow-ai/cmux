// l10n-allow-file: test fixture names and reports, not shipped UI.
// A subagent's report to its chat (SubagentReportLine.tsx; Leo, 2026-11-05: "what's up with this
// \"tool call\"?"): the background turn its task notification started names the subagent, sits
// right under its "Subagent finished" line (runningTray.ts `withSubagentLines`), and opens to the
// report as Markdown. Other background turns keep their line.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "../conversation/BackgroundTurnLine";
import { BACKGROUND_TURN, backgroundTurnRowId } from "../conversation/backgroundTurns";
import { withSubagentLines } from "./runningTray";
import { SUBAGENT_DONE } from "./subagentRows";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { SubagentViewsContext } from "./SubagentGroup";

// As Claude's live records name them: acpmux's subagent is `<session>/<tool call>`, the
// notification's origin the bare call.
const agent: Subagent = {
  id: "chat/toolu_fix",
  parent: null,
  name: "general-purpose",
  task: "Fix live working line in transcript",
  state: "completed",
  startedAt: 2_000,
  endedAt: 5_000,
  lastMessage: "I've merged the fix, but it covers **one** cause.",
};
const WHOLE = "I've merged the fix, but it covers **one** cause.\n\n- `liveLine()` falls back to the call";
const view: AcpmuxRow[] = [{ id: "child-reply", kind: "assistant", version: 1, at: 4_900, text: WHOLE }];
const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const turn = (id: string, at: number, origin = "toolu_fix", kind = "subagent"): AcpmuxRow =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, at, {
    background: {
      id,
      trigger: "task_notification",
      running: false,
      quiet: true,
      hasRows: true,
      cause: { kind, status: "completed", weight: "result", origin, summary: "I've merged the fix, but it" },
    },
  });

const transcript = (): AcpmuxRow[] => [
  row("prompt", "user", 1_000, { text: "Fix it with a subagent" }),
  row("group", SUBAGENTS, 1_500, { subagents: [agent] }),
  row("footer", "turnSummary", 1_600, { status: "completed" }),
  row("other", "assistant", 6_000, { text: "Meanwhile, the suite passed." }),
  turn("report", 7_000),
  row("reply", "assistant", 7_100, { text: "Noted.", inBackground: "report" }),
];

test("a subagent's report sits right under its finished line and names it", () => {
  const out = withSubagentLines(transcript());
  expect(out.map((entry) => entry.id)).toEqual([
    "prompt",
    "footer",
    "other",
    `${SUBAGENT_DONE}:chat/toolu_fix`,
    backgroundTurnRowId("report"),
    "reply",
  ]);
  const report = out[4]!;
  expect(report.subagentReport?.id).toBe("chat/toolu_fix");
  const closed = renderToStaticMarkup(<BackgroundTurnLine row={report} expanded={false} onToggle={() => {}} />);
  expect(closed).toContain("Report from");
  expect(closed).toContain("Fix live working line in transcript");
  expect(closed).toContain('aria-expanded="false"');
  expect(closed).not.toContain("I&#x27;ve merged");
  const open = renderToStaticMarkup(<BackgroundTurnLine row={report} expanded onToggle={() => {}} />);
  expect(open).toContain("cv-subagent-report__body");
  expect(open).toContain("<strong>one</strong>");
  // acpmux's `lastMessage` is cut; the subagent's own transcript holds the whole reply.
  expect(open).not.toContain("falls back");
  const whole = renderToStaticMarkup(
    <SubagentViewsContext.Provider value={(id) => (id === "chat/toolu_fix" ? view : undefined)}>
      <BackgroundTurnLine row={report} expanded onToggle={() => {}} />
    </SubagentViewsContext.Provider>,
  );
  expect(whole).toContain("falls back to the call");
});

test("a report delivered again names its subagent too; the finished line stays above the first", () => {
  const rows = [...transcript(), turn("again", 9_000)];
  const out = withSubagentLines(rows);
  const ids = out.map((entry) => entry.id);
  expect(ids.indexOf(backgroundTurnRowId("report"))).toBe(ids.indexOf(`${SUBAGENT_DONE}:chat/toolu_fix`) + 1);
  expect(out.find((entry) => entry.id === backgroundTurnRowId("again"))?.subagentReport?.id).toBe("chat/toolu_fix");
});

test("the line is kept while nothing it says changes", () => {
  const cache = new Map();
  const rows = transcript();
  const first = withSubagentLines(rows, cache).find((entry) => entry.id === backgroundTurnRowId("report"));
  const again = withSubagentLines(rows, cache).find((entry) => entry.id === backgroundTurnRowId("report"));
  expect(again).toBe(first);
});

test("a shell's background turn keeps its own line", () => {
  const shell = turn("shell", 7_000, "toolu_shell", "shell");
  const html = renderToStaticMarkup(<BackgroundTurnLine row={shell} expanded={false} onToggle={() => {}} />);
  expect(html).not.toContain("Report from");
  expect(html).toContain('data-background-turn="quiet"');
});
