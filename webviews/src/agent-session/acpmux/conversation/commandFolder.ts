// A shell call's leading `cd <folder> &&` steps are setup, not what it ran (Leo 2026-10-13, #20456):
// rows draw the command without them and the opened Shell block names the folder.

/// Leading `cd <dir> &&` steps split off: the last folder's last part, and the command that ran
/// there. Only a plain path counts: a `cd` whose folder could run code (`$(…)`, backticks, `$VAR`),
/// a `cd ..`, `cd ~` or `cd -`, a `;` step (its command runs even when the cd fails) or a command
/// that is only cd steps keeps its whole text, so nothing it ran is ever hidden.
export function commandFolder(command: string): { folder?: string; rest: string } {
  let rest = command;
  let dir: string | undefined;
  for (;;) {
    const match = /^\s*cd\s+("[^"$`\\]+"|'[^']+'|[\w./~@+:,-]+)\s*&&\s*/.exec(rest);
    if (!match) break;
    dir = match[1]!.replace(/^["']|["']$/g, "").replace(/\/+$/, "");
    rest = rest.slice(match[0].length);
  }
  const folder = dir?.split("/").at(-1);
  return folder && rest.trim() && !["~", ".", "..", "-"].includes(folder) ? { folder, rest } : { rest: command };
}
