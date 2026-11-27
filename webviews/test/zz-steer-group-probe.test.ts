import { test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { subagentRowsFrom } from "../src/agent-session/acpmux/subagents/subagentRows";
import { projectInboxRows } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { playTurn, type GapEvent } from "./support/thinkingGapScenes";

const show = (rows: AcpmuxRow[]) =>
  rows.map((r) => `${r.kind}:${r.id}${r.text ? " «" + r.text.slice(0, 30) + "»" : ""}${(r as any).foldOpen === false ? " (closed)" : ""}`);

for (const [name, events] of Object.entries({
  leo: [{ kind: "subagent" }, { kind: "subagent" }, { kind: "steer" }, { kind: "subagentEnd" }, { kind: "subagentEnd" }, { kind: "thought", ended: true }, { kind: "reply", text: "Both subagents ... banana." }, { kind: "end" }],
  noSteer: [{ kind: "subagent" }, { kind: "subagent" }, { kind: "subagentEnd" }, { kind: "subagentEnd" }, { kind: "thought", ended: true }, { kind: "reply", text: "Both." }, { kind: "end" }],
  toolSteer: [{ kind: "tool", status: "completed" }, { kind: "subagent" }, { kind: "steer" }, { kind: "subagentEnd" }, { kind: "tool", status: "completed" }, { kind: "reply", text: "Both." }, { kind: "end" }],
  twoSteers: [{ kind: "tool", status: "completed" }, { kind: "steer" }, { kind: "steer" }, { kind: "tool", status: "completed" }, { kind: "reply", text: "Done." }, { kind: "end" }],
  steersApart: [{ kind: "tool", status: "completed" }, { kind: "steer" }, { kind: "tool", status: "completed" }, { kind: "steer" }, { kind: "tool", status: "completed" }, { kind: "reply", text: "Done." }, { kind: "end" }],
} as Record<string, GapEvent[]>))
  test(name, () => {
    const steps = playTurn(events);
    for (const step of [steps.at(-2)!, steps.at(-1)!]) {
      const working = step.working !== false;
      const turns = turnViewFrom(step.rows, new Set(), { working, agentFamily: "claude" });
      const rows = subagentRowsFrom(projectInboxRows(turns.rows), new Set()).rows;
      console.log(`== ${name} ${step.name} working=${working}\n  ` + show(rows).filter((s) => !s.includes(":h-")).join("\n  "));
    }
  });
