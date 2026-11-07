// Reply to Selection (a port of the native ReplyQuote and ChatController+ReplyQuote): the words
// selected in one message become the reply's quote. The reply opens as Reply… does, with a card
// above the message box ("Replying to <name>", the words, a remove button), and the send carries the
// quote as a Markdown blockquote before the typed text, so every owner stores it as written.
import { quoteMarkdown } from "../../home-channels/quoteSelection";

/** The words a reply answers, and the message they are in. */
export interface ReplyQuote {
  message: string;
  text: string;
}

/** A quote longer than this goes out cut, with an ellipsis (ReplyQuote.maxQuoted). */
export const MAX_QUOTED = 1_000;
/** The card shows at most this many characters (ReplyQuote.cardLimit). */
export const CARD_LIMIT = 160;

const PENDING = /^(?:pending|stream):/;

/** The quote of the page's selection: undefined when nothing but white space is selected, when it
 * starts or ends outside a message or in two messages (a quote has one source), when it is in a
 * field, or when the message is not sent yet. `within`: only a selection in that message. */
export function selectionQuote(doc: Document, within?: string): ReplyQuote | undefined {
  const selection = doc.getSelection();
  if (!selection || selection.isCollapsed) return undefined;
  const holder = (node: Node | null) => {
    const element = node?.nodeType === 1 ? (node as Element) : node?.parentElement;
    if (element?.closest("input, textarea, [contenteditable]")) return undefined;
    return element?.closest<HTMLElement>("[data-message]") ?? undefined;
  };
  const start = holder(selection.anchorNode)?.dataset.message;
  const end = holder(selection.focusNode)?.dataset.message;
  if (!start || start !== end || PENDING.test(start)) return undefined;
  if (within !== undefined && start !== within) return undefined;
  const text = selection.toString().trim();
  if (!text) return undefined;
  return { message: start, text: text.length > MAX_QUOTED ? cut(text, MAX_QUOTED) : text };
}

/** The reply as it goes out: the quote as a blockquote, a blank line, then the typed text. */
export function quotedReply(quote: string, reply: string): string {
  return quoteMarkdown(quote) + reply;
}

/** The text with its white space collapsed, at most `limit` characters, cut at a word end. */
export function excerpt(text: string, limit = CARD_LIMIT): string {
  const flat = text.split(/\s+/).filter(Boolean).join(" ");
  return flat.length > limit ? cut(flat, limit) : flat;
}

/** The first `limit` characters, back to the last word end when one is past the middle, and "…". */
function cut(text: string, limit: number): string {
  const head = text.slice(0, Math.max(1, limit - 1));
  const space = head.search(/\s\S*$/);
  const word = space > limit / 2 ? head.slice(0, space) : head;
  return `${word.trim()}…`;
}
