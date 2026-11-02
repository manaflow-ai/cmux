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
  count?: number;
  /** A report's link target. It is separate from `briefId` because reports may have their own id. */
  reportBriefId?: string;
};

type RecordValue = Record<string, unknown>;

const EVENT_KIND = /^(dispatch|steer|report|briefs?)$/i;
const EXPLICIT_TOOL =
  /^(?:dispatch|steer|report|briefs?|(?:mcp__)?(?:acpmux|cmux|codex_apps)(?:__|[./:-])(?:agent_)?|agent_)(dispatch|steer|report|briefs(?:[_-]?(?:ls|list))?)(?:\s+call)?$/i;
const CLI_TITLE = /^acpmux(?:-debug-cli)?\s+(dispatch|steer|report|briefs(?:\s+(?:ls|list))?)(?:\s|$)/i;
const CLI_ACTION =
  /(?:^|(?:&&|\|\||;)\s*)(?:\w+=\S+\s+)*(?:\S+\/)?acpmux(?:-debug-cli)?\s+(dispatch|steer|report|briefs(?:\s+(?:ls|list))?)(?:\s|$)/i;

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
    briefId: firstString(values, ["briefId", "brief_id", "id"]),
    title: firstString(values, ["title", "briefTitle", "brief_title", "name"]),
    from: identityString(values, ["from", "sender"]) ?? firstString(values, ["senderId", "sender_id", "agent"]),
    to: identityString(values, ["to", "target", "recipient"]) ?? firstString(values, ["target", "recipient"]),
    host:
      identityField(values, "to", ["host", "hostname", "machine"]) ??
      firstString(values, ["host", "hostname", "machine"]),
    sessionId:
      identityField(values, "to", ["sessionId", "session_id", "session"]) ??
      firstString(values, ["sessionId", "session_id", "session"]),
    status: dispatchStatus(tool, output),
    stopCondition: firstString(values, ["stopCondition", "stop_condition"]),
    text:
      firstString(
        values,
        operation === "report"
          ? ["report", "message", "text", "body", "content"]
          : ["brief", "prompt", "text", "body", "content"],
      ) ?? (operation === "report" ? outputSummary(tool.output) : undefined),
    summary: firstString(values, ["summary", "result", "message", "report", "text"]) ?? outputSummary(tool.output),
    reportBriefId: firstString(values, ["briefId", "brief_id", "briefRef", "brief_ref", "id"]),
  };
  // A list call's response usually contains entries but no top-level title. Preserve a compact
  // count in the summary without printing the raw JSON in the transcript.
  if (operation === "briefs" && !call.summary) {
    const entries = Array.isArray(output)
      ? output
      : isRecord(output) && Array.isArray(output.briefs)
        ? output.briefs
        : undefined;
    if (entries) call.count = entries.length;
  }
  return call;
}

function operationName(tool: Tool): DispatchKind | undefined {
  const title = tool.title.trim();
  const input = parseJSON(tool.inputSummary);
  if (isRecord(input) && typeof input.server === "string" && typeof input.tool === "string" && "arguments" in input) {
    const server = input.server.toLowerCase();
    if (!["acpmux", "cmux", "codex_apps", "agent_dispatch"].includes(server)) return undefined;
    const codexTool = input.tool.toLowerCase().replace(/^agent_/, "");
    if (["dispatch", "steer", "report", "briefs", "briefs_ls", "briefs_list"].includes(codexTool)) {
      return codexTool === "dispatch"
        ? "dispatch"
        : codexTool === "steer"
          ? "steer"
          : codexTool === "report"
            ? "report"
            : "briefs";
    }
  }
  const explicit =
    EXPLICIT_TOOL.exec(title) ?? CLI_TITLE.exec(title) ?? (tool.command && CLI_ACTION.exec(tool.command));
  const args = parseJSON(tool.inputSummary);
  const output = parseJSON(tool.output);
  const event = [args, output].find((value) => {
    const kind = isRecord(value) && isRecord(value.event) ? value.event.kind : undefined;
    return typeof kind === "string" && EVENT_KIND.test(kind);
  });
  const eventKind =
    isRecord(event) && isRecord(event.event) && typeof event.event.kind === "string" ? event.event.kind : "";
  const plain = /^(dispatch|steer|report|briefs?)$/i.exec(title)?.[1];
  const operation = (plain ?? explicit?.[1] ?? eventKind).toLowerCase().replace(/\s+/g, "");
  if (!operation) return undefined;
  if (operation === "dispatch") return "dispatch";
  if (operation === "steer") return "steer";
  if (operation === "report") return "report";
  return "briefs";
}

function dispatchStatus(tool: Tool, output: unknown): string | undefined {
  if (tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0)) return "failed";
  if (tool.status === "pending" || tool.status === "in_progress") return "running";
  // Input is a requested transition; prose is the report's content. Only the
  // structured acknowledgement can confirm a brief's lifecycle transition.
  return firstString([output, ...records(output)], ["status", "state"]) ?? (tool.status || undefined);
}

/// A plain-text output as the report's text, whole: the card's panel scrolls a long one (Leo,
/// ask-486cb2cec3: "why the fuck did you guys ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND
/// WHAT WAS SAID TO SEE"). The line shows only its first line (DispatchCard.tsx `messagePreview`).
function outputSummary(value: string | undefined): string | undefined {
  const text = value?.trim();
  if (!text || text.startsWith("{") || text.startsWith("[")) return undefined;
  return text;
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

function identityString(values: readonly unknown[], keys: readonly string[]): string | undefined {
  for (const value of values) {
    if (!isRecord(value)) continue;
    for (const key of keys) {
      const found = value[key];
      if (typeof found === "string" && found.trim()) return found.trim();
      if (isRecord(found)) {
        const identity = firstString(
          [found],
          ["actor_id", "actorId", "name", "id", "session_id", "session", "harness", "host"],
        );
        if (identity) return identity;
      }
    }
  }
  return undefined;
}

function identityField(values: readonly unknown[], key: string, fields: readonly string[]): string | undefined {
  for (const value of values) {
    if (!isRecord(value) || !isRecord(value[key])) continue;
    const found = firstString([value[key]], fields);
    if (found) return found;
  }
  return undefined;
}

function isRecord(value: unknown): value is RecordValue {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
