#!/usr/bin/env bun
// Converts a Codex rollout (a codex-atlas-clone fixture) into the mock daemon's scripts, one
// per turn, so both agent panes replay the reference thread through the real acpmux client:
//
//   bun scripts/agent-pane-port/rollout-to-script.ts <rollout.jsonl> > turns.json
//
// Output: [{ prompt, steps, endAtMs }] where steps are ACP session updates, as
// scripts/agent-pane/specimen.json. Codex items map to the ACP an agent adapter sends:
// commands to `execute` tool calls (reads and searches to `read`/`search`), file changes to
// `edit` calls with diff content, web searches to `fetch`, other tools to `other`.
import fs from "node:fs";
import { parseRollout } from "../../src/agent-session-port/conversation/rollout";
import type { ThreadItem, Turn } from "../../src/agent-session-port/conversation/protocol";

type Step = { atMs: number; update: Record<string, unknown> };

/** Old and new text of a unified diff's hunks (only the lines the hunks show). */
function sides(diff: string): { oldText: string; newText: string } {
  const oldLines: string[] = [];
  const newLines: string[] = [];
  for (const line of diff.split("\n")) {
    if (line.startsWith("@@") || line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) newLines.push(line.slice(1));
    else if (line.startsWith("-")) oldLines.push(line.slice(1));
    else {
      oldLines.push(line.slice(1));
      newLines.push(line.slice(1));
    }
  }
  return { oldText: `${oldLines.join("\n")}\n`, newText: `${newLines.join("\n")}\n` };
}

const text = (value: string) => ({ type: "content", content: { type: "text", text: value } });

function updates(item: ThreadItem): Record<string, unknown>[] {
  switch (item.type) {
    case "agentMessage":
      return [{ sessionUpdate: "agent_message_chunk", messageId: item.id, content: { type: "text", text: item.text } }];
    case "reasoning":
      return item.summary.length
        ? [{ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: item.summary.join("\n\n") } }]
        : [];
    case "commandExecution": {
      const action = item.commandActions.length === 1 ? item.commandActions[0]! : undefined;
      const kind = action?.type === "read" ? "read" : action?.type === "search" ? "search" : "execute";
      const title =
        action?.type === "read"
          ? `Read ${action.name}`
          : action?.type === "search"
            ? `Search ${action.query ?? "files"}${action.path ? ` in ${action.path}` : ""}`
            : item.command;
      const status = item.status === "failed" ? "failed" : item.status === "declined" ? "cancelled" : "completed";
      return [
        {
          sessionUpdate: "tool_call",
          toolCallId: item.id,
          kind,
          title,
          status: "in_progress",
          rawInput: { command: ["bash", "-lc", item.command] },
          ...(action?.type === "read" ? { locations: [{ path: action.path }] } : {}),
        },
        {
          sessionUpdate: "tool_call_update",
          toolCallId: item.id,
          status,
          content: item.aggregatedOutput ? [text(item.aggregatedOutput)] : [],
        },
      ];
    }
    case "fileChange":
      return [
        {
          sessionUpdate: "tool_call",
          toolCallId: item.id,
          kind: "edit",
          title: `Edit ${item.changes.map((change) => change.path).join(", ")}`,
          status: "in_progress",
          locations: item.changes.map((change) => ({ path: change.path })),
          content: item.changes.map((change) =>
            change.kind.type === "add"
              ? { type: "diff", path: change.path, newText: sides(change.diff).newText }
              : { type: "diff", path: change.path, ...sides(change.diff) },
          ),
        },
        { sessionUpdate: "tool_call_update", toolCallId: item.id, status: "completed" },
      ];
    case "webSearch":
      return [
        {
          sessionUpdate: "tool_call",
          toolCallId: item.id,
          kind: "fetch",
          title: `Searched the web for ${item.query}`,
          status: "in_progress",
        },
        { sessionUpdate: "tool_call_update", toolCallId: item.id, status: "completed" },
      ];
    case "mcpToolCall": {
      const title = typeof item.arguments?.title === "string" ? item.arguments.title : `${item.server}.${item.tool}`;
      const output = (item.result?.content ?? [])
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join("\n");
      return [
        { sessionUpdate: "tool_call", toolCallId: item.id, kind: "other", title, status: "in_progress" },
        {
          sessionUpdate: "tool_call_update",
          toolCallId: item.id,
          status: item.status === "failed" ? "failed" : "completed",
          content: output ? [text(output)] : [],
        },
      ];
    }
    case "dynamicToolCall":
      return [
        { sessionUpdate: "tool_call", toolCallId: item.id, kind: "other", title: item.tool, status: "in_progress" },
        {
          sessionUpdate: "tool_call_update",
          toolCallId: item.id,
          status: item.status === "failed" ? "failed" : "completed",
        },
      ];
    default:
      return [];
  }
}

export function turnScript(turn: Turn) {
  const user = turn.items.find((item) => item.type === "userMessage");
  const prompt =
    user?.type === "userMessage"
      ? user.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n")
      : "";
  const duration = turn.durationMs ?? 0;
  const body = turn.items.filter((item) => item.type !== "userMessage");
  const all = body.flatMap(updates);
  const gap = all.length ? Math.max(1, Math.floor((duration || 1000) / (all.length + 1))) : 0;
  const steps: Step[] = all.map((update, index) => ({ atMs: gap * (index + 1), update }));
  return { prompt, steps, endAtMs: duration || gap * (all.length + 1) };
}

if (import.meta.main) {
  const file = process.argv[2];
  if (!file) throw new Error("usage: rollout-to-script.ts <rollout.jsonl>");
  process.stdout.write(JSON.stringify(parseRollout(fs.readFileSync(file, "utf8")).map(turnScript)));
}
