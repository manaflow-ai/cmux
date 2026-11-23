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
import { codeSpans, type SlashCommand } from "./slashCommands";

export type ToolMentionId = "computer-use" | "browser-use";

export type ToolMention = {
  id: ToolMentionId;
  /** The row's name and description, from the pane's table. */
  label: StringKey;
  hint: StringKey;
  icon: string;
  /** What a typed word may start to name it (`@comp`, `@brow`, `@cu`). */
  words: readonly string[];
};

export const TOOL_MENTIONS: readonly ToolMention[] = [
  {
    id: "computer-use",
    label: "mention.computerUse",
    hint: "mention.computerUseHint",
    icon: "computeruse.observe",
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
    /(^|[\s\uFFFC(["'])@(computer-use|browser-use)(?=[\s\uFFFC]|$|[,;:!?)\]"']|\.(?:\s|$))/gi,
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
    label: t(tool.label),
  }));
}

/// The tools `text` names as `@computer-use` / `@browser-use` (or `$computer-use`) outside code (a
/// fenced block or an inline span is literal text, never a mention), in menu order.
export function toolMentionsIn(text: string): readonly ToolMentionId[] {
  if (!text.includes("@") && !text.includes("$")) return [];
  const prose = withoutCode(text);
  const found = new Set<string>();
  // Markdown's emphasis around it (`**@computer-use**`) is no part of the word, the badge drew it the
  // same; emphasis then more letters (`@computer-use_notes`) is another word.
  // A bracket or quote before it (`(@computer-use)`) is punctuation, not part of another word. The same
  // rule as acpmux's tool_mentions.rs, which writes the agent's note: tool_mention_cases.json holds both.
  for (const match of prose.matchAll(
    /(^|[\s\uFFFC(["'])[*_~]*[@$](computer-use|browser-use)(?=[*_~]*(?:[\s\uFFFC]|$|[,;:!?)\]"']|\.(?:\s|$)))/gi,
  ))
    found.add(match[2]!.toLowerCase());
  return TOOL_MENTIONS.filter((tool) => found.has(tool.id)).map((tool) => tool.id);
}

/// `text` with its code blanked (line breaks kept), as CommonMark reads it: fenced blocks (`fenceLines`),
/// then inline code spans (slashCommands.ts codeSpans, `` ` `` runs too). One pass each, whatever the
/// draft's size.
function withoutCode(text: string): string {
  const lines = text.split("\n");
  const code = fenceLines();
  for (let index = 0; index < lines.length; index++) {
    if (code(lines[index]!)) lines[index] = lines[index]!.replace(/[^\n]/g, " ");
  }
  const fenced = lines.join("\n");
  const spans = codeSpans(fenced);
  if (!spans.length) return fenced;
  const out: string[] = [];
  let at = 0;
  for (const span of spans) {
    out.push(fenced.slice(at, span.start), fenced.slice(span.start, span.end).replace(/[^\n]/g, " "));
    at = span.end;
  }
  out.push(fenced.slice(at));
  return out.join("");
}

/// The fenced code blocks of a text, line by line, as CommonMark reads them inside its containers
/// (acpmux's tool_mentions.rs `Fences` keeps the same rules). A block quote (`>`) holds a line that
/// carries its marker; a list item (`-`, `*`, `+`, `1.`, `1)`) holds a blank line and one indented to
/// its content. A fence opened in a container ends with it: lazy continuation is only for a paragraph,
/// so `> ~~~` then a line without `>` is prose again. Inside its container, a fence closes at a line of
/// its mark at least as long, indented at most three spaces. Tabs count to the next multiple of four
/// columns. The reader it returns says, for each next line, whether it is a fenced block's.
function fenceLines(): (line: string) => boolean {
  // The open containers, outermost first: undefined a block quote, a number a list item whose content
  // starts that many columns into its parent's.
  const open: (number | undefined)[] = [];
  let fence: { mark: string; length: number } | undefined;
  // The last line was paragraph text, which a lazy line continues.
  let paragraph = false;
  return (line) => {
    const [matched, rest] = matchOpen(open, expandTabs(line));
    if (fence) {
      if (matched === open.length) {
        if (closes(rest, fence.mark, fence.length)) fence = undefined;
        return true;
      }
      // Its container ended, so the fence did too.
      fence = undefined;
      paragraph = false;
    }
    if (matched < open.length) {
      if (paragraph && !blank(rest) && !startsBlock(rest)) return false;
      open.length = matched;
    }
    const after = openNew(open, rest);
    const opened = opens(after);
    if (opened) {
      fence = opened;
      paragraph = false;
      return true;
    }
    paragraph = !blank(after);
    return false;
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
/// fence or a heading.
function startsBlock(rest: string): boolean {
  const n = spaces(rest);
  if (n > 3) return false;
  const after = rest.slice(n);
  return after.startsWith(">") || listMarker(after) !== undefined || !!opens(rest) || /^#{1,6}(?: |\r?$)/.test(after);
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
