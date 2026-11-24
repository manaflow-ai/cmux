// l10n-allow-file: test fixture replies, not shipped UI.
// A finished subagent's view ends on a turn's footer, whose Copy copies what it did (subagentRows.ts
// `subagentFooter`). Leo, 2026-11-06: "This is a subagent. I should be able to, like, copy the stuff
// that it did."
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { turnCopyText } from "../conversation/turnCopy";
import { TurnFooter } from "../conversation/TurnRows";
import { translate } from "../i18n";
import { SubagentFold } from "./subagentFold";
import { childView, subagentFooter } from "./subagentRows";
import { WholeReportBody } from "./WholeReportBody";

let seq = 0;
function feed(fold: SubagentFold, update: any, acpmux: Record<string, unknown> = {}) {
  seq += 1;
  const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
  return fold.reduce({ seq, at: seq * 1000, msg }, update);
}
const say = (text: string, messageId: string) => ({
  sessionUpdate: "agent_message_chunk",
  messageId,
  content: { type: "text", text },
});

function helperRun() {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "helper", parent: null, name: "Assess" }] });
  feed(fold, say("Reading the sample.", "first"), { subagent: "helper" });
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "read", title: "Read sample.ts", kind: "read", status: "in_progress" },
    { subagent: "helper" },
  );
  feed(fold, { sessionUpdate: "tool_call_update", toolCallId: "read", status: "completed" }, { subagent: "helper" });
  feed(fold, say("Neither blocks the five problems.", "last"), { subagent: "helper" });
  return fold;
}
const view = (fold: SubagentFold) => childView("helper", fold.takeRows(), fold.views(), new Set<string>(), "Chat")!;

test("a finished subagent's view ends on a footer whose Copy copies its replies and tool lines", () => {
  const fold = helperRun();
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "helper", state: "completed" }] });
  const rows = view(fold);
  const footer = rows.at(-1)!;
  expect(footer.kind).toBe("turnSummary");
  expect(footer.id).toBe("helper:end");
  expect(footer.seq).toBeUndefined();
  const copied = turnCopyText((key, values) => translate(key, values, "en"), footer.turnCopy!);
  expect(copied).toContain("Reading the sample.");
  expect(copied).toContain("Neither blocks the five problems.");
  expect(copied.indexOf("Reading the sample.")).toBeLessThan(copied.indexOf("Neither blocks"));
  expect(renderToStaticMarkup(<TurnFooter row={footer} />)).toContain('aria-label="Copy"');
});

test("a running subagent's view draws no footer yet", () => {
  const rows = view(helperRun());
  expect(rows.some((row) => row.kind === "turnSummary")).toBe(false);
});

test("a finished subagent that said nothing draws no footer", () => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "helper", parent: null, name: "Quiet" }] });
  feed(
    fold,
    { sessionUpdate: "tool_call", toolCallId: "read", title: "Read sample.ts", kind: "read", status: "completed" },
    { subagent: "helper" },
  );
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "helper", state: "completed" }] });
  expect(view(fold).some((row) => row.kind === "turnSummary")).toBe(false);
});

const report = (text: string, cut: boolean) => ({ text, cut, loading: false, away: false, more: () => {} });

test("a subagent's whole report card has the corner Copy; a cut one has none", () => {
  const whole = renderToStaticMarkup(<WholeReportBody report={report("All five checked.", false)} className="x" />);
  expect(whole).toContain("cv-card-copy");
  const cut = renderToStaticMarkup(<WholeReportBody report={report("All five", true)} className="x" />);
  expect(cut).not.toContain("cv-card-copy");
});

test("a subagent still waiting on its own background work draws no footer until its report", () => {
  const fold = helperRun();
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "helper", state: "completed" }] });
  const rows = fold.views().helper!;
  const agent = fold.all().find((each) => each.id === "helper")!;
  expect(subagentFooter(agent, rows)).toBeDefined();
  const waiting = { ...agent, reaction: { turn: "t", weight: "result" as const, interim: true as const } };
  expect(subagentFooter(waiting, rows)).toBeUndefined();
});

test("a whole report's corner Copy sits inside its Markdown box, where the float holds the corner", () => {
  const markup = renderToStaticMarkup(<WholeReportBody report={report("All five checked.", false)} className="x" />);
  expect(markup).toMatch(/^<div[^>]*class="cv-whole-report x"[^>]*><span class="cv-card-copy"/);
});
