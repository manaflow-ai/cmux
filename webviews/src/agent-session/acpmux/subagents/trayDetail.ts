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

/// Programs no tool title starts with in words: a title that starts with one is its command.
const PROGRAMS = new Set(
  (
    "cd export env sudo git gh bun bunx npm npx pnpm yarn node deno python python3 pip pip3 uv cargo " +
    "swift xcodebuild xcrun sed awk rg grep jq curl wget ssh scp rsync mkdir chmod tar docker zig ls " +
    "cmux-ci glaeda-gh bash zsh tmux plutil"
  ).split(" "),
);
/// Shell structure words do not have: an operator between steps, a flag, a path, an assignment or a
/// quoted argument.
const SHELL_SHAPED = /\s(?:&&|\|\||\||;|>>?|2>&1)\s|(?:^|\s)--?[A-Za-z]|(?:^|\s)(?:~|\.{0,2})\/\S|^\S+\s+\S*=|['"`$]/;

/// Whether a tool call's title is a shell command rather than words about the call: a shell
/// call's title (`shell`, its ACP kind is `execute`) that starts as a command does; without that
/// provenance (a chat's doing line, which carries no kind) it also needs a known program, a path,
/// an assignment or shell structure, so "find the issue" or "make a plan" stay words.
export function isCommandTitle(title: string, shell = false): boolean {
  const line = title.trim();
  if (!COMMAND_START.test(line)) return false;
  if (shell || !/^[a-z]/.test(line)) return true;
  return PROGRAMS.has(/^\S+/.exec(line)![0]) || SHELL_SHAPED.test(line);
}

/// The longest short command a line keeps; the row's CSS ellipsis cuts the rest of the line.
const COMMAND_MAX = 40;

/// A tool call's title in words: a command reads "Running <program …>", any other title as it is.
export function toolDetail(t: Translate, title: string | undefined, shell = false): string | undefined {
  const trimmed = title?.trim();
  if (!trimmed) return undefined;
  if (!isCommandTitle(trimmed, shell)) return trimmed;
  const command = shortCommand(trimmed, COMMAND_MAX);
  return command ? t("tools.runningCommand", { command }) : t("tools.runningUnnamed");
}

/// A chat's doing line in words: its plan step as it is, then its tool call's title in words. The
/// tool part is the end of the line acpmux joined (`step · tool`, or the tool alone).
export function doingDetail(t: Translate, doing: string | undefined, tool: string | undefined): string | undefined {
  if (!doing || !tool || !doing.endsWith(tool)) return doing;
  return doing.slice(0, doing.length - tool.length) + toolDetail(t, tool);
}
