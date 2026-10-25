// What a tray line says a running subagent or chat does now (SubagentTray.tsx): its status in words,
// never a raw shell line (Leo 2026-10-25 on a tray line reading "cd /Users/…/checkouts/… && sed -i
// …": "it's kind of wack"). Only a tool call's title is ever a command: a Claude subagent's action
// is its latest call's title, and a chat's doing line (sessionList.ts `doingLine`) is its plan step,
// prose that is never touched, then its latest call's title (`doingTool`). ACP titles every other
// call in words that start with a capital ("Read AgentCard.tsx", "Run cargo test"); a shell call's
// title is the command as typed, which starts with a lowercase program, a path or an assignment.
// That one reads "Running <program …>" (conversation/shortCommand.ts, the background-task note's
// short label); the whole text stays the line's tooltip.
import type { Translate } from "../i18n";
import { shortCommand } from "../conversation/shortCommand";

/// A command as a shell call's title starts: a lowercase program (`git`, `cd`, `./x`), a path
/// (`/opt/bin/x`, `~/bin/x`) or an assignment before one (`FOO=1 make`).
const COMMAND_START = /^(?:[a-z][\w.+-]*(?:\s|$)|(?:~|\.{1,2})?\/\S|[A-Za-z_][A-Za-z0-9_]*=)/;

/// Whether a tool call's title is a shell command rather than words about the call.
export function isCommandTitle(title: string): boolean {
  return COMMAND_START.test(title.trim());
}

/// The longest short command a line keeps; the row's CSS ellipsis cuts the rest of the line.
const COMMAND_MAX = 40;

/// A tool call's title in words: a command reads "Running <program …>", any other title as it is.
export function toolDetail(t: Translate, title: string | undefined): string | undefined {
  const trimmed = title?.trim();
  if (!trimmed) return undefined;
  if (!isCommandTitle(trimmed)) return trimmed;
  const command = shortCommand(trimmed, COMMAND_MAX);
  return command ? t("tools.runningCommand", { command }) : t("tools.runningUnnamed");
}

/// A chat's doing line in words: its plan step as it is, then its tool call's title in words. The
/// tool part is the end of the line acpmux joined (`step · tool`, or the tool alone).
export function doingDetail(t: Translate, doing: string | undefined, tool: string | undefined): string | undefined {
  if (!doing || !tool || !doing.endsWith(tool)) return doing;
  return doing.slice(0, doing.length - tool.length) + toolDetail(t, tool);
}
