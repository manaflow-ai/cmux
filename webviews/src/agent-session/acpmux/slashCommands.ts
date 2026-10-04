/// The agent's slash commands (ACP `available_commands_update`) and the
/// composer's `/` menu over them: the menu opens while the prompt is a single
/// `/word` at its start, filters by that word, and picking a command writes
/// `/name ` back so its arguments can follow.

export type SlashCommand = { name: string; description: string; hint?: string };

/// One menu row: the command and the ranges of its name the query matched.
export type SlashMatch = { command: SlashCommand; ranges: [number, number][] };

/// The commands in an ACP `available_commands_update`, or undefined when the
/// update is something else. Names are taken without a leading `/`.
export function commandsFromUpdate(update: any): SlashCommand[] | undefined {
  if (update?.sessionUpdate !== "available_commands_update" || !Array.isArray(update.availableCommands))
    return undefined;
  const commands: SlashCommand[] = [];
  for (const entry of update.availableCommands) {
    const name = typeof entry?.name === "string" ? entry.name.replace(/^\//, "").trim() : "";
    if (!name) continue;
    const hint = typeof entry.input?.hint === "string" && entry.input.hint.trim() ? entry.input.hint.trim() : undefined;
    commands.push({ name, description: typeof entry.description === "string" ? entry.description : "", hint });
  }
  return commands;
}

/// The query while the caret is in a leading `/word` (no space yet), else undefined.
export function slashQuery(text: string, caret: number): string | undefined {
  return /^\/(\S*)$/.exec(text.slice(0, caret))?.[1];
}

/// Commands matching `query`, best first: a name prefix, then a word start
/// inside the name, then any in-order subsequence; ties keep the agent's order.
export function matchCommands(commands: SlashCommand[], query: string): SlashMatch[] {
  const needle = query.toLowerCase();
  const scored: { match: SlashMatch; score: number; index: number }[] = [];
  commands.forEach((command, index) => {
    const name = command.name.toLowerCase();
    if (!needle) return scored.push({ match: { command, ranges: [] }, score: 0, index });
    if (name.startsWith(needle))
      return scored.push({ match: { command, ranges: [[0, needle.length]] }, score: 0, index });
    const word = wordStart(name, needle);
    if (word >= 0) return scored.push({ match: { command, ranges: [[word, word + needle.length]] }, score: 1, index });
    const ranges = subsequence(name, needle);
    if (ranges) scored.push({ match: { command, ranges }, score: 2, index });
  });
  return scored.sort((a, b) => a.score - b.score || a.index - b.index).map((entry) => entry.match);
}

/// Where `needle` starts a word of `name` after a `-`, `_`, `:`, `.` or `$`
/// (some agents list skills as `$name`), or -1.
function wordStart(name: string, needle: string): number {
  for (let at = name.indexOf(needle, 1); at > 0; at = name.indexOf(needle, at + 1)) {
    if ("-_:.$".includes(name[at - 1])) return at;
  }
  return -1;
}

/// `needle`'s characters in order within `name`, merged into ranges, or undefined.
function subsequence(name: string, needle: string): [number, number][] | undefined {
  const ranges: [number, number][] = [];
  let from = 0;
  for (const char of needle) {
    const at = name.indexOf(char, from);
    if (at < 0) return undefined;
    const last = ranges[ranges.length - 1];
    if (last && last[1] === at) last[1] = at + 1;
    else ranges.push([at, at + 1]);
    from = at + 1;
  }
  return ranges;
}

/// The prompt after picking `command`: `/name ` replacing the typed `/word`.
export function applyCommand(text: string, caret: number, command: SlashCommand): { text: string; caret: number } {
  const inserted = `/${command.name} `;
  const rest = text.slice(caret).replace(/^\S*\s?/, "");
  return { text: inserted + rest, caret: inserted.length };
}
