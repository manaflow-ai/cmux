// Where inside a machine a request came from: the cmux-tui workspace and
// terminal (surface) whose environment launched the agent. cmux-tui exports
// CMUX_WORKSPACE_ID and CMUX_SURFACE_ID into every terminal; agent-config.sh
// in the guest turns them into these two headers (Claude Code through
// ANTHROPIC_CUSTOM_HEADERS, Codex through env_http_headers). The ids are
// opaque attribution keys only; a missing or malformed header is null.
export const WORKSPACE_ID_HEADER = "x-cmux-workspace-id";
export const SURFACE_ID_HEADER = "x-cmux-surface-id";

const ORIGIN_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,128}$/;

export type UsageOrigin = {
  readonly workspaceId: string | null;
  readonly surfaceId: string | null;
};

export function usageOriginFromHeaders(headers: Headers): UsageOrigin {
  return {
    workspaceId: originId(headers.get(WORKSPACE_ID_HEADER)),
    surfaceId: originId(headers.get(SURFACE_ID_HEADER)),
  };
}

function originId(value: string | null): string | null {
  const trimmed = value?.trim() ?? "";
  return ORIGIN_ID_PATTERN.test(trimmed) ? trimmed : null;
}
