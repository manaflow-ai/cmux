// Dispatch operations are coordination protocol calls, not generic MCP or shell work. Keeping
// their small parser here lets every harness use the same transcript card: Claude's MCP names,
// Codex's `{server, tool, arguments}` envelope, and other ACP clients' plain tool names all feed
// the same metadata shape.
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type DispatchKind = "dispatch" | "steer" | "report" | "briefs";

export type DispatchCall = {
  kind: DispatchKind;
  briefId?: string;
  title?: string;
  from?: string;
  to?: string;
  host?: string;
  sessionId?: string;
  status?: string;
  stopCondition?: string;
  text?: string;
  summary?: string;
  /** A report's link target. It is separate from `briefId` because reports may have their own id. */
  reportBriefId?: string;
};

type RecordValue = Record<string, unknown>;

const ACTION = /(?:^|[._:/_-])(dispatch|steer|report|briefs(?:[_-]?(?:ls|list))?)(?:$|[._:/_-])/i;
const ACTION_WORD = /\b(acpmux\s+)?(dispatch|steer|report|briefs(?:\s+(?:ls|list))?)\b/i;
const CLI_ACTION =
  /(?:^|[\s/])(?:acpmux|acpmux-debug-cli|cmux)(?:\s+[^;&|]*)?\s+(dispatch|steer|report|briefs(?:\s+(?:ls|list))?)(?:\s|$)/i;

/// The dispatch operation represented by one ACP activity, or undefined for ordinary MCP calls.
export function dispatchCall(item: AcpmuxActivity): DispatchCall | undefined {
  const tool = item.tool;
  if (!tool) return undefined;
  const operation = operationName(tool);
  if (!operation) return undefined;
  const args = parseJSON(tool.inputSummary);
  const output = parseJSON(tool.output);
  const values = [args, output, ...records(args), ...records(output)];
  const call: DispatchCall = {
    kind: operation,
    briefId: firstString(values, ["briefId", "brief_id"]),
    title: firstString(values, ["title", "briefTitle", "brief_title", "name"]),
    from: firstString(values, ["from", "sender", "senderId", "sender_id", "agent"]),
    to: firstString(values, ["to", "target", "recipient"]),
    host: firstString(values, ["host", "hostname", "machine"]),
    sessionId: firstString(values, ["sessionId", "session_id", "session"]),
    status: firstString(values, ["status", "state"]) ?? statusFromTool(tool),
    stopCondition: firstString(values, ["stopCondition", "stop_condition"]),
    text:
      firstString(
        values,
        operation === "report"
          ? ["report", "message", "text", "body", "content"]
          : ["brief", "prompt", "text", "body", "content"],
      ) ?? (operation === "report" ? outputSummary(tool.output) : undefined),
    summary: firstString(values, ["summary", "result", "message", "report", "text"]) ?? outputSummary(tool.output),
    reportBriefId: firstString(values, ["briefId", "brief_id", "briefRef", "brief_ref"]),
  };
  // A list call's response usually contains entries but no top-level title. Preserve a compact
  // count in the summary without printing the raw JSON in the transcript.
  if (operation === "briefs" && !call.summary) {
    const entries = Array.isArray(output)
      ? output
      : isRecord(output) && Array.isArray(output.briefs)
        ? output.briefs
        : undefined;
    if (entries) call.summary = `${entries.length} brief${entries.length === 1 ? "" : "s"}`;
  }
  return call;
}

function operationName(tool: Tool): DispatchKind | undefined {
  const title = tool.title.trim();
  const match = ACTION.exec(title) ?? ACTION_WORD.exec(title) ?? (tool.command && CLI_ACTION.exec(tool.command));
  if (!match) return undefined;
  const operation = (match[1] ?? match[2] ?? "").toLowerCase().replace(/\s+/g, "");
  if (operation === "dispatch") return "dispatch";
  if (operation === "steer") return "steer";
  if (operation === "report") return "report";
  return "briefs";
}

function statusFromTool(tool: Tool): string | undefined {
  if (tool.status === "pending" || tool.status === "in_progress") return "running";
  if (tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0)) return "failed";
  const output = tool.output?.toLowerCase() ?? "";
  if (/\bmerged\b/.test(output)) return "merged";
  if (/\breported\b/.test(output)) return "reported";
  if (/\bsteered\b/.test(output)) return "steered";
  return tool.status || undefined;
}

function outputSummary(value: string | undefined): string | undefined {
  const text = value?.trim();
  if (!text || text.startsWith("{") || text.startsWith("[")) return undefined;
  return text.length > 2_000 ? `${text.slice(0, 1_997)}…` : text;
}

function parseJSON(value: string | undefined): unknown {
  if (!value?.trim()) return undefined;
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

function records(value: unknown, depth = 0): RecordValue[] {
  if (depth > 4 || value === undefined || value === null) return [];
  if (Array.isArray(value)) return value.flatMap((entry) => records(entry, depth + 1));
  if (!isRecord(value)) return [];
  return [value, ...Object.values(value).flatMap((entry) => records(entry, depth + 1))];
}

function firstString(values: readonly unknown[], keys: readonly string[]): string | undefined {
  for (const value of values) {
    if (!isRecord(value)) continue;
    for (const key of keys) {
      const found = value[key];
      if (typeof found === "string" && found.trim()) return found.trim();
    }
  }
  return undefined;
}

function isRecord(value: unknown): value is RecordValue {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
