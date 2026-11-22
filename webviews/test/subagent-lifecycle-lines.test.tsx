// l10n-allow-file: recorded subagent and transcript fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SubagentFold, SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { withSubagentLines, type DoneLineCache } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_DONE, SUBAGENT_STARTED } from "../src/agent-session/acpmux/subagents/subagentRows";
import { SubagentStartedLine } from "../src/agent-session/acpmux/subagents/SubagentStartedLine";
import { SubagentHarnessContext } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at: 0,
  version: 1,
  ...fields,
});
const prompt = row("prompt", "user", { text: "Review the changes" });
const call = row("tool", "activity", {
  at: 500,
  items: [
    {
      kind: "tool",
      text: "Read source",
      tool: { id: "read", title: "Read source", kind: "read", status: "completed" },
    },
  ],
});
const answer = row("answer", "assistant", {
  at: 5_000,
  text: "Both reviewers finished.",
  assistantPhase: "final_answer",
});
const summary = row("summary", "turnSummary", { at: 6_000, status: "completed", durationMs: 6_000, toolCount: 1 });

function recorded(harness: string) {
  const fold = new SubagentFold();
  const groups = new Map<string, AcpmuxRow>();
  const events: { seq: number; at: number; msg: Record<string, unknown> }[] = [];
  const feed = (sessionUpdate: string, subagents: Record<string, unknown>[]) => {
    const seq = events.length + 1;
    const update = { sessionUpdate };
    const event = {
      seq,
      at: seq * 1_000,
      msg: { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } },
    };
    events.push(event);
    fold.reduce(event, update);
    for (const group of fold.takeRows()) groups.set(group.id, group);
  };
  feed("subagent_spawned", [
    { id: "review-a", parent: null, name: "Review A", task: "Dummy task one", state: "running", harness },
    { id: "review-b", parent: null, name: "Review B", task: "Dummy task two", state: "running", harness },
  ]);
  return { fold, groups, events, feed };
}

for (const harness of ["claude-opus-5-5", "codex"])
  test(`${harness}: actual metadata groups keep one batched start and both finishes through live completion and replay`, () => {
    const record = recorded(harness);
    const cache: DoneLineCache = new Map();
    const live = withSubagentLines([prompt, call, ...record.groups.values()], cache);
    const started = live.find((entry) => entry.kind === SUBAGENT_STARTED)!;
    expect(started.subagents?.map((agent) => agent.id)).toEqual(["review-a", "review-b"]);
    expect(live.some((entry) => entry.kind === SUBAGENT_DONE)).toBe(false);
    expect(live).toContain(call);
    record.feed("subagent_state_update", [{ id: "review-a", state: "completed" }]);
    record.feed("subagent_state_update", [{ id: "review-b", state: "completed" }]);
    const raw = [prompt, call, ...record.groups.values(), answer, summary];
    const completed = withSubagentLines(raw, cache);
    expect(completed.find((entry) => entry.kind === SUBAGENT_STARTED)).toBe(started);
    expect(completed.filter((entry) => entry.kind === SUBAGENT_DONE)).toHaveLength(2);
    expect(raw.some((entry) => entry.kind === SUBAGENTS)).toBe(true);
    const closed = turnView(completed, new Set(), { agentFamily: harness, now: 10_000 });
    const opened = turnView(completed, new Set([`${WORKED}-${prompt.id}`]), { agentFamily: harness, now: 10_000 });
    for (const view of [closed, opened]) {
      expect(view.filter((entry) => entry.kind === SUBAGENT_STARTED)).toHaveLength(1);
      expect(view.filter((entry) => entry.kind === SUBAGENT_DONE)).toHaveLength(2);
    }
    expect(closed.some((entry) => entry.id === call.id)).toBe(false);
    expect(opened.some((entry) => entry.id === call.id)).toBe(true);
    const replay = new SubagentFold();
    const replayGroups = new Map<string, AcpmuxRow>();
    for (const event of record.events) {
      const update = (event.msg.params as { update: Record<string, unknown> }).update;
      replay.reduce(event, update);
      replay.reduce(event, update);
      for (const group of replay.takeRows()) replayGroups.set(group.id, group);
    }
    const replayed = withSubagentLines([prompt, call, ...replayGroups.values(), answer, summary]);
    expect(replayed.map((entry) => entry.id)).toEqual(completed.map((entry) => entry.id));
    expect(withSubagentLines(replayed)).toBe(replayed);
    const geometry = layoutConversation(closed, 760);
    for (const entry of closed.filter((entry) => entry.kind === SUBAGENT_STARTED || entry.kind === SUBAGENT_DONE))
      expect(geometry.heights[closed.indexOf(entry)]).toBe(22);
  });

test("queued placeholders and missing identities do not announce work", () => {
  const record = recorded("claude");
  const group = [...record.groups.values()][0]!;
  const agents = group.subagents!;
  const pending = {
    ...group,
    subagents: [
      { ...agents[0]!, state: "queued" },
      { ...agents[1]!, id: "" },
    ],
  };
  expect(withSubagentLines([prompt, pending]).some((entry) => entry.kind === SUBAGENT_STARTED)).toBe(false);
});

