// l10n-allow-file: test fixture prompts and commands, not shipped UI.
//
// A chat folded ahead (pane/useTurnActions.ts `shapeAhead`) is shaped as it rests, so the live line of
// a turn it still runs was first read on the switch: its running command's words, a shell parse and a
// rule match (~1.3 ms the first time on a page; settled-page bench, chat_switch stream). The shaping
// ahead reads them, so the switch finds them kept (commandActions.ts `runningCommandSaid`).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { runningSaidKept } from "../src/agent-session/acpmux/conversation/commandActions";
import { shapeAhead } from "../src/agent-session/acpmux/pane/useTurnActions";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, command: string, status: string): AcpmuxRow =>
  row(id, "activity", { items: [{ tool: { id: `${id}-tool`, kind: "execute", title: command, command, status } }] } as Partial<AcpmuxRow>);

const ahead = (sessionId: string, rows: AcpmuxRow[]) =>
  shapeAhead(
    { sessionId, rows, family: undefined },
    {
      expanded: new Set(),
      doneLines: new Map(),
      workflowLabsEnabled: false,
      splitSilent: true,
      clockOffset: undefined,
      pastTurns: new Map(),
    },
  );

test("a chat folded ahead mid-command keeps that command's live words for the switch", () => {
  const before = runningSaidKept();
  ahead("running", [
    row("u0", "user", { text: "Check the logs" }),
    call("c0", "tail -n 200 /var/log/warm-ahead-unique.log", "in_progress"),
  ]);
  expect(runningSaidKept()).toBe(before + 1);
});

test("finished commands and earlier turns' commands are not read ahead", () => {
  const before = runningSaidKept();
  ahead("rested", [
    row("u0", "user", { text: "Build it" }),
    call("c0", "make warm-ahead-earlier-turn", "in_progress"),
    row("u1", "user", { text: "Now test" }),
    call("c1", "make warm-ahead-finished", "completed"),
    row("e1", "turnSummary", { status: "completed", durationMs: 4_000 }),
  ]);
  expect(runningSaidKept()).toBe(before);
});
