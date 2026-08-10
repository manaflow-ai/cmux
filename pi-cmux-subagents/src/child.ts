import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { ChildResult } from "./types.js";

export default function childExtension(pi: ExtensionAPI) {
  const resultPath = process.env.PI_CMUX_SUBAGENT_RESULT;
  const id = process.env.PI_CMUX_SUBAGENT_ID;
  if (!resultPath || !id) return;

  pi.registerTool({
    name: "report_to_parent",
    label: "Report to parent",
    description: "Finish this subagent and return its concise result to the parent Pi session.",
    promptSnippet: "Return the subagent's final result to its parent",
    promptGuidelines: [
      "Call report_to_parent exactly once when the assigned task is complete or blocked. Put the complete, concise handoff in summary.",
    ],
    parameters: Type.Object({
      summary: Type.String({ description: "Complete result or handoff for the parent agent" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const result: ChildResult = {
        id,
        status: "completed",
        summary: params.summary,
        finishedAt: new Date().toISOString(),
      };
      await mkdir(dirname(resultPath), { recursive: true });
      const temporary = `${resultPath}.${process.pid}.tmp`;
      await writeFile(temporary, `${JSON.stringify(result, null, 2)}\n`, "utf8");
      await rename(temporary, resultPath);
      ctx.shutdown();
      return {
        content: [{ type: "text", text: "Result delivered. This subagent session will close." }],
        details: result,
        terminate: true,
      };
    },
  });
}
