// l10n-allow-file: test fixture prompts, not shipped UI.
// Jump up's "sent" mark (jumpUp.ts `lastOwnPrompt`) is the last prompt the reader sent by hand: never
// another agent's message, a task's result, the Chief's message to a subagent, or another person's
// prompt in a shared chat (Leo, 2026-11-10: "jumping up since like the last time you interacted
// manually").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { lastOwnPrompt, ownPrompt, type PromptScan } from "./jumpUp";

const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: Number(id.replace(/\D/g, "")) || 0,
  kind: "user",
  text: id,
  ...extra,
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "agent", text: "ok" });
const scan = (): { current: PromptScan } => ({ current: { length: 0 } });

test("the last prompt the reader sent, past the prompts they did not type", () => {
  const rows: AcpmuxRow[] = [
    row("typed-1"),
    reply("reply-1"),
    row("typed-2"),
    reply("reply-2"),
    row("task-result-3", { untyped: true }),
    row("agent-message-4", { incoming: { kind: "message" } as AcpmuxRow["incoming"] }),
    row("chief-5", { from: "chief" }),
    reply("reply-3"),
  ];
  expect(lastOwnPrompt(rows, scan())?.id).toBe("typed-2");
  const noneTyped = rows.filter((each) => each.kind !== "user" || each.untyped);
  expect(lastOwnPrompt(noneTyped, scan())).toBeUndefined();
});

test("in a shared chat, yours is the one with your author: none for the owner, your id for a guest", () => {
  const guest = { id: "guest-1", name: "Sam" };
  const other = { id: "guest-2", name: "Kim" };
  const rows: AcpmuxRow[] = [row("owner-1"), row("guest-2", { author: guest }), row("other-3", { author: other })];
  expect(lastOwnPrompt(rows, scan())?.id).toBe("owner-1");
  expect(lastOwnPrompt(rows, scan(), "guest-1")?.id).toBe("guest-2");
  expect(lastOwnPrompt(rows, scan(), "guest-3")).toBeUndefined();
  expect(ownPrompt(rows[2]!, "guest-2")).toBe(true);
});

test("appended rows are scanned alone, and another person's prompt after yours does not move the mark", () => {
  const memo = scan();
  const rows: AcpmuxRow[] = [row("owner-1"), reply("reply-1")];
  expect(lastOwnPrompt(rows, memo)?.id).toBe("owner-1");
  const more = [...rows, row("guest-2", { author: { id: "guest-1", name: "Sam" } }), reply("reply-2")];
  expect(lastOwnPrompt(more, memo)?.id).toBe("owner-1");
  expect(memo.current.length).toBe(4);
  const mine = [...more, row("owner-3")];
  expect(lastOwnPrompt(mine, memo)?.id).toBe("owner-3");
});

test("a new author id scans again rather than keeping the last author's prompt", () => {
  const memo = scan();
  const rows: AcpmuxRow[] = [row("owner-1"), row("guest-2", { author: { id: "guest-1", name: "Sam" } })];
  expect(lastOwnPrompt(rows, memo)?.id).toBe("owner-1");
  expect(lastOwnPrompt(rows, memo, "guest-1")?.id).toBe("guest-2");
});
