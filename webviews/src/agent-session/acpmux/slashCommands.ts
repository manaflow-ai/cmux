/// The agent's slash commands (ACP `available_commands_update`) and the
/// composer's `/` menu over them: the menu opens while the caret ends a `/word`
/// at the prompt's start or after a space or line break, filters by that word,
/// and picking a command writes `/name ` over it so its arguments can follow.
/// Mid-prompt (text before the `/`) it lists only the commands that go to the
/// agent as text, as Codex and Claude Code desktop let a skill be named anywhere.

import { useRef } from "react";
import type { StringKey } from "./i18n";

export type SlashCommand = {
  name: string;
  description: string;
  /** A pane string that replaces `description`, for commands cmux owns. */
  descriptionKey?: StringKey;
  hint?: string;
  /** Where the command came from. Harness commands are the default for old snapshots. */
  source?: "agent" | "cmux" | "skill" | "prompt";
};

/// One menu row: the command and the ranges of its name the query matched.
export type SlashMatch = { command: SlashCommand; ranges: [number, number][] };

/// The commands in an ACP `available_commands_update`, or undefined when the
/// update is something else. Names are taken without a leading `/`.
export function commandsFromUpdate(update: any): SlashCommand[] | undefined {
  if (update?.sessionUpdate !== "available_commands_update" || !Array.isArray(update.availableCommands))
    return undefined;
  const commands: SlashCommand[] = [];
  for (const entry of update.availableCommands) {
    // Harness commands, skills and prompts share this update, one picker and one
    // insertion path. A skill or prompt may carry `_meta.kind`, ACP's extension slot
    // (acpmux tags Claude's skills so, from its system/init `skills`). codex-acp names a
    // skill `$name` and passes `/$name` through to Codex as a skill mention, so only a
    // leading `/` is dropped.
    const name = typeof entry?.name === "string" ? entry.name.replace(/^\//, "").trim() : "";
    if (!name) continue;
    const hint = typeof entry.input?.hint === "string" && entry.input.hint.trim() ? entry.input.hint.trim() : undefined;
    commands.push({
      name,
      description: typeof entry.description === "string" ? entry.description : "",
      hint,
      source:
        name.startsWith("$") || entry?._meta?.kind === "skill" || entry?.kind === "skill" || entry?.source === "skill"
          ? "skill"
          : entry?._meta?.kind === "prompt" || entry?.kind === "prompt" || entry?.source === "prompt"
            ? "prompt"
            : "agent",
    });
  }
  return commands;
}

/// The name the prompt and the menu use: a Codex skill's without its `$` (codex-acp lists one as
/// `$name`). The person reads and types `/emil-color`; send writes `/$emil-color` back
/// (`withSkillDollars`), which Codex needs to take it as a skill.
export const shownName = (command: SlashCommand) => command.name.replace(/^\$(?=.)/, "");

/// The Codex skills of a command list by the name the prompt shows (`dollar`: `$emil-color` is
/// `emil-color`), and the names other commands have (`plain`), for the `$` the prompt adds and takes
/// away. Only names in the list count: a `/$source` or `/$5` someone typed is never taken for one.
export type SkillCatalog = { dollar: ReadonlySet<string>; plain: ReadonlySet<string> };

export function skillCatalog(commands: readonly SlashCommand[] | undefined): SkillCatalog {
  const dollar = new Set<string>();
  const plain = new Set<string>();
  for (const command of commands ?? [])
    if (command.name.length > 1 && command.name.startsWith("$")) dollar.add(command.name.slice(1));
    else plain.add(command.name);
  return { dollar, plain };
}

const catalogOf = (commands: readonly SlashCommand[] | SkillCatalog | undefined): SkillCatalog =>
  commands && !Array.isArray(commands) ? (commands as SkillCatalog) : skillCatalog(commands as SlashCommand[]);

/// A fenced code block's opening line at a line start: up to three spaces, then three or more
/// backticks or tildes, to the line's end (`\n`, `\r\n` or a lone `\r`).
const FENCE_OPEN = /( {0,3})(`{3,}|~{3,})[^\r\n]*/y;

/// A `/word` of a prompt in a command position: where it starts and ends in the text, the word
/// without its `/`, and whether it sits in Markdown code. `region` says which code: a fence of
/// backticks (`loose` when its info string holds a backtick, which the transcript's renderer opens no
/// fence for), of tildes, or an inline span of one backtick or of more.
export type CommandWord = {
  start: number;
  end: number;
  word: string;
  code: boolean;
  region?: "backticks" | "loose" | "tildes" | "span" | "spans";
};

/// A `/word` inside a stretch of code, for `commandWords`' `inCode`.
const CODE_WORD = /(^|[\s\uFFFC`])\/([^\s\uFFFC`]+)(?=[\s\uFFFC`]|$)/g;

