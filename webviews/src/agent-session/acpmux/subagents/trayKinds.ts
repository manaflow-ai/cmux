// The running tray's folded header by kind (trayFoldHead.experiment.ts `kinds`): what runs split by
// what kind of thing it is, each kind's count and how long its oldest has run, on one line,
// "2 subagents 4m / 1 server 12m / 2 waits 30s". Leo, 2026-11-03: "you can split up
// commands/waits/bg tasks/subagents/maybe agent sessions you expect something from and maybe more if
// you can think like what KINDS of background commands run... so you can fit that all in counts of
// stuff and maybe times all in one line like a \ b \ c or a | b| c or a / b / c".
import { acpmuxSend } from "../conversation/acpmuxSends";
import type { StringKey, Translate } from "../i18n";
import { servesCommand } from "../session-info/processes";
import { itemStart, type TrayItem } from "./runningTray";

/// What kind of background work a tray item is. A command is a server (it serves something, as
/// Session Info's Servers tell one), a wait (it waits on something else: CI, a run, a timer, a log),
/// a message to another agent whose reply it waits on (`acpmux send`), or any other command.
export type TrayKind = "subagent" | "chat" | "send" | "wait" | "server" | "command";

/// The kinds in the order the header names them: agents first, then the commands, the plain
/// command last.
export const TRAY_KINDS: readonly TrayKind[] = ["subagent", "chat", "send", "wait", "server", "command"];

/// A command that only waits: on CI or a run (`glaeda-gh wait`, `gh run watch`, `gh pr checks
/// --watch`), on another session (`acpmux wait`), on a timer or a condition (`sleep N`, `until`,
/// `while`, `wait`, `watch`) or on a log (`tail -f`). A wait word counts at a command's start or
/// after `;`, `&&`, `||`, `|` or `(`, so a path or an argument that holds one does not.
const WAIT_COMMAND = new RegExp(
  [
    String.raw`(?:^|[;&|(]\s*)(?:sleep\s+\d|until\s|while\s|wait(?:\s|$)|watch\s)`,
    String.raw`\b(?:glaeda-gh|acpmux)\s+wait\b`,
    String.raw`\bgh\s+run\s+watch\b`,
    String.raw`\bgh\s+pr\s+checks\b[^;&|]*\s--watch\b`,
    String.raw`\btail\s+(?:-\w+\s+)*-[a-zA-Z]*[fF]\b`,
  ].join("|"),
);

/// `item`'s kind. Only the command line decides a command's kind, never its description.
export function trayKindOf(item: TrayItem): TrayKind {
  if (item.kind === "agent") return "subagent";
  if (item.kind === "session") return "chat";
  const line = item.command.command.trim();
  if (acpmuxSend(line)) return "send";
  if (servesCommand(line)) return "server";
  if (WAIT_COMMAND.test(line)) return "wait";
  return "command";
}

/// One kind's part of the header: how many run and the oldest one's start (epoch ms), if known.
export type TrayKindCount = { kind: TrayKind; count: number; oldest: number | undefined };

/// What runs, counted by kind, in ``TRAY_KINDS`` order; kinds with nothing running are left out.
export function trayKindCounts(items: readonly TrayItem[]): TrayKindCount[] {
  const counts = new Map<TrayKind, TrayKindCount>();
  for (const item of items) {
    const kind = trayKindOf(item);
    const start = itemStart(item);
    const known = counts.get(kind);
    if (!known) counts.set(kind, { kind, count: 1, oldest: start });
    else {
      known.count += 1;
      if (start !== undefined && (known.oldest === undefined || start < known.oldest)) known.oldest = start;
    }
  }
  return TRAY_KINDS.flatMap((kind) => counts.get(kind) ?? []);
}

const KIND_LABEL: Record<TrayKind, StringKey> = {
  subagent: "subagents.count",
  chat: "turn.working.sessions",
  send: "tray.kind.sends",
  wait: "tray.kind.waits",
  server: "tray.kind.servers",
  command: "turn.working.commands",
};

/// The separator between kinds: a slash with a space either side, the lightest of the three Leo
/// offered ("a \ b \ c or a | b| c or a / b / c").
export const KIND_SEPARATOR = " / ";

/// The header's text by kind at `now`: each kind's count, then how long its oldest has run.
export function trayKindsText(
  t: Translate,
  counts: readonly TrayKindCount[],
  now: number,
  formatDuration: (ms: number) => string,
): string {
  return counts
    .map(({ kind, count, oldest }) => {
      const label = t(KIND_LABEL[kind], { n: count });
      return oldest === undefined ? label : `${label} ${formatDuration(Math.max(0, now - oldest))}`;
    })
    .join(KIND_SEPARATOR);
}
