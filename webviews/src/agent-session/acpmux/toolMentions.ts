// The composer's built-in @ tools (CMUX-682; Lucas and Lawrence, standup 2026-11-20): "@computer use"
// and "@browser use" are always in the @ menu, named for what they do, never "cmux CUA". Picking one
// writes `@computer-use ` or `@browser-use ` (one word, so the mention parser and the agent read it
// whole). A send that names one keeps the person's text as written and adds a note for the agent
// (`_meta.acpmux.context`, kept out of the transcript, as workspaceContext.ts), so the agent uses
// cmux's own tool for it. Every session already has both tools: Computer Use through its MCP bridge
// and the cmux-computer-use skill, the browser through the cmux-browser skill and `cmux browser`
// (acpmux agent_tools.rs). Only Computer Use needs setup (two macOS grants); the send asks the app
// first (computerUse/computerUseState.ts).
//
// l10n-allow-file: the notes are text for the agent, not the person, so they are not localized.
import type { StringKey, Translate } from "./i18n";
import computerUseTile from "./icons/computerUseTile.png";
import { codeSpans, type SlashCommand } from "./slashCommands";

/// Computer Use's tile (the midnight cursor): the composer's @computer-use and the setup window's head.
/// Imported, not `new URL(..., import.meta.url)`: the shipped pages inline each PNG as a data URL, and a
/// classic (non-module) script that bundles this file cannot parse `import.meta`.
export const COMPUTER_USE_TILE: string = computerUseTile;

export type ToolMentionId = "computer-use" | "browser-use";

export type ToolMention = {
  id: ToolMentionId;
  /** The row's name and description, from the pane's table. */
  label: StringKey;
  hint: StringKey;
  icon: string;
  /** A full-color picture drawn in place of `icon` (the menus' rows and both badges), when it has one. */
  image?: string;
  /** What a typed word may start to name it (`@comp`, `@brow`, `@cu`). */
  words: readonly string[];
};

export const TOOL_MENTIONS: readonly ToolMention[] = [
  {
    id: "computer-use",
    label: "mention.computerUse",
    hint: "mention.computerUseHint",
    icon: "computeruse.observe",
    // Lucas 2026-11-23: "lets use this icon here for computer use" (the midnight cursor tile).
    image: COMPUTER_USE_TILE,
    words: ["computer-use", "computer use", "cu"],
  },
  {
    id: "browser-use",
    label: "mention.browserUse",
    hint: "mention.browserUseHint",
    icon: "browser",
    words: ["browser-use", "browser use", "bu"],
  },
];

/// The href a tool's word stands for in the draft (composer/deeplinkTokens.ts), which the draft's chip
/// plugin draws as a badge with the tool's icon and name (composer/deeplinkTitles.ts).
export const TOOL_HREF_PREFIX = "cmux-tool:";

/// The tool a draft badge's href names, or undefined.
export function toolOfHref(href: string): ToolMention | undefined {
  if (!href.startsWith(TOOL_HREF_PREFIX)) return undefined;
  const id = href.slice(TOOL_HREF_PREFIX.length);
  return TOOL_MENTIONS.find((tool) => tool.id === id);
}

