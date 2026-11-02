// l10n-allow-file: test fixture prompts, messages and commands, not shipped UI.
// A run of one-line rows that carries messages between agents folds into one line (Leo, 2026-11-01,
// on a turn of "Sent to" rows, a read, another agent's line, a compaction and "Ran a command, read a
// file", each on its own row: "this should be collapsible").
//
// Before: each sent message stayed in sight beside its run's summary lines (toolGroups.ts
// `staysInSight`), and another agent's line and a compaction between two runs split them, so such a
// turn drew a dozen flat rows that no click could fold. After: the run draws one line ("Sent 3
// messages, read a file, ran a command, received a message") and opens to the rows as they drew.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { layoutConversation } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { hiddenRowFolds, turnView } from "../src/agent-session/acpmux/conversation/turns";

const MESSAGE_RUN = "messageRun";
let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const tool = (title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id: `tool-${(n += 1)}`, title, kind, status: "completed", ...fields },
});
const send = (to: string, message: string) =>
  tool("SendMessage", "other", { inputSummary: JSON.stringify({ to, message }) });
const read = (path: string) => tool(`Read ${path}`, "read", { locations: [{ path }] });
const run = (command: string) => tool(command, "execute", { command, output: "ok\n" });
const activity = (items: AcpmuxActivity[], id?: string) =>
  row("activity", { ...(id && { id }), items, toolCount: items.length });
/// Another agent's message that came in while the turn ran (a steer into it).
const received = (name: string, text: string, id: string) =>
  row("user", {
    id,
    text: "",
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  });

/// A finished turn shaped like Leo's screenshot: sends, a read and another send in one run, a
/// subagent's report, a compaction, then a command and a read, two more sends and a read.
function turn(): AcpmuxRow[] {
  return [
    row("user", { id: "prompt", text: "Coordinate the lanes" }),
    activity(
      [
        send("lane-2/coord-dispatcher", "From claude-sr2-coord, for nightly freshness"),
        send("lane-2/cpu-acpmux-index", "From claude-sr2-coord: re-profile"),
        read("/tmp/probe-22.log"),
        send("lane-12/cloud-item-11", "From claude-sr2-coord: probe 22"),
      ],
      "run-1",
    ),
    received("opus-ui-verify", "Merged (3) cmux#30265, the real-shaped fixtures", "report"),
    row("compaction", { id: "compacted", compaction: { state: "completed", preTokens: 369_000, postTokens: 24_000 } }),
    activity(
      [
        run("git log -1"),
        read("/tmp/notes.md"),
        send("lane-2/ask-8a6cb9b118", "answering your ask"),
        send("lane-2/acpmux-owner", "bug for you (acpmux)"),
        read("/tmp/daemon-links.txt"),
        send("lane-2/acpmux-owner", "confirmed on huge-blue"),
      ],
      "run-2",
    ),
    row("assistant", { id: "answer", text: "All lanes have their orders; the acpmux bug is with its owner." }),
    row("turnSummary", { id: "summary", status: "completed", durationMs: 90_000, toolCount: 10 }),
  ];
}

const claude = { liveRuns: true, agentFamily: "claude" } as const;
const ids = (rows: readonly AcpmuxRow[]) => rows.map((row) => row.id);

test("a finished Claude turn's run of sends, another agent's line and a compaction folds into one line", () => {
  const view = turnView(turn(), new Set(), claude);
  const lines = view.filter((row) => row.kind === MESSAGE_RUN);
  expect(lines).toHaveLength(1);
  // The agent message and the subagent's report join the run instead of breaking it, and so does
  // the compaction between them: none of the run's rows draws while its line is closed.
  for (const member of ["run-1", "report", "compacted", "run-2"]) expect(ids(view)).not.toContain(member);
  expect(lines[0]!.messageRun?.rows).toEqual(expect.arrayContaining(["run-1", "report", "compacted", "run-2"]));
  // The prompt, the line, then the answer and the footer: the answer stays last.
  expect(view.map((row) => row.kind).filter((kind) => kind !== "date")).toEqual([
    "user",
    MESSAGE_RUN,
    "assistant",
    "turnSummary",
  ]);
});

