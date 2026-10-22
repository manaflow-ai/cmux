// Primitives shared by the cmux Cloud MCP protocol layer (`cloudMcp.ts`) and
// its tool modules, kept apart so the modules can import each other's values
// without an initialization cycle.

export const CLOUD_MCP_AGENTS = ["claude", "codex", "opencode", "pi"] as const;
export type CloudMcpAgent = (typeof CLOUD_MCP_AGENTS)[number];

/** A failure the caller should see as a tool error, e.g. an unknown or unowned machine. */
export class CloudMcpToolError extends Error {
  constructor(
    readonly code: string,
    message: string,
    /** Extra machine-readable fields for `structuredContent`, e.g. `plan_info_url`. */
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
  }
}
