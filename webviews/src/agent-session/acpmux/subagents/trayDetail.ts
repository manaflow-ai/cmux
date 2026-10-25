// What a tray line says a running subagent or chat does now (SubagentTray.tsx): its status in words,
// never a raw shell line (Leo 2026-10-25 on a tray line reading "cd /Users/…/checkouts/… && sed -i
// …": "it's kind of wack"). acpmux's doing line (sessionList.ts `doingLine`) is a plan step, the
// latest tool or both ("step · tool"), and a shell call's tool is the command as typed; a Claude
// subagent's action is its latest call's title, which for a shell call is the command too. A part
// that reads as a command becomes "Running <program …>" (conversation/shortCommand.ts, the
// background-task note's short label); the whole text stays the line's tooltip.
import type { Translate } from "../i18n";
import { shortCommand } from "../conversation/shortCommand";

/// Programs no status line starts with in prose: a part that starts with one is a command.
const PROGRAMS = new Set(
  (
    "cd export env sudo git gh bun bunx npm npx pnpm yarn node deno python python3 pip pip3 uv cargo " +
    "swift xcodebuild xcrun sed awk rg grep jq curl wget ssh scp rsync mkdir chmod tar docker zig cmux-ci " +
    "glaeda-gh bash zsh tmux plutil"
  ).split(" "),
);
/// Words a status line may start with in prose ("Find the bug", "Make a plan", "Open the file"): a
/// part that starts with one is a command only when the rest looks like shell (``SHELL_SHAPED``).
const AMBIGUOUS = new Set(
  (
    "find make open touch kill go head tail cat echo ls cp mv rm sh ps test time which reach codex claude " +
    "acpmux cmux wt security defaults perl ruby printf"
  ).split(" "),
);
/// Shell structure prose does not have: an operator between steps, a flag, a path, an assignment
/// or a quoted argument.
const SHELL_SHAPED = /\s(?:&&|\|\||\||;|>>?|2>&1)\s|(?:^|\s)--?[A-Za-z]|(?:^|\s)(?:~|\.{0,2})\/\S|^\S+\s+\S*=|["`$]/;
/// `FOO=1 cmd`: assignments before a program.
const ASSIGNED = /^[A-Za-z_][A-Za-z0-9_]*=\S*\s+\S/;
/// A program named by its path: `/opt/x/bin/tool`, `./script.sh`, `~/bin/x`.
const PATH_PROGRAM = /^(?:~|\.{1,2})?\/\S/;
/// Steps joined as a shell joins them, whatever the program (`cd x && terraform plan`).
const JOINED = /\s(?:&&|\|\|)\s/;

/// Whether `text` is a shell command rather than words about one.
export function isShellLine(text: string): boolean {
  const line = text.trim();
  if (ASSIGNED.test(line) || PATH_PROGRAM.test(line) || JOINED.test(line)) return true;
  const first = /^\S+/.exec(line)?.[0] ?? "";
  if (PROGRAMS.has(first)) return true;
  return AMBIGUOUS.has(first) && SHELL_SHAPED.test(line);
}

/// The longest short command a line keeps; the row's CSS ellipsis cuts the rest of the line.
const COMMAND_MAX = 40;

/// acpmux joins a doing line's step and tool with " · "; one inside a quoted argument is the
/// command's own text, so the line splits only outside quotes. An unclosed quote quotes nothing.
function parts(text: string): string[] {
  const out: string[] = [];
  let quote: string | undefined;
  let start = 0;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]!;
    // A quote opens only where an argument starts: an apostrophe inside a word ("card's") is prose.
    const opens = (char === '"' || char === "'" || char === "`") && /[\s=]/.test(text[index - 1] ?? " ");
    if (quote) {
      if (char === quote) quote = undefined;
    } else if (opens) quote = char;
    else if (text.startsWith(" · ", index)) {
      out.push(text.slice(start, index));
      start = index + 3;
      index += 2;
    }
  }
  out.push(text.slice(start));
  return quote ? text.split(" · ") : out;
}

function part(t: Translate, text: string): string {
  if (!isShellLine(text)) return text;
  const command = shortCommand(text, COMMAND_MAX);
  return command ? t("tools.runningCommand", { command }) : t("tools.runningUnnamed");
}

/// The line's detail: each part of a running doing line in words. Undefined stays undefined.
export function trayDetail(t: Translate, text: string | undefined): string | undefined {
  const trimmed = text?.trim();
  if (!trimmed) return undefined;
  return parts(trimmed)
    .map((piece) => part(t, piece))
    .join(" · ");
}
