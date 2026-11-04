// Presentation-only reductions. Original calls remain available to Find, copy and export.
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

// Only the harness's successful discovery operation is noise; never hide a server's similarly
// named user operation, a pending permission, a failed discovery, or an error returned as success.
export function isToolDiscoveryNoise(tool: Tool | undefined): boolean {
  if (!tool || tool.status !== "completed" || tool.command || tool.diffs?.length || tool.images?.length || tool.background || tool.approved)
    return false;
  if (mcpCall(tool) || !/^(?:ToolSearch|tool_search|load_tools)$/.test(tool.title)) return false;
  if ((tool.exitCode ?? 0) !== 0 || /(?:"(?:isError|error)"\s*:\s*(?!(?:false|null|0)\s*[,}])\S|"(?:status|state)"\s*:\s*"(?:error|failed)"|^(?:error|failed|unable|unavailable)\b)/im.test(tool.output ?? ""))
    return false;
  return true;
}

export function usefulMcpRequest(args: unknown): { command?: string; context?: string } {
  if (!args || typeof args !== "object" || Array.isArray(args)) return {};
  const values = args as Record<string, unknown>;
  const command = [values.command, values.cmd].find((value): value is string => typeof value === "string" && !!value.trim());
  if (command) return { command };
  const context = [values.paths ?? values.path ?? values.file_path ?? values.url, values.pattern ?? values.query]
    .flatMap((value) => Array.isArray(value) ? value : [value])
    .filter((value): value is string => typeof value === "string" && !!value.trim())
    .join("\n");
  return context ? { context } : {};
}

// A bare lifecycle placeholder isn't output. Restrict this to an exact whole response, so logs
// containing the same words and genuine data are never shortened or discarded.
export function usefulMcpResponse(text: string | undefined): string | undefined {
  if (!text?.trim() || /^(?:waiting|running|pending)(?:\.{3}|…)?$/i.test(text.trim())) return undefined;
  let value: unknown;
  try { value = JSON.parse(text); } catch { return text; }
  const human = (part: unknown, depth: number): string[] => {
    if (depth > 8) return [JSON.stringify(part) ?? String(part)];
    if (typeof part === "string") return [part];
    if (part === null || typeof part === "number" || typeof part === "boolean") return [String(part)];
    if (Array.isArray(part)) return part.flatMap((item) => human(item, depth + 1));
    if (!part || typeof part !== "object") return [];
    const record = part as Record<string, unknown>;
    const proseKeys = ["text", "message", "detail", "reason", "error", "output", "stdout", "stderr", "content", "matches", "results", "data"];
    const body = proseKeys.flatMap((key) => human(record[key], depth + 1));
    const path = record.path ?? record.file;
    const extras = Object.entries(record)
      .filter(([key, item]) => !proseKeys.includes(key) &&
        !["type", "isError", "mimeType", "_meta"].includes(key) &&
        !(typeof path === "string" && body.length && ["path", "file", "line"].includes(key)) &&
        !(["status", "state"].includes(key) && typeof item === "string" && /^(?:waiting|running|pending)$/i.test(item)))
      .flatMap(([key, item]) => {
        const label = key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ");
        return human(item, depth + 1).map((line) => `${label}: ${line}`);
      });
    const lines = [...body, ...extras];
    return typeof path === "string" && body.length
      ? lines.map((line) => `${path}${typeof record.line === "number" ? `:${record.line}` : ""}: ${line}`)
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
  let value: unknown = output;
  try { value = JSON.parse(output); } catch { /* Plain text is the usual case. */ }
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    if (Object.keys(record).every((key) => key === "status" || key === "state")) value = record.status ?? record.state;
  }
  return typeof value === "string" && /^(?:waiting|running|pending)(?:\.{3}|…)?$/i.test(value.trim());
}
