// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript only appends while a turn runs, and its live zone is always last (Leo, 2026-11-09:
// "i hate the way when i send off a message it seems to move up and under your current running tool
// call or whatever"; "im still seeing compacting not be at the bottom"; "i previously sent the claude
// code one, just look at how they do it"). A prompt sent into a running turn draws after every row
// drawn at the send, and what was still going then (a call in flight, a thought) lands after it, never
// in its run above it; no footer comes in above it while the turn runs; a compaction that runs while
// the person's prompt waits stays the live line, under the prompt.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { findRowIndex, rowHolds } from "../src/agent-session/acpmux/conversation/chatFind";
import {
  AFTER_SEND,
  LIVE_THINKING,
  SUPERSEDED,
  THINKING,
  turnView,
} from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 9, 19, 0, 0);
const at = (second: number) => START + second * 1000;
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: at(second),
  ...extra,
});
type Item = NonNullable<AcpmuxRow["items"]>[number];
const call = (id: string, title: string, kind: string, startedAt: number, endedAt?: number): Item => ({
  kind: "tool",
  text: title,
  tool: {
    id,
    title,
    kind,
    status: endedAt === undefined ? "in_progress" : "completed",
    startedAt: at(startedAt),
    ...(endedAt !== undefined && { endedAt: at(endedAt) }),
  },
});
const prompt = row("u-1", "user", 0, { text: "Find every retry loop" });
const reply = row("a-1", "assistant", 2, { text: "Looking at the relay first." });
const steer = (state: AcpmuxRow["steer"], extra: Partial<AcpmuxRow> = {}) =>
  row("u-2", "user", 10, { text: "Also check the queue", steer: state, ...extra });
const view = (rows: AcpmuxRow[], family = "claude") =>
  turnView(rows, new Set(), { working: true, agentFamily: family, now: at(60) });
const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);
const callIds = (rows: readonly AcpmuxRow[], id: string) =>
  (rows.find((each) => each.id === id)?.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : []));

for (const family of ["claude", "codex"]) {
  test(`${family}: a call that ran when the person sent lands after the prompt, never in its run above it`, () => {
    // The read ran when the person sent at 10 s (Leo's case): while it runs the live line names it,
    // under the prompt.
    const running = view(
      [
        prompt,
        reply,
        row("act-1", "activity", 3, { items: [call("c-1", "Read relay.ts", "read", 3)] }),
        steer("waiting"),
      ],
      family,
    );
    expect(running.at(-1)!.id).toBe(LIVE_THINKING);
    expect(running.at(-1)!.doingCall).toBe("c-1");
    expect(ids(running).indexOf("u-2")).toBe(running.length - 2);
    expect(running.some((each) => callIds([each], each.id).includes("c-1"))).toBe(false);
    // It ends at 12 s: its row comes after the prompt, and nothing above the prompt changed.
    const done = view(
      [
        prompt,
        reply,
        row("act-1", "activity", 3, { items: [call("c-1", "Read relay.ts", "read", 3, 12)] }),
        steer("landed"),
      ],
      family,
    );
    const list = ids(done);
    const after = `act-1${AFTER_SEND}u-2`;
    expect(list.indexOf(after)).toBe(list.indexOf("u-2") + 1);
    expect(callIds(done, after)).toEqual(["c-1"]);
    expect(list.slice(0, list.indexOf("u-2"))).toEqual(ids(running).slice(0, ids(running).indexOf("u-2")));
    expect(done.at(-1)!.kind).toBe(THINKING);
  });

  test(`${family}: a call that ended before the send stays in its run above the prompt`, () => {
    const shaped = view(
      [
        prompt,
        reply,
        row("act-1", "activity", 3, {
          items: [call("c-0", "Read retry.ts", "read", 3, 5), call("c-1", "Read relay.ts", "read", 6, 12)],
        }),
        steer("landed"),
      ],
      family,
    );
    const list = ids(shaped);
    const run = list.find((id) => callIds(shaped, id).includes("c-0"))!;
    expect(list.indexOf(run)).toBeLessThan(list.indexOf("u-2"));
    expect(callIds(shaped, `act-1${AFTER_SEND}u-2`)).toEqual(["c-1"]);
  });

  test(`${family}: no footer comes in above a prompt the person sent while the turn runs`, () => {
    const shaped = view(
      [
        prompt,
        row("act-1", "activity", 1, { items: [call("c-0", "Run tests", "execute", 1, 2)] }),
        reply,
        steer("landed"),
      ],
      family,
    );
    expect(shaped.some((each) => each.id === `${SUPERSEDED}-u-2`)).toBe(false);
  });
}

test("a compaction running when the person sends stays the live line, under the prompt", () => {
  const shaped = view([
    prompt,
    reply,
    row("compaction-9", "compaction", 5, { compaction: { state: "running" } }),
    steer("waiting"),
  ]);
  const line = shaped.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.liveState).toBe("compacting");
  expect(ids(shaped)).not.toContain("compaction-9");
  expect(ids(shaped).indexOf("u-2")).toBe(shaped.length - 2);
});

