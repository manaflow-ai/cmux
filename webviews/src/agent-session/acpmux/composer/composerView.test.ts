import { expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { queuePauseReason } from "../queuePause";
import { composerRows, composerView, sameComposerView } from "./composerView";

const row = (id: string, kind: AcpmuxRow["kind"], extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind, ...extra }) as AcpmuxRow;

const start = row("start", "sessionStart");
const prompt = row("p1", "user", { text: "fix the build" });
const reply = row("a1", "assistant", { text: "on it" });
const tool = row("t1", "tool");
const failed = row("s1", "turnSummary", { status: "failed", error: "rate limited" } as Partial<AcpmuxRow>);
const queued = row("q1", "user", { text: "next", queued: {} } as Partial<AcpmuxRow>);

test("the composer's rows keep what it reads: prompts, queued, failed turns, the first and the first started", () => {
  const rows = [start, prompt, reply, tool, failed, queued];
  const kept = composerRows(rows);
  expect(kept.map((r) => r.id)).toEqual(["start", "p1", "s1", "q1"]);
  // What the composer asks of its rows reads the same from either.
  expect(kept.length === 0).toBe(rows.length === 0);
  expect(kept.some((r) => r.kind !== "sessionStart")).toBe(rows.some((r) => r.kind !== "sessionStart"));
  expect(queuePauseReason(kept)).toBe(queuePauseReason(rows));
  expect(kept.some((r) => r.queued !== undefined)).toBe(true);
  // A chat whose only rows are past its start keeps its first, so it reads as started.
  expect(composerRows([reply, tool]).map((r) => r.id)).toEqual(["a1"]);
  expect(composerRows([])).toEqual([]);
});

const snapshot = (rows: AcpmuxRow[], connection = "connected", commands = [{ name: "plan" }]): AcpmuxSnapshot =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows,
    connection,
    commands,
    queue: [],
    sessions: [],
  }) as unknown as AcpmuxSnapshot;

test("a tool call's snapshot is the same composer view; a new prompt is not", () => {
  const commands = [{ name: "plan" }];
  const before = composerView(snapshot([start, prompt, reply], "agent_message_chunk", commands));
  // A tool call: a new row, a new rows array, a new commands array with the same commands, and the
  // event's kind as the connection.
  const tool = composerView(snapshot([start, prompt, reply, row("t2", "tool")], "tool_call", [...commands]));
  expect(sameComposerView(before, tool)).toBe(true);
  const next = composerView(snapshot([start, prompt, reply, row("p2", "user", { text: "and test" })]));
  expect(sameComposerView(before, next)).toBe(false);
  // A lost link is still told apart.
  expect(sameComposerView(before, composerView(snapshot([start, prompt, reply], "disconnected", commands)))).toBe(
    false,
  );
});

test("a turn's token counts and subagent progress, and another chat's status, leave a started chat's view the same", () => {
  // The shown chat's entry is the same object in each list, as the client keeps an entry it did not change.
  const shown = { sessionId: "s1", title: "This", status: "running" };
  const sessions = (status: string, title = "Other") =>
    [
      shown,
      {
        sessionId: "s2",
        title,
        status,
        indicator: status === "running" ? "working" : "done",
        updatedAt: status.length,
      },
    ] as AcpmuxSnapshot["sessions"];
  const commands = [{ name: "plan" }];
  const at = (extra: Partial<AcpmuxSnapshot>) =>
    composerView({
      ...snapshot([start, prompt, reply], "connected", commands),
      sessionId: "s1",
      sessions: sessions("idle"),
      ...extra,
    });
  const before = at({});
  // The turn's live fields are not in the view at all.
  const step = at({ turnTokens: 1200, subagentStructureVersion: 3, subagentProgress: {} } as Partial<AcpmuxSnapshot>);
  expect("turnTokens" in step).toBe(false);
  expect(sameComposerView(before, step)).toBe(true);
  // Another chat starting to run changes only its live fields.
  expect(sameComposerView(before, at({ sessions: sessions("running") }))).toBe(true);
  // Its title is shown in the @ menu: a change draws the composer again.
  expect(sameComposerView(before, at({ sessions: sessions("idle", "Renamed") }))).toBe(false);
  // The shown chat's own entry is compared whole.
  const own = sessions("idle");
  own[0] = { ...own[0]!, status: "idle" };
  expect(sameComposerView(before, at({ sessions: own }))).toBe(false);
  // A new chat (no rows yet) reads the other chats' recency for its folder strip and suggestion.
  const fresh = (status: string) =>
    composerView({ ...snapshot([], "connected", commands), sessions: sessions(status) } as AcpmuxSnapshot);
  expect(sameComposerView(fresh("idle"), fresh("running"))).toBe(false);
});
