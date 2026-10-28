// Quote in Reply shares the native selection event with Home Channels. The agent pane keeps
// the insertion at the bottom of its current draft so the reply stays after what is already typed.
import { QUOTE_EVENT, quoteMarkdown } from "../../pages/home-channels/quoteSelection";

export { QUOTE_EVENT, quoteMarkdown };

/** Append one Markdown quote to a draft, leaving one blank line on either side. */
export function appendQuoteMarkdown(current: string, selected: string): string {
  const quote = quoteMarkdown(selected);
  if (!current) return quote;
  const separator = current.endsWith("\n\n") ? "" : current.endsWith("\n") ? "\n" : "\n\n";
  return `${current}${separator}${quote}`;
}
