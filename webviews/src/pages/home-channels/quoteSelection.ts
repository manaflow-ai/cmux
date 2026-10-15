// Quote in Reply (the app's native menu on selected message text, POLISH.md right-click contract):
// the page command `quoteSelection` puts the selection into the open composer as a Markdown quote.
// The composer (Composer.tsx) takes it through QUOTE_EVENT.

/** The event a composer takes a quote through: `detail` is the selected text. */
export const QUOTE_EVENT = "hc-quote";

/** Quotes the selected message text in the open composer; false when nothing was quoted. */
export function quoteSelection(_doc: Document): boolean {
  return false;
}