/// The `/word`s of `text` in a command position (the text's start, or after a space, a line break
/// or an attachment, running to the next), in order. The one reading of Markdown code that the
/// send mapping, the display mapping and the skill highlights share: a fenced block (backticks or
/// tildes, to its closing fence after `\n`, `\r\n` or `\r`, or the end) and an inline code span of
/// any backtick run (closed by a run of the same length; an unclosed run is literal) are code. Their
/// words come only with `inCode` (`code` true). One pass: a run length with no closer further on is
/// remembered, so no span is searched for twice.
export function commandWords(text: string, inCode = false): CommandWord[] {
  const words: CommandWord[] = [];
  if (!text.includes("/")) return words;
  const codeWords = (from: number, to: number, region: NonNullable<CommandWord["region"]>) => {
    if (!inCode || to <= from) return;
    for (const found of text.slice(from, to).matchAll(CODE_WORD)) {
      const start = from + found.index! + found[1]!.length;
      words.push({ start, end: start + found[2]!.length + 1, word: found[2]!, code: true, region });
    }
  };
  const unclosed = new Set<number>();
  const length = text.length;
  let at = 0;
  while (at < length) {
    const char = text[at]!;
    const lineStart = at === 0 || text[at - 1] === "\n" || text[at - 1] === "\r";
    if (lineStart && (char === " " || char === "`" || char === "~")) {
      FENCE_OPEN.lastIndex = at;
      const fence = FENCE_OPEN.exec(text);
      if (fence) {
        const mark = fence[2]!;
        const close = new RegExp(
          `(?:\\r\\n|\\r|\\n) {0,3}${mark[0] === "`" ? "`" : "~"}{${mark.length},}[ \\t]*(?=\\r|\\n|$)`,
          "g",
        );
        close.lastIndex = at + fence[0].length;
        const found = close.exec(text);
        const end = found ? found.index + found[0].length : length;
        const region =
          mark[0] === "~"
            ? "tildes"
            : fence[0].slice(fence[1]!.length + mark.length).includes("`")
              ? "loose"
              : "backticks";
        codeWords(at + fence[0].length, found ? found.index : length, region);
        at = end;
        continue;
      }
    }
    if (char === "`") {
      let end = at;
      while (text[end] === "`") end++;
      const run = end - at;
      at = end;
      if (unclosed.has(run)) continue;
      // The next run of exactly `run` backticks closes the span.
      for (let from = end; ;) {
        const next = text.indexOf("`".repeat(run), from);
        if (next < 0) {
          unclosed.add(run);
          break;
        }
        let stop = next;
        while (text[stop] === "`") stop++;
        if (stop - next === run && text[next - 1] !== "`") {
          codeWords(end, next, run === 1 ? "span" : "spans");
          at = stop;
          break;
        }
        from = stop;
      }
      continue;
    }
    if (char === "/" && (at === 0 || isSlashBoundary(text[at - 1]))) {
      let end = at + 1;
      while (end < length && !isSlashBoundary(text[end]) && text[end] !== "`") end++;
      if (end > at + 1 && (end === length || isSlashBoundary(text[end])))
        words.push({ start: at, end, word: text.slice(at + 1, end), code: false });
      at = end;
      continue;
    }
    at++;
  }
  return words;
}