test("another agent's message after a compaction still ends it as the live line", () => {
  const shaped = view([
    prompt,
    reply,
    row("compaction-9", "compaction", 5, { compaction: { state: "running" } }),
    row("u-3", "user", 8, { text: "report", incoming: { kind: "notice", text: "report" } as AcpmuxRow["incoming"] }),
  ]);
  expect(shaped.at(-1)!.liveState).not.toBe("compacting");
});

// Review of #39825 (F1): the run a call lands in under the prompt keeps naming the row it came from,
// so Find and a count's reveal still reach the call, in whichever part of a split row holds it.
test("Find and a count's reveal reach a call that landed under the prompt", () => {
  // The row's only call ended after the send: the whole row moved under the prompt.
  const whole = view([
    prompt,
    reply,
    row("act-1", "activity", 3, { items: [call("c-1", "Read relay.ts", "read", 3, 12)] }),
    steer("landed"),
  ]);
  const moved = whole.findIndex((each) => each.id === `act-1${AFTER_SEND}u-2`);
  expect(moved).toBeGreaterThan(0);
  expect(findRowIndex(whole, "act-1")).toBe(moved);
  // A row split in two: the call that ended before the send stays above, the one still going moved.
  const split = view([
    prompt,
    reply,
    row("act-1", "activity", 3, {
      items: [call("c-0", "Grep retry", "search", 3, 4), call("c-1", "Read relay.ts", "read", 5, 12)],
    }),
    steer("landed"),
  ]);
  const above = split.findIndex((each) => each.id === "act-1");
  const below = split.findIndex((each) => each.id === `act-1${AFTER_SEND}u-2`);
  expect(above).toBeGreaterThanOrEqual(0);
  expect(below).toBeGreaterThan(above);
  expect(findRowIndex(split, "act-1", rowHolds({ toolId: "c-1" }))).toBe(below);
  expect(findRowIndex(split, "act-1", rowHolds({ toolId: "c-0" }))).toBe(above);
  expect(findRowIndex(split, "act-1", rowHolds({ needle: "relay.ts" }))).toBe(below);
  expect(findRowIndex(split, "act-1", rowHolds({ needle: "grep retry" }))).toBe(above);
});

// Review of #39825 (F2): the run under the prompt changes with any row it took a call from, so a
// background call in a later row that ends redraws it (ToolActivityRow keys on the version).
test("the run under the prompt changes when a call from any of its rows changes", () => {
  const rows = (second: AcpmuxRow) => [
    prompt,
    reply,
    row("act-1", "activity", 3, { items: [call("c-1", "Read relay.ts", "read", 3, 12)] }),
    second,
    steer("landed"),
  ];
  // The later row's call ends after the send; then its result comes in (its row's version moves).
  const first = view(rows(row("act-2", "activity", 4, { version: 1, items: [call("c-2", "Run tests", "execute", 4, 15)] })));
  const failed = { ...call("c-2", "Run tests", "execute", 4, 15) };
  failed.tool = { ...failed.tool!, status: "failed" };
  const next = view(rows(row("act-2", "activity", 4, { version: 2, items: [failed] })));
  const run = (shaped: readonly AcpmuxRow[]) => shaped.find((each) => each.id === `act-1${AFTER_SEND}u-2`);
  expect(callIds([run(first)!], run(first)!.id)).toEqual(["c-1", "c-2"]);
  expect(run(next)!.version).not.toBe(run(first)!.version);
});

// Review of #39825 (F3): the pane's send time and the agent's call times are read on one clock. The
// pane stamps `delivery.sentAt` on this computer's clock; a call's `endedAt` is the events' clock,
// `clockOffset` behind or ahead (events' time + offset = this computer's).
for (const offset of [5 * 60_000, -5 * 60_000]) {
  test(`a call's place against a prompt sent mid-turn holds with the pane's clock ${offset > 0 ? "ahead" : "behind"} by 5 min`, () => {
    // The person sent at 10 s on the events' clock; the pane stamped it on its own.
    const sent = steer("landed", {
      delivery: { state: "read", promptId: "p-2", sessionId: "s-1", sentAt: at(10) + offset },
    });
    const shaped = (endedAt: number) =>
      turnView(
        [prompt, reply, row("act-1", "activity", 3, { items: [call("c-1", "Read relay.ts", "read", 3, endedAt)] }), sent],
        new Set(),
        { working: true, agentFamily: "claude", now: at(60) + offset, clockOffset: offset },
      );
    // Ended 5 s before the send: it stays above the prompt.
    const before = ids(shaped(5));
    expect(before.indexOf("act-1")).toBeLessThan(before.indexOf("u-2"));
    expect(before).not.toContain(`act-1${AFTER_SEND}u-2`);
    // Ended 2 s after it: it lands under the prompt.
    const after = ids(shaped(12));
    expect(after.indexOf(`act-1${AFTER_SEND}u-2`)).toBe(after.indexOf("u-2") + 1);
  });
}
