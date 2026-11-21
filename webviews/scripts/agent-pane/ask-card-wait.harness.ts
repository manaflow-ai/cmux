// How long an agent's wrap-up card waits before the chat draws it (bench `ask-card-wait`).
// Leo, 2026-11-19, on the Needs your input cards: "plus it's not instant yet".
//
// Reads acpmux session event logs (`~/.acpmux/sessions/<id>/events/*.ndjson`). Each call's events go
// through the client's own merge (direct.ts `mergeToolItem`), as the pane builds its row. When a
// wrap-up call returns (`acpmux_wrap_up` from `cmux_exec`, or `mcp__acpmux__wrap_up`), the harness
// shapes the running turn as the pane does at that moment (turns.ts `turnView`, working) and looks for
// the card. Drawn: it waited 0 ms. Not drawn: it waited until the turn's `turn_end`, when the pane
// shapes the ended turn. Prints one line:
//   ASK-CARD-WAIT n=N p50_ms=X p90_ms=X p95_ms=X drawn_live=K
// Usage: bun scripts/agent-pane/ask-card-wait.harness.ts [SESSIONS_DIR]
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { mergeToolItem, textFromContent } from "../../src/agent-session/acpmux/direct";
import { execWrapUp, isWrapUp, wrapUpAsk } from "../../src/agent-session/acpmux/conversation/wrapUp";
import { NEXT_STEP, turnView } from "../../src/agent-session/acpmux/conversation/turns";

const root = process.argv[2] ?? join(homedir(), ".acpmux/sessions");
const WRAP = /acpmux_wrap_up|mcp__acpmux__wrap_up/;

type Update = { toolCallId?: string; status?: string; content?: unknown };

/// The running turn at the call's return, as the pane holds it: the prompt, a reply, and the call.
function drawnLive(item: AcpmuxActivity, at: number): boolean {
  const rows = [
    { id: "p", version: 1, at: at - 2, kind: "user", text: "prompt" },
    { id: "a", version: 1, at: at - 1, kind: "assistant", text: "reply" },
    { id: "w", version: 1, at, kind: "activity", items: [item] },
  ] as unknown as AcpmuxRow[];
  return turnView(rows, new Set(), { working: true }).some((row) => row.kind === NEXT_STEP);
}

const waits: number[] = [];
let live = 0;
for (const session of existsSync(root) ? readdirSync(root) : []) {
  const dir = join(root, session, "events");
  if (!existsSync(dir)) continue;
  const calls = new Map<string, AcpmuxActivity>();
  let pending: { at: number; drawn: boolean } | undefined;
  for (const file of readdirSync(dir)
    .filter((name) => name.endsWith(".ndjson"))
    .sort()) {
    for (const line of readFileSync(join(dir, file), "utf8").split("\n")) {
      const ends = line.includes('"turn_end"');
      if (!ends && !(line.includes('"tool_call') && (WRAP.test(line) || calls.size > 0))) continue;
      let event: { at: number; kind: string; msg?: { params?: { update?: Update } } };
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      if (event.kind === "turn_end") {
        if (pending) waits.push(pending.drawn ? 0 : event.at - pending.at);
        pending = undefined;
        calls.clear();
        continue;
      }
      if (event.kind !== "tool_call" && event.kind !== "tool_call_update") continue;
      const update = event.msg?.params?.update;
      const id = update?.toolCallId;
      if (!update || !id || (!calls.has(id) && !WRAP.test(line))) continue;
      const item = mergeToolItem(calls.get(id), update, id, textFromContent(update.content), event.at);
      calls.set(id, item);
      // A wrap-up as the pane reads one (wrapUp.ts, the same on every build): not a ToolSearch that
      // loads the tool, nor output that names it.
      const tool = item.tool;
      if (update.status !== "completed" || !tool || !(isWrapUp(tool) || execWrapUp(tool)) || !wrapUpAsk(tool)) continue;
      const drawn = drawnLive(item, event.at);
      if (drawn) live += 1;
      pending = { at: event.at, drawn };
    }
  }
}
waits.sort((a, b) => a - b);
const q = (p: number) => waits[Math.min(waits.length - 1, Math.floor(p * waits.length))] ?? "None";
console.log(`ASK-CARD-WAIT n=${waits.length} p50_ms=${q(0.5)} p90_ms=${q(0.9)} p95_ms=${q(0.95)} drawn_live=${live}`);