/// `text` with each `/word` outside code (`commandWords`) that `visit` rewrites replaced, the rest
/// as it is.
function mapCommandWords(text: string, visit: (word: string) => string | undefined): string {
  let out = "";
  let copied = 0;
  for (const { start, end, word } of commandWords(text)) {
    const written = visit(word);
    if (written === undefined) continue;
    out += text.slice(copied, start) + written;
    copied = end;
  }
  return copied ? out + text.slice(copied) : text;
}

/// The prompt as sent: each `/name` in a command position outside code that names a Codex skill
/// without its `$` is written `/$name`, as codex-acp needs. When a command also has that name
/// without `$`, the word is that command's unless the person picked the skill in this draft
/// (`picked`, by shown name): typed text stays as typed. Every other character stays.
export function withSkillDollars(
  text: string,
  commands: readonly SlashCommand[] | SkillCatalog | undefined,
  picked?: ReadonlySet<string>,
): string {
  const catalog = catalogOf(commands);
  if (!catalog.dollar.size) return text;
  return mapCommandWords(text, (name) =>
    catalog.dollar.has(name) && (!catalog.plain.has(name) || picked?.has(name)) ? `/$${name}` : undefined,
  );
}

/// A sent prompt as the person reads it: each `/$name` outside code that names a Codex skill of the
/// list reads `/name`, as it was typed (`withSkillDollars` wrote the `$`). For display, copy and
/// putting the prompt back in a field only; the stored and sent text keep the `$`.
export function withoutSkillDollars(
  text: string,
  commands: readonly SlashCommand[] | SkillCatalog | undefined,
): string {
  if (!text.includes("/$")) return text;
  const catalog = catalogOf(commands);
  if (!catalog.dollar.size) return text;
  return mapCommandWords(text, (word) =>
    word.startsWith("$") && catalog.dollar.has(word.slice(1)) ? `/${word.slice(1)}` : undefined,
  );
}

/// The Codex skills a sent prompt names as `/$name` (outside code, in the list), by shown name: put
/// back in an editor without its `$`, the prompt goes out with them again even where a command
/// shares the name (`withSkillDollars` `picked`).
export function pickedSkillsOf(
  text: string,
  commands: readonly SlashCommand[] | SkillCatalog | undefined,
): Set<string> {
  const picked = new Set<string>();
  if (!text.includes("/$")) return picked;
  const catalog = catalogOf(commands);
  mapCommandWords(text, (word) => {
    if (word.startsWith("$") && catalog.dollar.has(word.slice(1))) picked.add(word.slice(1));
    return undefined;
  });
  return picked;
}

/// Whether `command` is the harness's own `/fast` (Claude Code lists it as "Toggle fast mode"). The
/// `/` menu draws it as ChatGPT does (Leo 2026-10-22): the bolt, the plain name Fast, and what
/// picking it does in the chat's current state (fastModeState).
export function isFastCommand(command: SlashCommand): boolean {
  return (command.source ?? "agent") === "agent" && command.name.toLowerCase() === "fast";
}

type FastOption = { id: string; name?: string; currentValue?: string; options: { value: string }[] };

/// The chat's fast mode, from its config options as the model menu reads them (ComposerPickers.tsx):
/// Claude Code's `fast-mode`, or an option named for it. Undefined when the session reports none or
/// no current value.
export function fastModeState(options: readonly FastOption[] | undefined): "on" | "off" | undefined {
  const option = options?.find((entry) => entry.id === "fast-mode" || /fast[ _-]?mode/i.test(entry.name ?? ""));
  if (!option || option.currentValue === undefined) return undefined;
  const off =
    option.options.find((choice) => /^(off|false|disabled)$/i.test(choice.value))?.value ?? option.options[0]?.value;
  return option.currentValue === off ? "off" : "on";
}