test("an actual same-ID resume keeps the original start and replaces its current finish", () => {
  const record = recorded("claude");
  record.feed("subagent_state_update", [
    { id: "review-a", state: "completed" },
    { id: "review-b", state: "completed" },
  ]);
  const cache: DoneLineCache = new Map();
  const first = withSubagentLines([prompt, ...record.groups.values()], cache);
  const started = first.find((entry) => entry.kind === SUBAGENT_STARTED);
  record.feed("subagent_state_update", [{ id: "review-a", state: "running" }]);
  const running = withSubagentLines([prompt, ...record.groups.values()], cache);
  expect(running.find((entry) => entry.kind === SUBAGENT_STARTED)).toBe(started);
  expect(running.filter((entry) => entry.kind === SUBAGENT_DONE).map((entry) => entry.subagents?.[0]?.id)).toEqual([
    "review-b",
  ]);
  record.feed("subagent_state_update", [{ id: "review-a", state: "completed" }]);
  const resumed = withSubagentLines([prompt, ...record.groups.values()], cache);
  expect(resumed.filter((entry) => entry.kind === SUBAGENT_STARTED)).toHaveLength(1);
  expect(resumed.find((entry) => entry.id === `${SUBAGENT_DONE}:review-a`)?.at).toBe(4_000);
  expect(new Set(resumed.map((entry) => entry.id)).size).toBe(resumed.length);
});

test("the batched start names both agents with their own marks and no disclosure", () => {
  const record = recorded("claude-opus-5-5");
  const started = withSubagentLines([...record.groups.values()])[0]!;
  const html = renderToStaticMarkup(
    <SubagentHarnessContext.Provider value="claude">
      <SubagentStartedLine row={started} />
    </SubagentHarnessContext.Provider>,
  );
  expect(html).toContain("Dummy task one");
  expect(html).toContain("Dummy task two");
  expect(html).toContain("started working");
  expect(html.match(/data-agent-tone=/g)).toHaveLength(2);
  expect(html).not.toContain("cv-agent-activity__chevron");
});

// Leo, 2026-11-22, on a start line whose chips shrank as more agents joined it: "there's like a
// secondary animation that shifts as it recalculates to shrink stuff ... with better designs this
// won't happen". A line names the agents one record started; it is never rewritten for a later one.
test("an agent the group starts later gets its own start line under the rows before it", () => {
  const record = recorded("claude");
  const cache: DoneLineCache = new Map();
  const group = () => [...record.groups.values()];
  const starts = (rows: readonly AcpmuxRow[]) => rows.filter((entry) => entry.kind === SUBAGENT_STARTED);
  const [first] = starts(withSubagentLines([prompt, ...group()], cache));
  expect(first!.subagents?.map((agent) => agent.id)).toEqual(["review-a", "review-b"]);
  // The chat ran a tool, then started a third agent (the fold's events are a second apart).
  const tool = { ...call, at: 1_500 };
  record.feed("subagent_spawned", [
    { id: "review-c", parent: null, name: "Review C", task: "Dummy task three", state: "running" },
  ]);
  expect(group()).toHaveLength(1);
  const later = { ...answer, at: 9_000 };
  const out = withSubagentLines([prompt, ...group(), tool, later], cache);
  expect(out.map((entry) => entry.kind)).toEqual(["user", SUBAGENT_STARTED, "activity", SUBAGENT_STARTED, "assistant"]);
  const [kept, joined] = starts(out);
  // The first line is the same row: nothing in it is drawn again.
  expect(kept).toBe(first!);
  expect(joined!.subagents?.map((agent) => agent.id)).toEqual(["review-c"]);
  expect(joined!.id).not.toBe(kept!.id);
  expect(renderToStaticMarkup(<SubagentStartedLine row={joined!} />)).toContain("Dummy task three");
  // A fourth agent leaves both lines as they are and adds its own at the end.
  record.feed("subagent_spawned", [
    { id: "review-d", parent: null, name: "Review D", task: "Dummy task four", state: "running" },
  ]);
  const again = starts(withSubagentLines([prompt, ...group(), tool, later], cache));
  expect(again).toHaveLength(3);
  expect(again[0]).toBe(kept!);
  expect(again[1]).toBe(joined!);
  // Read again with nothing new, every row is the same object.
  const settled = withSubagentLines([prompt, ...group(), tool, later], cache);
  expect(starts(settled)).toEqual(again);
  starts(settled).forEach((entry, index) => expect(entry).toBe(again[index]!));
});

test("late kind and prompt metadata update a cached start label", () => {
  const record = recorded("claude");
  record.feed("subagent_spawned", [
    { id: "chat/toolu_review", name: "chat/toolu_alias", parent: null, state: "running" },
  ]);
  const cache: DoneLineCache = new Map();
  // The agent started after the group's first two, so it has a start line of its own.
  const read = () =>
    withSubagentLines([...record.groups.values()], cache).find(
      (entry) => entry.kind === SUBAGENT_STARTED && entry.subagents?.some((agent) => agent.id === "chat/toolu_review"),
    )!;
  const first = read();
  expect(first.subagents).toHaveLength(1);
  record.feed("subagent_state_update", [{ id: "chat/toolu_review", kind: "Explore" }]);
  const second = read();
  expect(second).not.toBe(first);
  expect(renderToStaticMarkup(<SubagentStartedLine row={second} />)).toContain("Explore");
  record.feed("subagent_state_update", [{ id: "chat/toolu_review", prompt: "Inspect the source\nReport findings" }]);
  const third = read();
  expect(third).not.toBe(second);
  expect(renderToStaticMarkup(<SubagentStartedLine row={third} />)).toContain("Inspect the source");
});
