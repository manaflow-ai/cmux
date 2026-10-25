import { INLINE_ATTACHMENT_MARK } from "./attachments";

/// `text`, a sent prompt's words (as shown, maybe edited since: Retry, Edit and Resend), with the
/// marks `sent` placed attachments by, each where it was among the words: a mark in words that stayed
/// keeps its place, one after them moves with them, one inside the words that changed goes after
/// the change. So a resent prompt goes in the order it was written.
export function carryMarks(sent: string, text: string): string {
  const pieces = sent.split(INLINE_ATTACHMENT_MARK);
  if (pieces.length < 2) return text;
  const plain = pieces.join("");
  let head = 0;
  while (head < plain.length && head < text.length && plain[head] === text[head]) head += 1;
  let tail = 0;
  while (
    tail < plain.length - head &&
    tail < text.length - head &&
    plain[plain.length - 1 - tail] === text[text.length - 1 - tail]
  )
    tail += 1;
  const at = (offset: number) =>
    offset <= head ? offset : offset >= plain.length - tail ? offset + text.length - plain.length : text.length - tail;
  let out = "";
  let from = 0;
  let offset = 0;
  for (const piece of pieces.slice(0, -1)) {
    offset += piece.length;
    const to = Math.max(from, at(offset));
    out += text.slice(from, to) + INLINE_ATTACHMENT_MARK;
    from = to;
  }
  return out + text.slice(from);
}
