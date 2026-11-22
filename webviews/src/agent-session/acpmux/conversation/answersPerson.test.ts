// l10n-allow-file: test fixture replies, not shipped UI.
// An agent's lone "." still draws when it answers the person's own prompt (Leo, 2026-11-03, on
// hiding punctuation-only replies: "well there are cases (rare) that you would want to see it...").
// The "." it answers another agent's message with, or ends a background turn with, draws nothing.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView } from "./turns";
import { isVisiblyEmptyMessage } from "./visibleMessage";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const summary = (id: string) => row(id, "turnSummary", { status: "completed", durationMs: 2_000 });
const drawn = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set())
    .filter((entry) => entry.kind !== "date" && !isVisiblyEmptyMessage(entry))
    .map((entry) => entry.id);
const received = (id: string, text: string) =>
  row(id, "user", { text, incoming: { kind: "message", message: { name: "lane", text, raw: text } } });

test("a punctuation-only reply to the person's prompt draws", () => {
  for (const text of ["…", "?", ".", " .\n", "!"]) {
    at = 0;
    const rows = [row("prompt", "user", { text: "Anything left?" }), row("reply", "assistant", { text }), summary("s")];
    expect(drawn(rows)).toContain("reply");
  }
});

test("a blank reply to the person's prompt still draws nothing", () => {
  at = 0;
  const rows = [row("prompt", "user", { text: "Go" }), row("reply", "assistant", { text: "  \n" }), summary("s")];
  expect(drawn(rows)).not.toContain("reply");
});

test("a '.' answering another agent's message draws nothing", () => {
  at = 0;
  const rows = [received("msg", "Green at 4f2a91c."), row("reply", "assistant", { text: "." }), summary("s")];
  expect(drawn(rows)).not.toContain("reply");
});

test("a '.' after another agent's message steered into the person's turn draws nothing", () => {
  at = 0;
  const steer = { ...received("msg", "Green."), steer: "landed" as const };
  const rows = [
    row("prompt", "user", { text: "Run the suites" }),
    row("reply", "assistant", { text: "Running." }),
    steer,
    row("dot", "assistant", { text: "." }),
    summary("s"),
  ];
  const ids = drawn(rows);
  expect(ids).toContain("reply");
  expect(ids).not.toContain("dot");
});

test("the '.' ending a background turn after the person's turn draws nothing", () => {
  at = 0;
  const line = row(backgroundTurnRowId("a"), BACKGROUND_TURN, {
    background: { id: "a", trigger: "task_notification", running: false, quiet: true },
  });
  const rows = [
    row("prompt", "user", { text: "Run the suites in the background" }),
    row("reply", "assistant", { text: "Started them." }),
    summary("s"),
    line,
    row("dot", "assistant", { text: "." }),
  ];
  expect(drawn(rows)).not.toContain("dot");
});
