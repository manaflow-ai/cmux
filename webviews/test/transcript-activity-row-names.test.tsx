// l10n-allow-file: test fixture names and replies, not shipped UI.
// Activity rows name what they are about, and keep the one row pitch (Leo, 2026-11-03, on a capture
// where a finished subagent row read the generic "Subagent", a "Sent to" row showed a bare session
// id and the gaps were uneven):
//   - a finished sub-session's line reads its chat's title when its record names nothing;
//   - a message to a sub-session whose chat left the session list names it from its start call;
//   - the chat's reply under a finished subagent's line is counted in the row's estimate.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import {
  SubsessionContext,
  SubsessionStore,
  subagentTaskLabel,
  subsessionName,
} from "../src/agent-session/acpmux/subagents/subsessions";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { SubsessionCallCard } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";
import { subsessionCall } from "../src/agent-session/acpmux/conversation/subsessionCalls";
import { startedNames, StartedNamesContext } from "../src/agent-session/acpmux/conversation/startedNames";

const t = ((key: string) => (key === "tray.kind.subagent" ? "Subagent" : key)) as never;
const CHILD = "optchat-5e2a91c4b7d0-3f";

const subsessionDone = (reply?: string): AcpmuxRow => {
  const agent: Subagent = {
    id: `${CHILD}/start-1`,
    parent: null,
    name: `${CHILD}/start-1`,
    child: CHILD,
    state: "completed",
    startedAt: 1_000,
    endedAt: 61_000,
    ...(reply && { reaction: { turn: "turn-1", weight: "result" as const, text: reply } }),
  } as Subagent;
  return { id: "done-1", version: 1, kind: "subagentDone", at: 61_000, subagents: [agent] } as AcpmuxRow;
};

const store = (entries: Partial<AcpmuxSessionEntry>[]) => {
  const next = new SubsessionStore();
  next.set(entries as AcpmuxSessionEntry[]);
  return { store: next, open: () => undefined };
};

test("a finished sub-session's line prefers its chat's title to the bare Subagent", () => {
  const agent = { id: `${CHILD}/start-1`, name: `${CHILD}/start-1` };
  expect(subagentTaskLabel(t, agent)).toBe("Subagent");
  expect(subagentTaskLabel(t, agent, "Audit the retry banner")).toBe("Audit the retry banner");
  // A task the record gave still comes first.
  expect(subagentTaskLabel(t, { ...agent, task: "Explore the daemon" }, "Audit")).toBe("Explore the daemon");
  expect(subsessionName({ sessionId: CHILD, name: CHILD, title: "Audit" })).toBe("Audit");
  expect(subsessionName({ sessionId: CHILD, name: "perf-audit" })).toBe("perf-audit");
  // An id names nothing.
  expect(subsessionName({ sessionId: CHILD, name: CHILD })).toBeUndefined();
  expect(subsessionName({ sessionId: "x", name: `peer/${CHILD}` })).toBeUndefined();

  const html = renderToStaticMarkup(
    <SubsessionContext.Provider
      value={store([
        { sessionId: CHILD, name: CHILD, title: "Audit the retry banner", startedBy: "parent", status: "idle" },
      ])}
    >
      <SubagentDoneLine row={subsessionDone()} />
    </SubsessionContext.Provider>,
  );
  expect(html).toContain("Audit the retry banner");
  expect(html).not.toMatch(/>Subagent</);
});

const call = (name: string, args: unknown, output: string) =>
  ({
    id: `call-${name}`,
    title: `mcp__cmux-subsessions__${name}`,
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(args),
    output,
  }) as never;

test("a message to a sub-session that left the list names it from its start call, never a bare id", () => {
  const id = "sub-perf-audit-7f3a9c2e41d0";
  const start = call(
    "start_session",
    { prompt: "Own the perf audit", name: "perf-audit" },
    `Started sub-session perf-audit (sessionId ${id}, depth 1).`,
  );
  const send = call("send_message", { sessionId: id, text: "Start with scroll." }, "Sent: it started a turn with it.");
  const rows = [
    { id: "a", version: 1, kind: "activity", at: 1, items: [{ kind: "tool", text: "start", tool: start }] },
    { id: "b", version: 1, kind: "activity", at: 2, items: [{ kind: "tool", text: "send", tool: send }] },
  ] as AcpmuxRow[];
  const first = startedNames(rows);
  expect(first.names.get(id)).toBe("perf-audit");
  // Unchanged rows hand on the same map; a new row without a start keeps it too.
  expect(startedNames(rows, first).names).toBe(first.names);
  expect(startedNames([...rows, { id: "c", version: 1, kind: "assistant", at: 3, text: "ok" }], first).names).toBe(
    first.names,
  );

  const draw = (names: ReadonlyMap<string, string>) =>
    renderToStaticMarkup(
      <StartedNamesContext.Provider value={names}>
        <SubsessionCallCard call={subsessionCall(send)} tool={send} />
      </StartedNamesContext.Provider>,
    );
  const named = draw(first.names);
  expect(named).toContain("perf-audit");
  expect(named).not.toContain("sub-perf…");
  // With no start call in the chat, the short id is all there is.
  expect(draw(new Map())).toContain("sub-perf…");
});

test("the reply under a finished subagent's line is in the row's estimate", () => {
  const height = (row: AcpmuxRow, width = 720) =>
    layoutConversation([row, { id: "next", version: 1, kind: "subagentDone", at: 2, subagents: [] } as never], width)
      .heights[0]!;
  const bare = height(subsessionDone());
  const short = height(subsessionDone("Found one race; fixing it next."));
  const long = height(subsessionDone("The reviewer found one race in the banner's timer. ".repeat(12)), 360);
  // One 20px line under the 22px line, no margin of its own; a long reply wraps onto more lines.
  expect(short - bare).toBe(20);
  expect(long - height(subsessionDone(), 360)).toBeGreaterThan(40);
  expect((long - height(subsessionDone(), 360)) % 20).toBe(0);
});
