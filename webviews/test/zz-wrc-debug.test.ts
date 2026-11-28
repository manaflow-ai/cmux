import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({ id, kind, at: 1_000, version: 1, ...extra });
const prompt = row("prompt", "user", { text: "Check the code" });
const commentary = row("commentary", "assistant", { text: "Checking the caller.", assistantPhase: "commentary" });
const call = row("call", "activity", { items: [{ kind: "tool", text: "Read caller.ts", tool: { id: "read", title: "Read caller.ts", kind: "read", status: "completed" } }] });
const answer = row("answer", "assistant", { at: 16_000, text: "The fix is ready.", assistantPhase: "final_answer", streaming: true });
const pick = (r: AcpmuxRow) => ({ id: r.id, kind: r.kind, turnPhase: r.turnPhase, foldOpen: r.foldOpen, durationMs: r.durationMs, at: r.at });
for (const arms of [undefined, { "live-turn-work": "open" }, { "live-turn-work": "open", "live-turn-clock": "line" }] as const)
  test(`dump ${JSON.stringify(arms)}`, () => {
    globalThis.cmuxExperiments = arms as never;
    const o = { agentFamily: "codex", working: true, now: 10_000 };
    console.log("ARMS", JSON.stringify(arms));
    console.log("BEFORE", JSON.stringify(turnViewFrom([prompt, commentary, call], new Set(), o).rows.map(pick)));
    console.log("FINAL", JSON.stringify(turnViewFrom([prompt, commentary, call, answer], new Set(), { ...o, now: 40_000 }).rows.map(pick)));
    expect(1).toBe(2);
  });
