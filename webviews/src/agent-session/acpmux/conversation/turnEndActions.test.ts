// l10n-allow-file: test fixture text, not shipped UI.
// Every turn that ended ends on its row of actions (Copy, Fork, Timeline, Read aloud, More), whatever
// its last rows are. Leo, 2026-11-21: "there's no buttons at the bottom even thuogh you have visibly
// stopped doing things". A turn the agent ran on its own (a background task's end woke it) that only
// ran calls and sent a message, with no reply after them, drew its calls and then nothing: acpmux
// calls such a turn quiet (no reply to tell), and `backgroundFooters` gave a footer only to a turn
// that ended with a reply, so the chat's last rows had no buttons under them while earlier replies did.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { isEmptyFooter, turnView } from "./turns";
import { turnCopyText } from "./turnCopy";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const calls = (id: string, titles: string[], extra: Partial<AcpmuxRow> = {}) =>
  row(id, "activity", {
    items: titles.map((title, index) => ({
      kind: "tool",
      text: title,
      tool: { id: `${id}-${index}`, title, kind: "execute", status: "completed" },
    })),
    ...extra,
  });
const woke = (id: string, background: Partial<NonNullable<AcpmuxRow["background"]>> = {}) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: {
      id,
      trigger: "task_notification",
      running: false,
      quiet: true,
      hasRows: true,
      cause: { kind: "shell", status: "completed", weight: "result", summary: "run pool iam.sh --apply" },
      ...background,
    },
  });

/// Leo's chat: a prompt's turn that answered, then two turns the agent ran on its own after a task
/// ended, each of calls and a sent message alone, no reply.
function leosChat(last: Partial<NonNullable<AcpmuxRow["background"]>> = {}): AcpmuxRow[] {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the identity setup script" }),
    calls("start", ["iam.sh --apply"]),
    row("reply", "assistant", { text: "I'm running the identity setup script in the background." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 12_000, seq: 40 }),
    woke("bg1"),
    calls("bg1-calls", ["acpmux send coord-deputy-3", "tail log", "gcloud iam list"], { inBackground: "bg1" }),
    woke("bg2", last),
    calls("bg2-calls", ["tail log", "acpmux send coord-deputy-3"], { inBackground: "bg2" }),
  ];
}

const footers = (view: readonly AcpmuxRow[]) => view.filter((entry) => entry.kind === "turnSummary");

test("the chat's last turn of calls alone, run on its own, ends on its row of actions", () => {
  const view = turnView(leosChat(), new Set(), { now: 60_000, agentFamily: "claude" });
  const end = view.at(-1)!;
  expect(end.kind).toBe("turnSummary");
  // The row shows at rest: it has something to copy, so it is no empty hover-only footer.
  expect(isEmptyFooter(end)).toBe(false);
  // Its Copy copies that turn's own calls, never the reply of the prompt's turn above.
  const copied = turnCopyText((key: string) => key, end.turnCopy!);
  expect(copied).not.toContain("identity setup script");
  // Its Fork goes through the last turn acpmux ended.
  expect(end.seq).toBe(40);
});

test("each turn the agent ran on its own and ended ends on its own row, as a prompt's turn does", () => {
  const view = turnView(leosChat(), new Set(), { now: 60_000, agentFamily: "claude" });
  expect(footers(view).filter((entry) => !isEmptyFooter(entry))).toHaveLength(3);
});

test("while the last turn still runs it has no row yet, and the chat draws its live line", () => {
  const view = turnView(leosChat({ running: true, quiet: undefined }), new Set(), {
    now: 60_000,
    agentFamily: "claude",
    working: true,
  });
  expect(view.some((entry) => entry.id === "backgroundEnd-bg2")).toBe(false);
});

test("idle, no live line stays at the end", () => {
  const view = turnView(leosChat(), new Set(), { now: 60_000, agentFamily: "claude", working: false });
  expect(view.some((entry) => entry.below === true || entry.kind === "thinking" || entry.kind === "working")).toBe(
    false,
  );
});

test("a quiet turn's hidden reply is not what its row copies or reads aloud", () => {
  const rows = leosChat();
  rows.push(row("bg2-dots", "assistant", { text: "Nothing new for you yet.", inBackground: "bg2" }));
  const view = turnView(rows, new Set(), { now: 60_000, agentFamily: "claude" });
  const end = view.at(-1)!;
  expect(end.kind).toBe("turnSummary");
  expect(end.text).toBeUndefined();
  expect(view.some((entry) => entry.id === "bg2-dots")).toBe(false);
});
