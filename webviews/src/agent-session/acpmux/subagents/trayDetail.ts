// What a tray line says a subagent or a chat does now (SubagentTray.tsx): its status in words, never
// a raw shell line (Leo 2026-10-25 on a tray line reading "cd /Users/…/checkouts/… && sed -i …":
// "it's kind of wack"). acpmux's doing line (sessionList.ts `doingLine`) is a plan step, the latest
// tool or both ("step · tool"), and a shell call's tool is the command as typed; a Claude subagent's
// action is its latest call's title, which for a shell call is the command too. A part that reads
// as a command becomes "Running <program …>" (conversation/shortCommand.ts, the background-task
// note's short label); the whole text stays the line's tooltip.
import type { Translate } from "../i18n";
import { shortCommand } from "../conversation/shortCommand";

/// Programs a status line never starts with in prose: a part that does reads as a command.
const PROGRAMS = new Set(
  (
    "cd export env sudo git gh bun bunx npm npx pnpm yarn node deno python python3 pip pip3 uv cargo swift " +
    "xcodebuild make sed awk rg grep find ls cat head tail echo printf curl wget ssh scp rsync mv cp rm mkdir " +
    "touch chmod tar jq docker go zig reach codex claude acpmux cmux cmux-ci wt glaeda-gh bash sh zsh open " +
    "kill ps tmux security perl ruby defaults plutil xcrun"
  ).split(" "),
);
/// `FOO=1 cmd`: assignments before a program.
const ASSIGNED = /^[A-Za-z_][A-Za-z0-9_]*=\S*\s+\S/;
/// A program named by its path: `/opt/x/bin/tool`, `./script.sh`, `~/bin/x`.
const PATH_PROGRAM = /^(?:~|\.{1,2})?\/\S/;

/// Whether `text` is a shell command rather than words about one.
export function isShellLine(text: string): boolean {
  const line = text.trim();
  if (ASSIGNED.test(line) || PATH_PROGRAM.test(line)) return true;
  const first = /^\S+/.exec(line)?.[0] ?? "";
  return PROGRAMS.has(first);
}

/// The longest short command a line keeps; the row's CSS ellipsis cuts the rest of the line.
const COMMAND_MAX = 40;

function part(t: Translate, text: string): string {
  if (!isShellLine(text)) return text;
  const command = shortCommand(text, COMMAND_MAX);
  return command ? t("tools.runningCommand", { command }) : t("tools.runningUnnamed");
}

/// The line's detail: each part of the doing line in words. Undefined stays undefined.
export function trayDetail(t: Translate, text: string | undefined): string | undefined {
  const trimmed = text?.trim();
  if (!trimmed) return undefined;
  return trimmed
    .split(" · ")
    .map((piece) => part(t, piece))
    .join(" · ");
}
