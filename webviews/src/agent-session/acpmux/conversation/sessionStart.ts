// What a Claude Code chat runs on, noted once where its session started (acpmux's
// `session_info_update`, from Claude Code's system/init line): its version and model, the route
// it reaches Claude through, and its folder. The pane showed none of it before,
// while the Claude Code TUI opens with the same facts in its banner.
import type { AcpmuxSessionStart } from "../model";

/// sr2's harness (`~/.config/cmux/harnesses/claude-sr2.toml`).
export const SR2_HARNESS = "claude-sr2";

/// Which way the chat reaches Claude: sr2's gateway, the configured CodeRouter route, or the
/// person's own Claude Code setup (their `claude` and its settings).
export type ClaudeRoute = "sr2" | "coderouter" | "own";

export function routeOf(harness: string | undefined): ClaudeRoute {
  if (harness === SR2_HARNESS) return "sr2";
  if (harness === "claude-cr") return "coderouter";
  return "own";
}

/// A session start from a `session_info_update`, or nil when it is not Claude Code's
/// (`_meta.claude.version` names it; Codex's carry `_meta.codex`).
export function sessionStartOf(
  update: Record<string, any> | undefined,
  context: { harness?: unknown; cwd?: unknown },
): AcpmuxSessionStart | undefined {
  const claude = update?._meta?.claude;
  if (!claude || typeof claude.version !== "string" || !claude.version) return undefined;
  return {
    agent: "claude",
    version: claude.version,
    ...(typeof claude.model === "string" && claude.model ? { model: claude.model } : {}),
    ...(typeof context.harness === "string" && context.harness ? { harness: context.harness } : {}),
    ...(typeof context.cwd === "string" && context.cwd ? { cwd: context.cwd } : {}),
  };
}

export function sameSessionStart(a: AcpmuxSessionStart | undefined, b: AcpmuxSessionStart): boolean {
  return (
    a !== undefined && a.version === b.version && a.model === b.model && a.harness === b.harness && a.cwd === b.cwd
  );
}

/// /Users/me/x -> ~/x, /home/me/x -> ~/x; anything else as is.
export function foldHome(cwd: string): string {
  const parts = cwd
    .replace(/(.)\/+$/, "$1")
    .split("/")
    .filter(Boolean);
  if ((parts[0] === "Users" || parts[0] === "home") && parts.length >= 2) return ["~", ...parts.slice(2)].join("/");
  return cwd;
}
