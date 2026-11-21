// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A running turn is one live status line that replaces itself, as chatgpt.com draws it (read
// 2026-11-10/11: while a turn runs, one line under the prompt says what it does now; its earlier
// steps never stack up as rows). The user, 2026-11-10: "it says 'worked for 36s' but if i hide it,
// it still shows a bunch of tool calls ... we need to match and be the same." What the agent says to
// the person stays in sight (Leo, 2026-11-06: an intermediate message "can never" get lost), and so
// does a file change waiting for the person's permission. This file covers the `line` arm of
// liveTurnWork.experiment.ts and pins it; the shipped `runs` arm keeps each finished run in sight as
// its folded line (transcript-live-runs.test.tsx).
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (id: string, status = "completed", extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id, startedAt: at, ...extra },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
const live = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true });
const kinds = (rows: AcpmuxRow[]) => rows.map((entry) => entry.kind).filter((kind) => kind !== "date");

const armsBefore = globalThis.cmuxExperiments;
// The clock on the live line: "Working for" over the work (liveTurnClock.experiment.ts `top`) with
// this arm is transcript-live-turn-clock.test.ts.
const clockOnLine = { "live-turn-clock": "line" };
beforeEach(() => {
  globalThis.cmuxExperiments = { ...armsBefore, ...clockOnLine, "live-turn-work": "line" };
});
afterEach(() => {
  if (armsBefore === undefined) delete globalThis.cmuxExperiments;
  else globalThis.cmuxExperiments = armsBefore;
});

test("a running turn draws no finished run: the prompt, then one live line naming the call in flight", () => {
  const shaped = live([
    row("u", "user", { text: "Fix the flaky test" }),
    row("run", "activity", { items: [call("rg retry"), call("git log"), call("bun test src/net", "in_progress")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", THINKING]);
  expect(shaped.at(-1)).toMatchObject({ id: "thinking-live", doing: "bun test src/net" });
});

test("a finished thought and finished calls leave no row while the turn thinks", () => {
  const shaped = live([
    row("u", "user", { text: "Fix the flaky test" }),
    row("run", "activity", { items: [call("rg retry"), thought("The backoff is scheduled twice.")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", THINKING]);
  expect(shaped.filter((entry) => entry.kind === "activity")).toHaveLength(0);
});

test("replies to the person stay in sight between runs; the runs around them do not", () => {
  const shaped = live([
    row("u", "user", { text: "Fix the flaky test" }),
    row("run1", "activity", { items: [call("rg retry"), call("git log")] }),
    row("a1", "assistant", { text: "The backoff is scheduled twice. I'm moving it into one place." }),
    row("run2", "activity", { items: [call("bun test src/net"), call("git diff", "in_progress")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", "assistant", THINKING]);
  expect(shaped.find((entry) => entry.id === "a1")?.text).toContain("scheduled twice");
});

test("the line replaces itself in place: one line, one id, at every step", () => {
  const user = row("u", "user", { text: "Fix the flaky test" });
  const steps = [
    [user],
    [user, row("run", "activity", { items: [call("rg retry", "in_progress")] })],
    [user, row("run", "activity", { items: [call("rg retry"), thought("Now the tests")] })],
    [user, row("run", "activity", { items: [call("rg retry"), call("bun test", "in_progress")] })],
  ].map(live);
  for (const shaped of steps) {
    expect(shaped.filter((entry) => entry.kind === THINKING)).toHaveLength(1);
    expect(shaped.filter((entry) => entry.kind === "activity")).toHaveLength(0);
    expect(shaped.at(-1)!.id).toBe("thinking-live");
  }
  expect(steps[1]!.at(-1)!.doing).toBe("rg retry");
  expect(steps[3]!.at(-1)!.doing).toBe("bun test");
});

test("a file change waiting for permission stays in sight over the line", () => {
  const shaped = live([
    row("u", "user", { text: "Tighten the retry comment" }),
    row("run", "activity", {
      items: [
        call("Edit install.sh", "pending", {
          kind: "edit",
          command: undefined,
          locations: [{ path: "/home/dev/install.sh" }],
        }),
      ],
    }),
  ]);
  expect(kinds(shaped)).toEqual(["user", "activity", THINKING]);
});

test("a stretch that already ended keeps its run while the chat works, so its end moves nothing", () => {
  const shaped = turnView(
    [
      row("u", "user", { text: "Watch the deploy" }),
      row("a", "assistant", { text: "Watching it." }),
      row("s", "turnSummary", { status: "completed", durationMs: 2_000 }),
      row("woken-run", "activity", { items: [call("ls")] }),
      row("woken", "assistant", { text: "Listed." }),
      row("woken-end", "turnSummary", { status: "completed", durationMs: 2_000, turnId: "woken-turn" }),
      row("later", "activity", { items: [call("git status"), call("bun test", "in_progress")] }),
    ],
    new Set(),
    { working: true, agentFamily: "claude" },
  );
  expect(shaped.some((entry) => entry.id === "woken-run")).toBe(true);
  expect(shaped.some((entry) => entry.id === "later")).toBe(false);
  expect(shaped.at(-1)).toMatchObject({ id: "thinking-live", doing: "bun test" });
});

test("the runs arm keeps every finished run in sight until the turn ends", () => {
  globalThis.cmuxExperiments = { ...armsBefore, ...clockOnLine, "live-turn-work": "runs" };
  const shaped = live([
    row("u", "user", { text: "Fix the flaky test" }),
    row("run", "activity", { items: [call("git log"), call("bun test src/net", "in_progress")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", "activity", THINKING]);
});
