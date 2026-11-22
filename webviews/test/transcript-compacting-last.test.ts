// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A compaction running when the person sends a prompt stays the running turn's live line, under
// that prompt, never a row above it (Leo, 2026-11-09: "im still seeing compacting not be at the
// bottom"). Carried from #39825's `liveCompaction`.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 9, 19, 0, 0);
const at = (second: number) => START + second * 1000;
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: at(second),
  ...extra,
});
const prompt = row("u-1", "user", 0, { text: "Find every retry loop" });
const reply = row("a-1", "assistant", 2, { text: "Looking at the relay first." });
const compaction = row("compaction-9", "compaction", 5, { compaction: { state: "running" } });
const view = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true, agentFamily: "claude", now: at(60) });
const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);

for (const steer of ["waiting", "landed"] as const) {
  test(`a compaction running when the person sends (${steer}) stays the live line, under the prompt`, () => {
    const shaped = view([prompt, reply, compaction, row("u-2", "user", 10, { text: "Also check the queue", steer })]);
    const line = shaped.at(-1)!;
    expect(line.kind).toBe(THINKING);
    expect(line.liveState).toBe("compacting");
    expect(ids(shaped)).not.toContain("compaction-9");
    expect(ids(shaped).indexOf("u-2")).toBe(shaped.length - 2);
  });
}

test("another agent's message after a compaction still ends it as the live line", () => {
  const shaped = view([
    prompt,
    reply,
    compaction,
    row("u-3", "user", 8, { text: "report", incoming: { kind: "notice", text: "report" } as AcpmuxRow["incoming"] }),
  ]);
  expect(shaped.at(-1)!.liveState).not.toBe("compacting");
});
