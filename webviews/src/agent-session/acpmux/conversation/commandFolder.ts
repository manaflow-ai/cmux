// A shell call's leading `cd <folder> &&` steps are setup, not what it ran (Leo 2026-10-13, #20456):
// rows draw the command without them and the opened Shell block names the folder. A background
// task's note (shortCommand.ts) drops the same cd steps.

/// A `cd` whose folder is a plain path: quoted with no `$`, backtick or backslash, or bare path
/// characters. A folder that could run code (`$(…)`, backticks) or expand (`$VAR`) never matches.
const CD = /cd\s+("[^"$`\\]+"|'[^']+'|[\w./~@+:,-]+)/.source;
const LEADING_CD = new RegExp(`^\\s*${CD}\\s*&&\\s*`);
const PLAIN_CD = new RegExp(`^${CD}$`);

/// Whether one shell step is only a `cd` into a plain path, so leaving it out hides nothing it ran.
export function isPlainCd(step: string): boolean {
  return PLAIN_CD.test(step.trim());
}

/// Leading `cd <dir> &&` steps split off: the last folder's last part, and the command that ran
/// there. Only a plain path counts: a `cd` whose folder could run code (`$(…)`, backticks, `$VAR`),
/// a `cd ..`, `cd ~` or `cd -`, a `;` step (its command runs even when the cd fails) or a command
/// that is only cd steps keeps its whole text, so nothing it ran is ever hidden.
export function commandFolder(command: string): { folder?: string; rest: string } {
  let rest = command;
  let dir: string | undefined;
  for (;;) {
    const match = LEADING_CD.exec(rest);
    if (!match) break;
    dir = match[1]!.replace(/^["']|["']$/g, "").replace(/\/+$/, "");
    rest = rest.slice(match[0].length);
  }
  const folder = dir?.split("/").at(-1);
  return folder && rest.trim() && !["~", ".", "..", "-"].includes(folder) ? { folder, rest } : { rest: command };
}