/// The `/word` the caret ends: `query` is what follows the `/`, `length` counts from the `/` to the
/// caret, and `leading` says the word starts the prompt as send reads it (attachments placed
/// before it and blank lines or spaces do not count: send takes them out and trims).
export type SlashTrigger = { query: string; length: number; leading: boolean };

/// Longer words are never commands; the trigger and the token colour read no further back.
export const SLASH_WORD_MAX = 256;

/// What ends a command word: whitespace (a line break too) or an attachment placed in the text,
/// which the editor reads as U+FFFC.
export const isSlashBoundary = (char: string | undefined) => char === "\uFFFC" || (!!char && /\s/.test(char));

/// The `/word` ending at the caret, from `before`, the text before the caret in its block (only its
/// last SLASH_WORD_MAX + 1 characters are read), or undefined. The `/` starts the block or follows
/// whitespace: one inside a word or a path (`src/app`, `http://x/y`) opens nothing. `lead`: where in
/// `before` the prompt's first word starts (composer/slashTokens.ts promptLead), undefined when not
/// in it. Mid-prompt a second `/` makes the word a path (`/usr/local`), not a command.
export function slashTrigger(before: string, lead: number | undefined): SlashTrigger | undefined {
  let start = before.length;
  const floor = Math.max(0, before.length - SLASH_WORD_MAX - 1);
  while (start > floor && !isSlashBoundary(before[start - 1])) start--;
  // A word that fills the whole window is longer than any command.
  if (before[start] !== "/" || before.length - start > SLASH_WORD_MAX) return undefined;
  const query = before.slice(start + 1);
  const leading = start === lead;
  if (!leading && query.includes("/")) return undefined;
  return { query, length: query.length + 1, leading };
}

/// Whether the agent reads `command` wherever it sits in the prompt: a skill or a prompt. Claude
/// Code and Codex run their built-in commands (`/compact`, `/init`, `/review`) only from the prompt's
/// start, and cmux runs its own only there (Composer `send`). acpmux tags Claude's skills and
/// codex-acp names Codex's `$name` (commandsFromUpdate), so an untagged command of the agent's is a
/// built-in or a command that runs only at the start; for another harness the list cannot tell a
/// skill from a built-in. So every untagged command stays start-of-prompt only.
export const goesAsText = (command: SlashCommand) => command.source === "skill" || command.source === "prompt";

/// The menu's rows for `trigger`: every command at the prompt's start, the ones that go as text
/// mid-prompt.
export function slashMatches(commands: readonly SlashCommand[], trigger: SlashTrigger): SlashMatch[] {
  return matchCommands(trigger.leading ? [...commands] : commands.filter(goesAsText), trigger.query);
}

/// The names a `/name` word is a command by: `anywhere` mid-prompt, `leading` at the prompt's start.
/// `descriptions`: each skill's and prompt's description by name, which its word shows on hover.
export type SlashNames = {
  leading: ReadonlySet<string>;
  anywhere: ReadonlySet<string>;
  descriptions?: ReadonlyMap<string, string>;
};

export function slashNames(commands: readonly SlashCommand[] | undefined): SlashNames {
  const list = commands ?? [];
  // A `$` skill by the name the prompt shows (`/emil-color`) and by its own (`/$emil-color`).
  const names = (each: readonly SlashCommand[]) => each.flatMap((command) => [command.name, shownName(command)]);
  const descriptions = new Map<string, string>();
  for (const command of list.filter(goesAsText)) {
    const description = command.description.trim();
    if (!description) continue;
    descriptions.set(command.name, description);
    descriptions.set(shownName(command), description);
  }
  return { leading: new Set(names(list)), anywhere: new Set(names(list.filter(goesAsText))), descriptions };
}