/// Each `@computer-use` / `@browser-use` word in one textblock's text (a leaf reads as U+FFFC), with
/// the href its badge draws from. The same word rule as `toolMentionsIn`.
export function toolWords(text: string): { start: number; end: number; href: string }[] {
  if (!text.includes("@")) return [];
  const out: { start: number; end: number; href: string }[] = [];
  for (const match of text.matchAll(
    /(^|[\s\uFFFC(["'\u201C\u2018])@(computer-use|browser-use)(?=[\s\uFFFC]|$|[,;:!?)\]"'\u201D\u2019]|\.(?:\s|$|[)\]"'\u201D\u2019]))/gi,
  )) {
    const start = match.index! + match[1]!.length;
    out.push({ start, end: start + 1 + match[2]!.length, href: TOOL_HREF_PREFIX + match[2]!.toLowerCase() });
  }
  return out;
}

/// The tools a typed `@word` names, in menu order: every tool for a bare `@`, else those whose name
/// (or short form) starts with the word, case aside.
export function toolMentionsFor(query: string): readonly ToolMention[] {
  const word = query.trim().toLowerCase();
  if (!word) return TOOL_MENTIONS;
  return TOOL_MENTIONS.filter((tool) => tool.words.some((name) => name.startsWith(word)));
}

/// The `/` and `$` menus' rows for the tools (Lucas 2026-11-21: "computer use should appear in the
/// top menu where the skills appear"): picking one writes `@computer-use `, never `/computer-use`,
/// which Claude Code and Codex would refuse as an unknown command. cmux's own, so the row says cmux.
export function toolSlashCommands(t: Translate): SlashCommand[] {
  return TOOL_MENTIONS.map((tool) => ({
    name: tool.id,
    insert: `@${tool.id} `,
    description: t(tool.hint),
    source: "extension",
    icon: tool.icon,
    image: tool.image,
    label: t(tool.label),
  }));
}

/// True: `command` is one of `toolSlashCommands`' rows (not an extension's command of the same name,
/// which names its extension), or the cmux plugin's skill behind one of the two tools. The New Tab lists the tools only after `@`, never in its
/// `/` menu or `/help` (Lucas 2026-11-24: "those should only show when the user types @").
export function isToolCommand(command: SlashCommand): boolean {
  if (command.extension !== undefined) return false;
  // The skills behind the tools, which acpmux's session plugin gives Claude Code (agent_tools.rs):
  // `@computer-use` and `@browser-use` already name them.
  if (command.source !== "extension") return CMUX_TOOL_SKILLS.has(command.name);
  return TOOL_MENTIONS.some((tool) => command.name === tool.id && command.insert === `@${tool.id} `);
}

/// The cmux plugin's skills for the two tools, as Claude Code lists them.
const CMUX_TOOL_SKILLS: ReadonlySet<string> = new Set(["cmux:cmux-browser", "cmux:cmux-computer-use"]);

/// The tools `text` names as `@computer-use` / `@browser-use` (or `$computer-use`) outside code (a
/// fenced block or an inline span is literal text, never a mention), in menu order.
export function toolMentionsIn(text: string): readonly ToolMentionId[] {
  if (!text.includes("@") && !text.includes("$")) return [];
  const prose = withoutCode(text);
  const found = new Set<string>();
  // Markdown's emphasis around it (`**@computer-use**`) is no part of the word, the badge drew it the
  // same; emphasis then more letters (`@computer-use_notes`) is another word.
  // A bracket or quote before it (`(@computer-use)`, `“@computer-use”`) is punctuation, not part of
  // another word; a block quote's marker (`>@computer-use`) is blanked by `withoutCode`. The same rule
  // as acpmux's tool_mentions.rs, which writes the agent's note: tool_mention_cases.json holds both.
  // A full stop ends it before a space, the end or a closing mark (`(@computer-use.)`), never before
  // more letters (`@computer-use.md` is a file).
  for (const match of prose.matchAll(
    /(^|[\s\uFFFC(["'\u201C\u2018])[*_~]*[@$](computer-use|browser-use)(?=[*_~]*(?:[\s\uFFFC]|$|[,;:!?)\]"'\u201D\u2019]|\.(?:\s|$|[)\]"'\u201D\u2019])))/gi,
  ))
    found.add(match[2]!.toLowerCase());
  return TOOL_MENTIONS.filter((tool) => found.has(tool.id)).map((tool) => tool.id);
}

/// `text` as prose: each line's container markers (`>`, a list item's marker and indent) and its fenced
/// code blanked (`fenceLines`), then the inline code spans of each paragraph (slashCommands.ts codeSpans,
/// `` ` `` runs too), which a container's markers never end (`> run \`a` then `> b\` now` is one span).
/// Line breaks are kept and tabs read as spaces; only the mentions in it are read. One pass each,
/// whatever the draft's size.
function withoutCode(text: string): string {
  const lines = text.split("\n");
  const read = fenceLines();
  const breaks: number[] = [];
  let at = 0;
  for (let index = 0; index < lines.length; index++) {
    const wide = expandTabs(lines[index]!);
    const line = read(wide);
    if (index > 0 && !line.continues) breaks.push(at);
    lines[index] = line.code ? blankOut(wide) : blankOut(wide.slice(0, line.start)) + wide.slice(line.start);
    at += lines[index]!.length + 1;
  }
  const prose = lines.join("\n");
  const spans = codeSpans(prose, breaks);
  if (!spans.length) return prose;
  const out: string[] = [];
  at = 0;
  for (const span of spans) {
    out.push(prose.slice(at, span.start), blankOut(prose.slice(span.start, span.end)));
    at = span.end;
  }
  out.push(prose.slice(at));
  return out.join("");
}

/// Each character of `text` as a space, line breaks kept.
function blankOut(text: string): string {
  return text.replace(/[^\n]/g, " ");
}

/// One line as `fenceLines` read it: whether it is a fenced block's (its opening, content or closing),
/// where its content starts after its container markers, and whether it goes on with the paragraph of
/// the line before (no blank line, block start, new or closed container between them).
type FenceLine = { code: boolean; start: number; continues: boolean };

/// The fenced code blocks of a text, line by line, as CommonMark reads them inside its containers
/// (acpmux's tool_mentions.rs `Fences` keeps the same rules). A block quote (`>`) holds a line that
/// carries its marker; a list item (`-`, `*`, `+`, `1.`, `1)`) holds a blank line and one indented to
/// its content. A fence opened in a container ends with it: lazy continuation is only for a paragraph,
/// so `> ~~~` then a line without `>` is prose again. Inside its container, a fence closes at a line of
/// its mark at least as long, indented at most three spaces. The reader it returns reads each next line,
/// its tabs expanded (`expandTabs`).
function fenceLines(): (wide: string) => FenceLine {
  // The open containers, outermost first: undefined a block quote, a number a list item whose content
  // starts that many columns into its parent's.
  const open: (number | undefined)[] = [];
  let fence: { mark: string; length: number } | undefined;
  // The last line was paragraph text, which a lazy line continues.
  let paragraph = false;
  return (wide) => {
    const [matched, rest] = matchOpen(open, wide);
    const start = (rest: string) => wide.length - rest.length;
    if (fence) {
      if (matched === open.length) {
        if (closes(rest, fence.mark, fence.length)) fence = undefined;
        return { code: true, start: start(rest), continues: false };
      }
      // Its container ended, so the fence did too.
      fence = undefined;
      paragraph = false;
    }
    const closed = matched < open.length;
    if (closed) {
      // A lazy line goes on with the paragraph.
      if (paragraph && !blank(rest) && !startsBlock(rest)) return { code: false, start: start(rest), continues: true };
      open.length = matched;
    }
    const before = open.length;
    const after = openNew(open, rest);
    const opened = opens(after);
    if (opened) {
      fence = opened;
      paragraph = false;
      return { code: true, start: start(after), continues: false };
    }
    const continues = paragraph && !closed && open.length === before && !blank(after) && !startsBlock(after);
    paragraph = !blank(after) && !heading(after) && !thematicBreak(after);
    return { code: false, start: start(after), continues };
  };
}

/// `line` with each tab as the spaces to the next multiple of four columns.
function expandTabs(line: string): string {
  if (!line.includes("\t")) return line;
  let out = "";
  let column = 0;
  for (const ch of line) {
    if (ch === "\t") {
      const n = 4 - (column % 4);
      out += " ".repeat(n);
      column += n;
    } else {
      out += ch;
      column += 1;
    }
  }
  return out;
}

/// Whether `s` holds only spaces (and a line's `\r`).
function blank(s: string): boolean {
  return /^[ \r]*$/.test(s);
}

function spaces(s: string): number {
  return /^ */.exec(s)![0].length;
}

/// How many of `open` `line` continues, and the rest of it after their markers and indents.
function matchOpen(open: readonly (number | undefined)[], line: string): [number, string] {
  let rest = line;
  for (let index = 0; index < open.length; index++) {
    const indent = open[index];
    if (indent === undefined) {
      const n = spaces(rest);
      if (n > 3 || rest[n] !== ">") return [index, rest];
      rest = rest.slice(n + 1);
      if (rest.startsWith(" ")) rest = rest.slice(1);
    } else {
      if (blank(rest)) continue;
      if (spaces(rest) < indent) return [index, rest];
      rest = rest.slice(indent);
    }
  }
  return [open.length, rest];
}

/// The length of the list marker `s` starts with (`-`, `*`, `+`, or 1 to 9 digits then `.` or `)`),
/// when a space or the line's end follows it.
function listMarker(s: string): number | undefined {
  const marker = /^(?:[-*+]|[0-9]{1,9}[.)])/.exec(s);
  if (!marker) return undefined;
  const after = s.slice(marker[0].length);
  return blank(after) || after.startsWith(" ") ? marker[0].length : undefined;
}

