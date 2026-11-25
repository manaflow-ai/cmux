import { test } from "bun:test";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { rowMark } from "../src/agent-session/acpmux/transcriptGrid";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => ["in","agent_message_chunk",update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } })];
const call = (id: string, title: string, kind: string, status="completed"): Step => ["in","tool_call",update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status })];
const cases: Record<string, Step[]> = {
  woken: [
  ["mux", "user_message", { text: "Reclaim", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  call("reclaim", "wt reclaim --apply", "execute"),
  say("Removing them."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
  ["mux","background_turn",{state:"started",id:"bg",trigger:"task_notification",cause:{kind:"shell",status:"completed",weight:"result",origin:"reclaim",summary:"done"}}],
  call("read-output", "Read x.output", "read"),
  call("r2", "ls", "execute", "in_progress"),
  ],
  prompted: [
  ["mux", "user_message", { text: "Reclaim", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  call("reclaim", "wt reclaim --apply", "execute"),
  say("Removing them."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
  ["mux", "user_message", { text: "next", turnId: "t2" }],
  ["mux", "turn_started", { turnId: "t2" }],
  call("r2", "ls", "execute", "in_progress"),
  ],
};
for (const [name, steps] of Object.entries(cases))
test("probe " + name, async () => {
  const { client, rows } = await connect(fakeDaemon(record(steps)));
  try {
    const raw = rows();
    console.log(name, "RAW", raw.map((r) => r.kind).join(","));
    const view = turnView(raw, new Set(), { working: true, now: Date.now() }).filter((r) => r.kind !== "date") as AcpmuxRow[];
    const layout = layoutConversation(view, 720);
    view.forEach((r, i) => console.log(name, i, r.kind, r.id, (r as any).below ? "below" : "", "mark", rowMark(r), "top", layout.tops[i], "h", layout.heights[i], "gapAbove", i ? layout.tops[i]! - layout.tops[i-1]! - layout.heights[i-1]! : 0));
  } finally { client.close(); }
});
