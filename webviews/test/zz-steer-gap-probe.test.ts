import { test } from "bun:test";
import { layoutConversation } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { subagentRowsFrom } from "../src/agent-session/acpmux/subagents/subagentRows";
import { projectInboxRows } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { playTurn } from "./support/thinkingGapScenes";
test("gaps", () => {
  const steps = playTurn([{ kind: "tool", status: "completed" }, { kind: "steer" }, { kind: "steer" }, { kind: "tool", status: "completed" }, { kind: "reply", text: "Done." }, { kind: "end" }]);
  for (const step of [steps.at(-2)!, steps.at(-1)!]) {
    const turns = turnViewFrom(step.rows, new Set(), { working: step.working !== false, agentFamily: "claude" });
    const rows = subagentRowsFrom(projectInboxRows(turns.rows), new Set()).rows;
    const l = layoutConversation(rows, 800);
    console.log(rows.map((r, i) => `${r.kind}:${r.id} top=${l.tops[i]} h=${l.heights[i]} gapAbove=${i ? l.tops[i]! - l.tops[i - 1]! - l.heights[i - 1]! : 0}`).filter((s) => !s.includes(":h-")).join("\n"));
  }
});