/// Opens the block quotes and list items `rest` starts with, and gives what follows them.
function openNew(open: (number | undefined)[], rest: string): string {
  for (;;) {
    const n = spaces(rest);
    if (n > 3) return rest;
    const after = rest.slice(n);
    if (after.startsWith(">")) {
      open.push(undefined);
      rest = after.slice(1);
      if (rest.startsWith(" ")) rest = rest.slice(1);
      continue;
    }
    // `* * *` is a thematic break, no list item.
    if (thematicBreak(rest)) return rest;
    const marker = listMarker(after);
    if (marker === undefined) return rest;
    const content = after.slice(marker);
    if (blank(content)) {
      open.push(n + marker + 1);
      return content;
    }
    // Five or more spaces after the marker start indented code: the content is one in.
    const gap = spaces(content) >= 5 ? 1 : spaces(content);
    open.push(n + marker + gap);
    rest = content.slice(gap);
  }
}

/// The fence `rest` opens: at most three spaces, then 3+ backticks or tildes, as its mark and length
/// (a backtick fence's info has no backtick).
function opens(rest: string): { mark: string; length: number } | undefined {
  const run = /^ {0,3}(`{3,}|~{3,})/.exec(rest);
  if (!run) return undefined;
  const mark = run[1]![0]!;
  if (mark === "`" && rest.slice(run[0].length).includes("`")) return undefined;
  return { mark, length: run[1]!.length };
}

/// Whether `rest` closes the fence of `mark` and `length`.
function closes(rest: string, mark: string, length: number): boolean {
  const run = /^ {0,3}(`+|~+)/.exec(rest);
  return !!run && run[1]![0] === mark && run[1]!.length >= length && blank(rest.slice(run[0].length));
}

