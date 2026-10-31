// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A steered turn's messages to the person never fold (Leo, 2026-10-31: "THE FACT THAT YOUR INTERIM
// MESSAGE YOU SENT BETWEEN STEERS GOT COLLAPSED IS FUCKIGN SHIT"; "I WILL NEVER FUCKING ACCEPT THAT
// EVEN WITH THE FUCKING CODEX-STYLE COLLAPSING"). The delineation is structural (Leo: "i think the
// delineation is between end-of-turn-that-had-a-steer-between vs otherwise that's how we can tell"):
// the agent's last reply before each steer ends a sub-turn and stays drawn like the final answer,
// beside the steer it came before; other replies inside the turn are chatter and fold with the tools.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { subTurnEnds, turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: `Ran ${id}`, tool: { id, title: id, kind: "execute", status: "completed" } }],
  });
const reply = (id: string, text: string) => row(id, "assistant", { text });
const steer = (id: string, text: string) => row(id, "user", { text, steer: "landed", promptId: `${id}-prompt` });
const report = (id: string) =>
  row(id, "user", {
    text: "The delegated tests passed.",
    steer: "landed",
    promptId: `${id}-prompt`,
    incoming: {
      kind: "message",
      message: { name: "test-runner", text: "The delegated tests passed.", raw: "The delegated tests passed." },
    },
  });

/// prompt → tool → status → steer → chatter → tool → status → steer → tool → final.
/// The two statuses end a sub-turn (each is the last reply before a steer); the chatter does not.
const steeredTurn = () => {
  at = 0;
  return [
    row("prompt", "user", { text: "Land the header fix" }),
    tool("read"),
    reply("status-1", "Not merged yet: the webview check is still running."),
    tool("wait-1"),
    steer("steer-1", "also remove the dots"),
    reply("chatter", "Now let me check the dots."),
    tool("grep"),
    reply("status-2", "The dots come from the group colour; a helper is on it."),
    steer("steer-2", "and the tab underline"),
    tool("edit-check"),
    reply("final", "Both are with one helper now."),
    row("summary", "turnSummary", { status: "completed", durationMs: 66_000 }),
  ];
};

const ids = (rows: readonly AcpmuxRow[]) => rows.filter((entry) => entry.kind !== "date").map((entry) => entry.id);

test("the last reply before each steer ends a sub-turn; chatter is not one", () => {
  const body = steeredTurn().slice(1, -1);
  expect([...subTurnEnds(body)].map((entry) => entry.id)).toEqual(["status-1", "status-2"]);
});

// Each collapse mode: the Claude layout (no Codex-style runs) and the Codex-style runs, each with the
// live line over or below the turn. Every one draws the same closed fold of a finished turn.
const modes = [
  { name: "Claude layout", liveRuns: false, lineBelow: false },
  { name: "Claude layout, live line below", liveRuns: false, lineBelow: true },
  { name: "Codex-style runs", liveRuns: true, lineBelow: false },
  { name: "Codex-style runs, live line below", liveRuns: true, lineBelow: true },
];

for (const mode of modes)
  describe(mode.name, () => {
    test("a finished steered turn keeps every sub-turn's last reply and steer in sight; tools and chatter fold", () => {
      const drawn = turnView(steeredTurn(), new Set(), mode);
      expect(ids(drawn)).toEqual([
        "prompt",
        `${WORKED}-prompt`,
        "status-1",
        "steer-1",
        "status-2",
        "steer-2",
        "final",
        "summary",
      ]);
      for (const hidden of ["read", "wait-1", "chatter", "grep", "edit-check"]) expect(ids(drawn)).not.toContain(hidden);
    });

    test("opened, the fold shows every row once, in the order it ran", () => {
      const drawn = ids(turnView(steeredTurn(), new Set([`${WORKED}-prompt`]), mode));
      // The Codex-style runs fold short chatter into the run around it as a quiet note (mergeShortNotes).
      const order = ["status-1", "steer-1", ...(mode.liveRuns ? [] : ["chatter"]), "status-2", "steer-2", "final", "summary"];
      for (const id of order) expect(drawn.filter((entry) => entry === id)).toHaveLength(1);
      expect(order.map((id) => drawn.indexOf(id))).toEqual([...order.map((id) => drawn.indexOf(id))].sort((a, b) => a - b));
    });

    test("a steer, text, tool, text, steer, text turn keeps both texts before a steer and the final one", () => {
      at = 0;
      const rows = [
        row("prompt", "user", { text: "go" }),
        tool("t0"),
        reply("before-1", "Started the build."),
        steer("s1", "faster please"),
        reply("ack", "On it."),
        tool("t1"),
        reply("before-2", "Moved it to the fleet."),
        steer("s2", "thanks"),
        reply("last", "Done."),
        row("summary", "turnSummary", { status: "completed", durationMs: 9_000 }),
      ];
      const drawn = ids(turnView(rows, new Set(), mode));
      for (const id of ["before-1", "s1", "before-2", "s2", "last"]) expect(drawn).toContain(id);
      for (const id of ["t0", "ack", "t1"]) expect(drawn).not.toContain(id);
    });
  });

test("a turn without steers still folds its chatter: only the final answer stays", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "go" }),
    tool("t0"),
    reply("chatter", "Now let me check X."),
    tool("t1"),
    reply("final", "Done."),
    row("summary", "turnSummary", { status: "completed", durationMs: 3_000 }),
  ];
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", `${WORKED}-prompt`, "final", "summary"]);
});

test("a report from another agent is not a steer: the reply before it folds, and so does the report", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "go" }),
    tool("t0"),
    reply("before-report", "Waiting on the test runner."),
    report("report"),
    reply("final", "Tests passed."),
    row("summary", "turnSummary", { status: "completed", durationMs: 3_000 }),
  ];
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", `${WORKED}-prompt`, "final", "summary"]);
});

test("a running turn's Codex-style runs never merge a reply before a steer into a run", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "go" }),
    tool("t0"),
    reply("before", "Started it."),
    tool("t1"),
    steer("s1", "faster"),
    tool("t2"),
  ];
  for (const lineBelow of [false, true]) {
    const drawn = ids(turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow }));
    expect(drawn).toContain("before");
    expect(drawn).toContain("s1");
  }
});
