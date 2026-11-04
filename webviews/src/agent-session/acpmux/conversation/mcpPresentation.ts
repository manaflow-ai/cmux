// Presentation-only reductions. Original calls remain available to Find, copy and export.
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { losesNumbers, parseJSONValue } from "./toolResult";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const DISCOVERY_NAMES = /^(?:ToolSearch|tool_search|load_tools)$/;

// Only the harness's successful discovery operation is noise; never hide a server's similarly
// named user operation, a pending permission, a failed discovery, or an error returned as success.
export function isToolDiscoveryNoise(tool: Tool | undefined): boolean {
  if (
    !tool ||
    tool.status !== "completed" ||
    tool.command ||
    tool.diffs?.length ||
    tool.images?.length ||
    tool.background ||
    tool.approved
  )
    return false;
  const provenanceName = tool.provenance?.claudeTool ?? tool.provenance?.claudeCodeToolName;
  if (
    !provenanceName ||
    tool.title !== provenanceName ||
    !DISCOVERY_NAMES.test(provenanceName) ||
    mcpCall(tool)
  )
    return false;
  if (
    (tool.exitCode ?? 0) !== 0 ||
    /(?:"(?:isError|error)"\s*:\s*(?!(?:false|null|0)\s*[,}])\S|"(?:success|ok)"\s*:\s*(?:false|0)\b|"(?:status|state)"\s*:\s*"(?:error|failed|cancelled|canceled)"|^\s*(?:error|failed|unable|unavailable|cancelled|canceled)(?:\s+by\s+user)?\b)/im.test(
      tool.output ?? "",
    )
  )
    return false;
  return true;
}

// Rendering and first-layout accounting share this projection. Transcript snapshots remain
// intact for Find/copy/export; Find may explicitly reveal the original calls. Cache by the
// immutable items array so geometry's repeated edge checks never rescan the tool run.
const visibleItems = new WeakMap<readonly AcpmuxActivity[], AcpmuxActivity[]>();
export function visibleToolItems(
  items: AcpmuxActivity[] | undefined,
  revealing = false,
): AcpmuxActivity[] | undefined {
  if (!items || revealing) return items;
  const kept = visibleItems.get(items);
  if (kept) return kept;
  const projected = items.filter((item) => !isToolDiscoveryNoise(item.tool));
  const result = projected.length === items.length ? items : projected;
  visibleItems.set(items, result);
  return result;
}

export function usefulMcpRequest(args: unknown): { command?: string; context?: string } {
  if (!args || typeof args !== "object" || Array.isArray(args)) return {};
  const values = args as Record<string, unknown>;
  const command = [values.command, values.cmd].find(
    (value): value is string => typeof value === "string" && !!value.trim(),
  );
  if (command) return { command };
  const context = [
    values.paths ?? values.path ?? values.file_path ?? values.url,
    values.pattern ?? values.query,
  ]
    .flatMap((value) => (Array.isArray(value) ? value : [value]))
    .filter((value): value is string => typeof value === "string" && !!value.trim())
    .join("\n");
  return context ? { context } : {};
}

// A bare lifecycle placeholder isn't output. Restrict this to an exact whole response, so logs
// containing the same words and genuine data are never shortened or discarded.
export function usefulMcpResponse(text: string | undefined): string | undefined {
  if (!text?.trim() || /^(?:waiting|running|pending)(?:\.{3}|…)?$/i.test(text.trim()))
    return undefined;
  // Preserve the existing result reader's exact numeric IDs and bounded object parsing.
  // A condensed view must never round a value that Raw still represents faithfully.
  if (losesNumbers(text)) return text;
  let value: unknown;
  try {
    value = /^\s*[[{]/.test(text) ? parseJSONValue(text) : JSON.parse(text);
    if (value === undefined) return text;
  } catch {
    return text;
  }
  const human = (part: unknown, depth: number): string[] => {
    if (depth > 8) return [JSON.stringify(part) ?? String(part)];
    if (typeof part === "string") return [part];
    if (part === null || typeof part === "number" || typeof part === "boolean")
      return [String(part)];
    if (Array.isArray(part)) return part.flatMap((item) => human(item, depth + 1));
    if (!part || typeof part !== "object") return [];
    const record = part as Record<string, unknown>;
    const proseKeys = [
      "text",
      "message",
      "detail",
      "reason",
      "error",
      "output",
      "stdout",
      "stderr",
      "content",
      "matches",
      "results",
      "data",
    ];
    const body = proseKeys.flatMap((key) => human(record[key], depth + 1));
    const path = record.path ?? record.file;
    const extras = Object.entries(record)
      .filter(
        ([key, item]) =>
          !proseKeys.includes(key) &&
          !["type", "isError", "mimeType", "_meta"].includes(key) &&
          !(typeof path === "string" && body.length && ["path", "file", "line"].includes(key)) &&
          !(
            ["status", "state"].includes(key) &&
            typeof item === "string" &&
            /^(?:waiting|running|pending)$/i.test(item)
          ),
      )
      .flatMap(([key, item]) => {
        const label = key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ");
        return human(item, depth + 1).map((line) => `${label}: ${line}`);
      });
    const lines = [...body, ...extras];
    return typeof path === "string" && body.length
      ? lines.map(
          (line) => `${path}${typeof record.line === "number" ? `:${record.line}` : ""}: ${line}`,
        )
      : lines;
  };
  const lines = human(value, 0);
  return lines.length ? usefulMcpResponseText(lines.join("\n")) : undefined;
}

function usefulMcpResponseText(text: string): string | undefined {
  return /^(?:waiting|running|pending)(?:\.{3}|…)?$/i.test(text.trim()) ? undefined : text;
}

// A lifecycle marker is never useful output even when a harness wraps it in JSON.
export function isMcpLifecycleOutput(output: string | undefined): boolean {
  if (!output?.trim()) return true;
  if (/^"(?:waiting|running|pending)(?:\.{3}|…)?"$/i.test(output.trim())) return true;
  // Closed rows need only recognize small lifecycle envelopes. Reuse the output reader's
  // parsing bound; large results remain real output and are rendered only on disclosure.
  const value = parseJSONValue(output) ?? output;
  const marker = (part: unknown, depth = 0): boolean => {
    if (typeof part === "string")
      return /^(?:waiting|running|pending)(?:\.{3}|…)?$/i.test(part.trim());
    if (!part || typeof part !== "object" || depth > 8) return false;
    if (Array.isArray(part))
      return part.length > 0 && part.every((item) => marker(item, depth + 1));
    const record = part as Record<string, unknown>;
    const keys = Object.keys(record);
    if (keys.length === 0 || record.isError === true) return false;
    if (keys.every((key) => key === "status" || key === "state"))
      return Object.values(record).every((item) => marker(item, depth + 1));
    if (keys.every((key) => key === "type" || key === "text") && record.type === "text")
      return marker(record.text, depth + 1);
    for (const wrapper of ["content", "result"]) {
      if (
        keys.every((key) => key === wrapper || key === "isError") &&
        wrapper in record &&
        (record.isError === undefined || record.isError === false)
      )
        return marker(record[wrapper], depth + 1);
    }
    return false;
  };
  return marker(value);
}
