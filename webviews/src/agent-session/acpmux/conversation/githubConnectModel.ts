import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { parseJSONValue } from "./toolResult";

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

/** Only the GitHub bridge's explicit retryable refusal, never prose or an action supplied by a tool. */
export function needsGitHubConnection(tool: NonNullable<AcpmuxActivity["tool"]>): boolean {
  if (mcpCall(tool)?.server !== "github" || !tool.output || tool.output.length > 64_000) return false;
  const envelope = record(parseJSONValue(tool.output));
  // Some harnesses keep the JSON-RPC result envelope around the MCP result.
  const result = record(envelope?.result) ?? envelope;
  const error = record(record(result?.structuredContent)?.error);
  return (
    result?.isError === true &&
    error?.code === "github.not_connected" &&
    error.retryable === true &&
    record(error.connect)?.action === "accounts.githubConnect"
  );
}
