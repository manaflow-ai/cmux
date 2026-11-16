import { clipMessagePreview } from "./clipMessagePreview";

/// The message's first line of text as it reads, its spaces collapsed and its Markdown marks (a
/// heading's or quote's or list item's lead, emphasis, code ticks) dropped: the closed line's
/// preview. The same reading as incomingMessage.ts gives a received message (#23727).
export function messagePreview(text: string): string {
  const line = text.split("\n").find((part) => part.trim()) ?? "";
  return clipMessagePreview(plainLine(line));
}

/// One line of Markdown as it reads, uncut: its heading's, quote's or list item's lead and its
/// emphasis and code ticks dropped.
export function plainLine(line: string): string {
  return line.replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?)/, "").replace(/(\*\*|__|`)/g, "");
}