test("the line opens on click to the rows exactly as they drew before", () => {
  const closed = turnView(turn(), new Set(), claude);
  const line = closed.find((row) => row.kind === MESSAGE_RUN)!;
  const open = turnView(turn(), new Set([line.id]), claude);
  const at = open.findIndex((row) => row.id === line.id);
  expect(open[at]!.foldOpen).toBe(true);
  expect(ids(open.slice(at + 1, at + 5))).toEqual(["run-1", "report", "compacted", "run-2"]);
  // The open line's version differs from the closed one's, so the memoized row draws again.
  expect(open[at]!.version).not.toBe(line.version);
});

test("the line counts what the run did, messages first", async () => {
  const { messageRunSummary } = await import("../src/agent-session/acpmux/conversation/messageRuns");
  const line = turnView(turn(), new Set(), claude).find((row) => row.kind === MESSAGE_RUN)!;
  expect(messageRunSummary(translate, line.messageRun!)).toBe(
    "Sent 6 messages, read 3 files, ran a command, received a message",
  );
});

test("a running turn folds its run of messages the same way, under the live line", () => {
  const rows = turn().filter((row) => row.kind !== "assistant" && row.kind !== "turnSummary");
  const view = turnView(rows, new Set(), { ...claude, working: true, lineBelow: true });
  expect(view.filter((row) => row.kind === MESSAGE_RUN)).toHaveLength(1);
  expect(ids(view)).not.toContain("report");
});

test("a Codex turn's open Worked for folds its run of messages too", () => {
  const view = turnView(turn(), new Set(["worked-prompt"]), { liveRuns: true, agentFamily: "codex" });
  expect(view.filter((row) => row.kind === MESSAGE_RUN)).toHaveLength(1);
});

test("a run with no message, and a lone send, keep drawing as before", () => {
  const plain = [
    row("user", { id: "p2", text: "Look around" }),
    activity([run("ls"), read("/tmp/a")], "plain"),
    row("assistant", { text: "Done." }),
    row("turnSummary", { status: "completed" }),
  ];
  expect(turnView(plain, new Set(), claude).some((row) => row.kind === MESSAGE_RUN)).toBe(false);
  const lone = [
    row("user", { id: "p3", text: "Tell lane-a" }),
    activity([send("lane-a", "rebase")], "lone"),
    row("assistant", { text: "Sent." }),
    row("turnSummary", { status: "completed" }),
  ];
  expect(ids(turnView(lone, new Set(), claude))).toContain("lone");
});

test("the closed line is estimated as one line, so its mount moves nothing below it", () => {
  const view = turnView(turn(), new Set(), claude);
  const at = view.findIndex((row) => row.kind === MESSAGE_RUN);
  const heights = [...layoutConversation(view as never, 720).heights];
  // The frame of a one-call tool run's line (model.ts lineRow), in the same place.
  const oneCall = [...view.slice(0, at), activity([read("/tmp/one")]), ...view.slice(at + 1)];
  const line = [...layoutConversation(oneCall as never, 720).heights][at];
  expect(heights[at]).toBe(line!);
});

// Review of cmux#31398 at d0f89fda: in a Codex turn whose "Worked for" is closed, the run's line is
// not drawn yet, so Find and links must open the turn's fold and the run inside it together.
test("Find and a link open a closed Worked for and the message run inside it at once", () => {
  const rows = turn();
  const codex = { liveRuns: true, agentFamily: "codex" } as const;
  const closed = turnView(rows, new Set(), codex);
  expect(ids(closed)).not.toContain("report");
  const folds = hiddenRowFolds(
    rows,
    closed,
    rows.findIndex((row) => row.id === "report"),
  );
  expect(folds[0]).toBe("worked-prompt");
  const opened = turnView(rows, new Set(folds), codex);
  expect(ids(opened)).toContain("report");
  // The line opened by the row's key closes on a click by that same key.
  const line = opened.find((row) => row.kind === MESSAGE_RUN)!;
  expect(line.foldOpen).toBe(true);
  expect(folds).toContain(line.id);
});

test("a run whose edit waits for its permission stays in sight, not under the line", () => {
  const rows = turn();
  rows.splice(
    3,
    0,
    activity(
      [
        tool("Edit notes.md", "edit", { status: "pending", locations: [{ path: "/tmp/notes.md" }] }),
        send("lane-9", "hold on"),
      ],
      "asks",
    ),
  );
  const view = turnView(rows, new Set(), claude);
  expect(ids(view)).toContain("asks");
});
