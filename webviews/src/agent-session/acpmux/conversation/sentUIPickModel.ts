// Inspector picks in a sent prompt's text (SentUIPick.tsx). The composer sends a pick as a text
// attachment, its name over its report in a fence (attachments.ts `promptText`): "UI: span", then
// ```` ``` ````, "cmux NEXT app-owned webview selection" and the report's lines, then the fence. The
// bubble draws each such block as the composer's chip, which opens the report in place; the text
// around it reads as before. The recorded text is unchanged: Copy and Edit keep it whole.
import { UI_PICK_HEADER } from "../composer/uiPickModel";

export type SentPromptSegment = { kind: "text"; text: string } | { kind: "pick"; name: string; text: string };

/// A pick's block: its name's line, a fence of three or more backticks (with any info string), the
/// report from its header line, and the same fence on a line of its own.
const BLOCK = new RegExp(
  `(^|\\n)([^\\n]+)\\n(\`{3,})[^\\n\`]*\\n(${UI_PICK_HEADER}(?:\\n[\\s\\S]*?)?)\\n\\3(?=\\n|$)`,
  "g",
);

/// The prompt's text split around its picks, or undefined when it holds none (the common case: one
/// substring test). The text between two blocks keeps its words; the line breaks that only set a
/// block apart go, the chip being a block of its own.
export function sentUIPickSegments(text: string): SentPromptSegment[] | undefined {
  if (!text.includes(UI_PICK_HEADER)) return undefined;
  const segments: SentPromptSegment[] = [];
  let at = 0;
  for (const match of text.matchAll(BLOCK)) {
    const start = match.index + match[1]!.length;
    const before = text.slice(at, start).replace(/\s+$/, "");
    if (before.trim()) segments.push({ kind: "text", text: before });
    segments.push({ kind: "pick", name: match[2]!.trim(), text: match[4]! });
    at = match.index + match[0].length;
  }
  if (!segments.length) return undefined;
  const after = text.slice(at).replace(/^\s+/, "");
  if (after.trim()) segments.push({ kind: "text", text: after });
  return segments;
}

/// A text file's stored body when it is one inspector pick's block, as the composer sends a pick
/// placed in the prompt (inlinePrompt.ts): its chip draws it (InlinePromptContent.tsx).
export function sentUIPick(stored: string): Extract<SentPromptSegment, { kind: "pick" }> | undefined {
  const segments = sentUIPickSegments(stored);
  const only = segments?.length === 1 ? segments[0] : undefined;
  return only?.kind === "pick" ? only : undefined;
}
