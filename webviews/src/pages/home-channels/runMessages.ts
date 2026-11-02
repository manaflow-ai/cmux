// Preserve full message arguments before producing ordinary tool summaries.
import type { AcpmuxActivity } from "../../agent-session/acpmux/model";
import { agentMessage, type AgentMessage } from "../../agent-session/acpmux/conversation/agentMessages";
import type { HomeRunStep } from "./types";

/** A tool or thought step as the agent pane's activity item (ToolRow, ThoughtRow). */
export function stepActivity(step: HomeRunStep): AcpmuxActivity {
  if (step.kind !== "tool" || !step.tool) return { kind: "thought", text: step.text ?? "" };
  const tool = step.tool;
  const input = tool.input && typeof tool.input === "object" ? (tool.input as Record<string, unknown>) : undefined;
  const command = typeof input?.command === "string" ? input.command : undefined;
  const activity: AcpmuxActivity = {
    kind: "tool",
    text: tool.title ?? tool.name,
    status: step.status,
    tool: {
      id: step.id,
      title: tool.name,
      kind: tool.kind,
      status: step.status === "done" ? "completed" : step.status === "failed" ? "failed" : "in_progress",
      inputSummary: input ? JSON.stringify(input) : typeof tool.input === "string" ? tool.input : undefined,
      output: tool.output,
      command,
      exitCode: tool.exitCode,
      startedAt: tool.startedAt,
      endedAt: tool.endedAt,
      diffs: tool.files
        .filter((file) => file.newText !== undefined)
        .map((file) => ({
          path: file.path,
          oldText: file.oldText,
          newText: file.newText!,
          line: file.line,
        })),
      locations: tool.files.map((file) => ({ path: file.path, line: file.line })),
    },
  };
  // Classify with the canonical tool name and full arguments before making a display summary.
  if (!agentMessage(activity.tool!)) {
    activity.tool!.title = tool.title ?? tool.name;
    activity.tool!.inputSummary = input ? summary(input) : activity.tool!.inputSummary;
  }
  return activity;
}

function summary(input: Record<string, unknown>): string {
  for (const key of ["command", "file_path", "path", "pattern", "url", "query", "description"]) {
    const value = input[key];
    if (typeof value === "string" && value) return value;
  }
  return JSON.stringify(input).slice(0, 200);
}

export type RunAgentMessage = { item: AcpmuxActivity; sent: AgentMessage } | { from: string; text: string };

/** One card's classifications. Retain only its current steps; unversioned Cloud steps use
 * object identity, since a replacement at revision zero can contain a new delivery result. */
export class RunMessageCache {
  private entries = new Map<string, { step: HomeRunStep; rev: number; message: RunAgentMessage | undefined }>();

  private runKey?: string;

  classify(
    steps: readonly HomeRunStep[],
    runKey?: string,
  ): {
    messages: { step: HomeRunStep; message: RunAgentMessage }[];
    work: HomeRunStep[];
  } {
    if (runKey !== this.runKey) {
      this.entries.clear();
      this.runKey = runKey;
    }
    const next: typeof this.entries = new Map();
    const messages: { step: HomeRunStep; message: RunAgentMessage }[] = [];
    const work: HomeRunStep[] = [];
    for (const step of steps) {
      const held = this.entries.get(step.id);
      const cached = held && held.rev === step.rev && (step.rev > 0 || held.step === step);
      const entry = cached ? held : { step, rev: step.rev, message: stepMessage(step) };
      next.set(step.id, entry);
      if (entry.message) messages.push({ step, message: entry.message });
      else if (step.kind === "tool") work.push(step);
    }
    this.entries = next;
    return { messages, work };
  }
}

export function stepMessage(step: HomeRunStep): RunAgentMessage | undefined {
  if (step.kind === "tool") {
    const item = stepActivity(step);
    const sent = item.tool && agentMessage(item.tool);
    return sent ? { item, sent } : undefined;
  }
  if (step.kind === "note" && step.id.startsWith("report:")) {
    const match = /^\[([^\]\n]+)\] ([\s\S]*)$/.exec(step.text ?? "");
    if (match) return { from: match[1]!, text: match[2]! };
  }
  return undefined;
}
