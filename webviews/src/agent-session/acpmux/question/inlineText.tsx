// The inline Markdown an agent writes in a question, its options' labels and their descriptions:
// `code`, **bold**, *italic* or _italic_, ~~struck~~, and a backslash escape. Claude Code's own card
// draws these as marks; drawn as plain text they showed their backticks and asterisks. Only marks:
// an option row is a button, so a link draws as its label (a link or chip inside the row would
// take the click that answers it), and nothing here loads, runs or opens anything.
import { Fragment, type ReactNode } from "react";

// Groups: code, bold, strikethrough, italic, link (its label), backslash escape. The same shapes
// the transcript's renderInline reads (conversation/Markdown.tsx), so an agent's text reads alike.
const MARKS =
  /(`[^`\n]+`)|(\*\*[^*\n]+\*\*)|(~~[^~\n]+~~)|((?<![\w*])\*[^*\s][^*\n]*\*(?![\w*])|(?<![\w_])_[^_\s][^_\n]*_(?![\w_]))|(\[[^\]\n]+\]\([^()\s]+\))|(\\[\\`*_{}[\]()#+\-.!~<>])/g;

/// True when `text` holds a mark this reads (so plain text keeps its exact string).
export const hasMarks = (text: string): boolean => new RegExp(MARKS.source).test(text);

/// `text` with its inline marks drawn; plain text comes back as the same string.
export function inlineText(text: string): ReactNode {
  if (!hasMarks(text)) return text;
  return marks(text, "m");
}

function marks(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let index = 0;
  for (const match of text.matchAll(MARKS)) {
    const at = match.index!;
    if (at > last) out.push(text.slice(last, at));
    const whole = match[0];
    const k = `${key}.${index++}`;
    if (match[1])
      out.push(
        <code key={k} className="acpmux-question-code">
          {whole.slice(1, -1)}
        </code>,
      );
    else if (match[2]) out.push(<strong key={k}>{marks(whole.slice(2, -2), k)}</strong>);
    else if (match[3]) out.push(<del key={k}>{marks(whole.slice(2, -2), k)}</del>);
    else if (match[4]) out.push(<em key={k}>{marks(whole.slice(1, -1), k)}</em>);
    else if (match[5]) out.push(<Fragment key={k}>{marks(whole.slice(1, whole.indexOf("](")), k)}</Fragment>);
    else out.push(whole.slice(1));
    last = at + whole.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}
