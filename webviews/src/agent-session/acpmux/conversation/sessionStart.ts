// What a Claude Code chat runs on (acpmux's `session_info_update`, from Claude Code's system/init
// line on every turn): its version and model, the route it reaches Claude through, and its folder.
// Session Info's Environment and the /status card hold them; the transcript draws a line only
// where a turn's model or route changes from the turn before (Leo, 2026-11-05: "why does it even
// show that ... like we know what it is ... giving tmi").
import type { Translate } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { modelIdName } from "../defaultChoice";

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

/// Whether two init lines run the chat on the same model and route: a new version or folder alone
/// tells the reader nothing in the transcript (Session Info keeps them).
export function sameRun(a: AcpmuxSessionStart, b: AcpmuxSessionStart): boolean {
  return a.model === b.model && routeOf(a.harness) === routeOf(b.harness);
}

/// Where a chat's init lines change its model or route, in seq order: the first line, then each one
/// that differs from the line before it. Inserting a line (live, or from an older page that lands
/// later) keeps that true, so the list stays as short as the chat's changes.
export type RunChange = { seq: number; at: number; start: AcpmuxSessionStart };

export function insertRunChange(changes: RunChange[], change: RunChange): boolean {
  let at = changes.length;
  while (at > 0 && changes[at - 1]!.seq > change.seq) at -= 1;
  const before = changes[at - 1];
  if (before?.seq === change.seq) {
    if (sameSessionStart(before.start, change.start)) return false;
    changes[at - 1] = change;
    return true;
  }
  // The same run as the line before: nothing changed here. A point's facts are those of the line
  // that started its run; what the chat runs on now is the newest line (direct.ts `latestStart`).
  if (before && sameRun(before.start, change.start)) return false;
  changes.splice(at, 0, change);
  // The next change point may now be the same run as this line: it is no change any more.
  const after = changes[at + 1];
  if (after && sameRun(after.start, change.start)) changes.splice(at + 1, 1);
  return true;
}

/// A start's short line ("Claude Code · Opus 5.5 · sr2") and its whole facts (version, model id,
/// route, folder), as the transcript's change line and Session Info both say them.
export function sessionStartLabels(start: AcpmuxSessionStart, t: Translate): { short: string; facts: string } {
  const route = routeOf(start.harness);
  const short = [
    t("sessionStart.agent"),
    start.model ? modelIdName(start.model, t) : undefined,
    route === "sr2"
      ? t("sessionStart.routeShort.sr2")
      : route === "coderouter"
        ? t("sessionStart.routeShort.coderouter")
        : undefined,
  ].filter((fact): fact is string => !!fact);
  const facts = [
    t("sessionStart.claudeCode", { version: start.version }),
    start.model,
    route === "sr2"
      ? t("sessionStart.route.sr2")
      : route === "coderouter"
        ? t("sessionStart.route.coderouter")
        : t("sessionStart.route.own"),
    start.cwd ? foldHome(start.cwd) : undefined,
  ].filter((fact): fact is string => !!fact);
  return { short: short.join(" · "), facts: facts.join(" · ") };
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