/// Whether `rest` starts a block, so it is no lazy line of a paragraph: a block quote, a list item, a
/// fence, a heading or a thematic break.
function startsBlock(rest: string): boolean {
  const n = spaces(rest);
  if (n > 3) return false;
  const after = rest.slice(n);
  return (
    after.startsWith(">") || listMarker(after) !== undefined || !!opens(rest) || heading(rest) || thematicBreak(rest)
  );
}

/// Whether `rest` is a thematic break: at most three spaces, then 3+ of one of `-`, `*`, `_`, with spaces
/// between them allowed. It ends a paragraph (under one, `---` underlines a heading, which ends it too), so
/// an inline code span never runs across it.
function thematicBreak(rest: string): boolean {
  return /^ {0,3}(?:(?:- *){3,}|(?:\* *){3,}|(?:_ *){3,})$/.test(rest.replace(/[ \r]+$/, ""));
}

/// Whether `rest` is an ATX heading: at most three spaces, 1 to 6 `#`, then a space or the end.
function heading(rest: string): boolean {
  return /^ {0,3}#{1,6}(?: |[ \r]*$)/.test(rest);
}

const NOTES: Record<ToolMentionId, string> = {
  "computer-use":
    "The person wrote @computer-use: do this with cmux Computer Use, which drives the apps on this Mac (the cmux-computer-use skill and its tools). Use it for the steps that need an app's own window.",
  "browser-use":
    "The person wrote @browser-use: do this in the cmux browser (the cmux-browser skill, or `cmux browser` in your shell), not in a separate or headless browser.",
};

/// The note a send that names tools adds for the agent; undefined when it names none. It starts on
/// its own line, as the workspace note does, so the person's words stay alone on the first line. Its
/// `<cmux-…-context>` element is the shape acpmux drops from a replayed harness log (prompt_context.rs).
export function toolMentionContext(ids: readonly ToolMentionId[]): string | undefined {
  if (ids.length === 0) return undefined;
  const lines = ids.map((id) => NOTES[id]).join("\n");
  return `\n\n<cmux-tools-context>\nThe person did not type this note; do not quote it.\n${lines}\n</cmux-tools-context>`;
}
