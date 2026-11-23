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
    /(^|[\s\uFFFC])@(computer-use|browser-use)(?=[\s\uFFFC]|$|[,;:!?)]|\.(?:\s|$))/gi,
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
  for (const match of prose.matchAll(
    /(^|[\s\uFFFC])[*_~]*[@$](computer-use|browser-use)(?=[*_~]*(?:[\s\uFFFC]|$|[,;:!?)]|\.(?:\s|$)))/gi,
  ))
    found.add(match[2]!.toLowerCase());
  return TOOL_MENTIONS.filter((tool) => found.has(tool.id)).map((tool) => tool.id);
}

/// `text` with its code blanked (line breaks kept), as CommonMark reads it: fenced blocks (a line of 3+
/// backticks or tildes, closed by a line of the same mark at least as long, or the end), then inline
/// code spans (slashCommands.ts codeSpans, `` ` `` runs too). One pass each, whatever the draft's size.
function withoutCode(text: string): string {
  const lines = text.split("\n");
  let fence: { mark: string; length: number } | undefined;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!;
    const run = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (fence) {
      lines[index] = " ".repeat(line.length);
      if (run && run[1]![0] === fence.mark && run[1]!.length >= fence.length && !line.slice(run[0].length).trim())
        fence = undefined;
    } else if (run && !(run[1]![0] === "`" && line.slice(run[0].length).includes("`"))) {
      fence = { mark: run[1]![0]!, length: run[1]!.length };
      lines[index] = " ".repeat(line.length);
    }
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
