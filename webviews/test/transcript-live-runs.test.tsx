// Codex-style tool runs while a turn runs (cx-ncc.108, behind the Debug toggle
// agentPane.debug.codexToolRuns): the Codex desktop app never lets a running turn's tool calls pile
// up as a list. The run in flight is one line that names the newest call and replaces itself as
// calls go by; once text follows a run, that run settles into one summary line ("Read files"),
// which opens to its calls. Off (the default), every call keeps its row.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, kind: string, status = "completed") => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind, status },
});
const run = (id: string, calls: ReturnType<typeof call>[]) => row(id, "activity", { items: calls });
const text = (id: string) => row(id, "assistant", { text: id });

// A running turn: a plan, two reads and a listing, a sentence, then two commands, the second still
// running.
const live = [
  row("u", "user"),
  text("plan"),
  run("reads", [call("README.md", "read"), call("retry.py", "read"), call("ls src", "execute")]),
  text("between"),
  run("commands", [call("git log", "execute"), call("wc -l retry.py", "execute", "in_progress")]),
];

/// The text each drawn activity row shows, by row id.
function drawnRuns(liveRuns: boolean): Record<string, string> {
  const shaped = turnView(live, new Set(), { working: true, liveRuns });
  return Object.fromEntries(
    shaped
      .filter((entry) => entry.kind === "activity")
      .map((entry) => [entry.id, renderToStaticMarkup(<ToolRows row={entry} />).replace(/<[^>]+>/g, " ")]),
  );
}

test("with live runs on, a run that text followed reads as one summary line", () => {
  const reads = drawnRuns(true).reads!;
  expect(reads).toContain("Read files, ran a command");
  expect(reads).not.toContain("README.md");
  expect(reads).not.toContain("ls src");
});

test("with live runs on, the run in flight is one line naming its newest call", () => {
  const commands = drawnRuns(true).commands!;
  expect(commands).toContain("wc -l retry.py");
  expect(commands).not.toContain("git log");
});

test("with live runs off, a running turn lists every call", () => {
  const runs = drawnRuns(false);
  expect(runs.reads).toContain("ls src");
  expect(runs.commands).toContain("git log");
  expect(runs.commands).toContain("wc -l retry.py");
});

test("a pending harness prompt keeps one thinking line in place", () => {
  const pending = row("pending", "user", {
    text: "Start this chat",
    pending: true,
    status: "Starting Claude Code…",
    queued: "pending-prompt",
  });
  const starting = turnView([pending], new Set(), { now: pending.at });
  const startThinking = starting.filter((entry) => entry.kind === "thinking");

  expect(starting.map((entry) => entry.kind)).toEqual(["user", "thinking"]);
  expect(startThinking).toHaveLength(1);
  expect(startThinking[0]).toMatchObject({
    id: "thinking-live",
    version: 0,
    status: "Starting Claude Code…",
    queued: "pending-prompt",
  });
  expect(starting.filter((entry) => entry.status !== undefined)).toHaveLength(1);

  const ready = turnView([{ ...pending, status: undefined }], new Set(), { now: pending.at });
  const readyThinking = ready.filter((entry) => entry.kind === "thinking");

  expect(ready).toHaveLength(2);
  expect(readyThinking).toHaveLength(1);
  expect(readyThinking[0]).toMatchObject({ id: "thinking-live", version: 1 });
  expect(readyThinking[0]?.status).toBeUndefined();
  expect(ready.filter((entry) => entry.status !== undefined)).toHaveLength(0);
});
