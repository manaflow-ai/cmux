import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
const START = 0;
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const shell = (id: string, command: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: command, kind: "execute", status: "completed", command },
});
const calls = (id: string, second: number, commands: string[]): AcpmuxRow =>
  row(id, "activity", second, { items: commands.map((c, i) => shell(`${id}-${i}`, c)) });
const message = (id: string, second: number, name: string, text: string) =>
  row(id, "user", second, {
    text,
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  });
const messaged: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Watch the nightly" }),
  calls("t-1", 1, ["gh run list"]),
  row("a-before", "assistant", 60, { text: "Watching it; I'll tell the owner when it's green." }),
  message("m-1", 90, "lane-box/ux-owner", "Is it green yet?"),
  calls("t-2", 91, ["gh run view 42", "gh pr view 7"]),
  row("a-final", "assistant", 200, { text: "Green; the owner is landing." }),
  row("s-0", "turnSummary", 210, { status: "completed", durationMs: 210_000, toolCount: 3 }),
];
test("dbg", () => {
  for (const fam of ["codex", "claude"]) {
    const v = turnView(messaged, new Set([`${WORKED}-m-1`]), { agentFamily: fam, now: 400_000 });
    console.log(
      "DBG",
      fam,
      JSON.stringify(v.map((r) => [r.kind, r.id, r.messageRun?.rows, r.joined, r.foldedPrompt?.id])),
    );
  }
});
