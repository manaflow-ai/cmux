// Temporary dump (deleted before commit): the settled turn's rows, working false vs true, after a send.
import { test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 22, 21, 40, 0);
const at = (s: number) => START + s * 1000;
const row = (id: string, kind: string, s: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: at(s),
  ...extra,
});
const call = (id: string, title: string, a: number, b?: number, kind = "execute") => ({
  kind: "tool",
  text: title,
  tool: {
    id,
    title,
    kind,
    status: b === undefined ? "in_progress" : "completed",
    startedAt: at(a),
    ...(b !== undefined && { endedAt: at(b) }),
  },
});
const base: AcpmuxRow[] = [
  row("u-1", "user", 0, { text: "Fix it." }),
  row("act-1", "activity", 2, { items: [call("c-1", "Run tests", 2, 20)] as never }),
  row("a-1", "assistant", 40, { text: "Looking." }),
  row("act-2", "activity", 41, { items: [call("c-2", "Agent: scan logs", 41, undefined, "think")] as never }),
  row("a-2", "assistant", 62, { text: "Fixed." }),
  row("s-1", "turnSummary", 63, { status: "completed", durationMs: 63_000, toolCount: 2 }),
];
const delivery = { state: "sending", promptId: "p-2", sessionId: "s", sentAt: at(70) } as const;
const sending = row("local-p-2", "user", 70, { text: "next", pending: true, delivery });
const written = row("local-p-2", "user", 70, { text: "next", version: 2, promptId: "p-2" });
const dump = (rows: readonly AcpmuxRow[]) =>
  rows
    .map(
      (r) =>
        `${r.kind}:${r.id}${r.foldOpen !== undefined ? (r.foldOpen ? "(open)" : "(closed)") : ""}${r.below ? "*" : ""}`,
    )
    .join(" | ");
for (const family of ["claude", "codex"])
  test(`dump ${family}`, () => {
    const cases: [string, AcpmuxRow[], boolean][] = [
      ["settled", base, false],
      ["pending, idle", [...base, sending], false],
      ["pending, working", [...base, sending], true],
      ["pending+typing, working", [...base, sending, row("typing", "typing", 71)], true],
      ["written, working", [...base, written], true],
      ["written+typing, working", [...base, written, row("typing", "typing", 71)], true],
    ];
    for (const [name, rows, working] of cases)
      console.log(
        `DUMP ${family} ${name.padEnd(26)} ${dump(turnView(rows, new Set(), { working, agentFamily: family, now: at(72), turnStartedAtMs: working ? at(71) : undefined }))}`,
      );
  });