/// `slashNames` kept while the list's names and kinds are the same: a chat's snapshot rebuilds its
/// list on every update, and the prompt recolours only when the names change.
export function useSlashNames(commands: readonly SlashCommand[] | undefined): SlashNames {
  const key = (commands ?? [])
    .map(
      (command) =>
        `${goesAsText(command) ? "a" : "c"}${command.name}\u0000${goesAsText(command) ? command.description : ""}`,
    )
    .join("\n");
  const kept = useRef<{ key: string; names: SlashNames }>(undefined);
  if (kept.current?.key !== key) kept.current = { key, names: slashNames(commands) };
  return kept.current.names;
}

/// The command words in `text`, one text block: each `/name` that starts the block or follows a
/// boundary and runs to the next, whose name `names` allows there. `lead`: where the prompt's first
/// word starts in `text`, where every command counts. `from`/`to` limit the scan to the words
/// touching that span; a word cut by the text's start or end (`cutStart`/`cutEnd`) is not read.
export function slashTokens(
  text: string,
  names: SlashNames,
  {
    lead,
    from = 0,
    to = text.length,
    cutStart = false,
    cutEnd = false,
  }: { lead?: number; from?: number; to?: number; cutStart?: boolean; cutEnd?: boolean } = {},
): { from: number; to: number; tokens: [number, number][] } {
  let left = Math.max(0, Math.min(from, text.length));
  while (left > 0 && !isSlashBoundary(text[left - 1])) left--;
  let right = Math.max(left, Math.min(to, text.length));
  while (right < text.length && !isSlashBoundary(text[right])) right++;
  const tokens: [number, number][] = [];
  for (let start = left; start < right;) {
    if (isSlashBoundary(text[start])) {
      start++;
      continue;
    }
    let end = start;
    while (end < right && !isSlashBoundary(text[end])) end++;
    const cut = (start === 0 && cutStart) || (end === text.length && cutEnd);
    if (!cut && text[start] === "/" && end - start <= SLASH_WORD_MAX) {
      const name = text.slice(start + 1, end);
      if (name && (names.anywhere.has(name) || (start === lead && names.leading.has(name)))) tokens.push([start, end]);
    }
    start = end;
  }
  return { from: left, to: right, tokens };
}

/// Commands matching `query`, best first: a name prefix, then a word start
/// inside the name, then any in-order subsequence; ties keep the agent's order. Names are read as
/// the menu shows them (`shownName`, a Codex skill without its `$`), and the ranges index that name;
/// a `$` typed first is skipped too.
export function matchCommands(commands: SlashCommand[], query: string): SlashMatch[] {
  const needle = query.replace(/^\$/, "").toLowerCase();
  const scored: { match: SlashMatch; score: number; index: number }[] = [];
  commands.forEach((command, index) => {
    const name = shownName(command).toLowerCase();
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

/// What picking `name` writes over `trigger`'s `/word`: `back` characters before the caret and
/// `forward` after it (the rest of the word and one space or tab) become `text`, `/name `. What
/// came before and after stays; a line break or attachment after the word is kept. `cut`: `after`
/// stops short of the block's end. A rest of the word that runs past it is left whole, never cut
/// (nor split between the halves of a surrogate pair).
export function commandSplice(
  after: string,
  trigger: SlashTrigger,
  name: string,
  cut = false,
): { back: number; forward: number; text: string } {
  const word = /^[^\s\uFFFC]*/.exec(after)?.[0] ?? "";
  const forward =
    word.length === after.length && cut ? 0 : word.length + (/^[ \t]/.test(after.slice(word.length)) ? 1 : 0);
  return { back: trigger.length, forward, text: `/${name} ` };
}

/// The prompt after picking `command` with no editor to edit in place: `/name ` replacing a
/// leading `/word`.
export function applyCommand(text: string, caret: number, command: SlashCommand): { text: string; caret: number } {
  const inserted = `/${shownName(command)} `;
  const rest = text.slice(caret).replace(/^\S*\s?/, "");
  return { text: inserted + rest, caret: inserted.length };
}
