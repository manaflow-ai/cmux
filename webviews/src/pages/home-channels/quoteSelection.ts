// Quote in Reply (the app's native menu on selected message text, POLISH.md right-click contract):
// the page command `quoteSelection` puts the selection into the open composer as a Markdown quote,
// after what is already typed. An open thread's composer takes it, else the conversation's; an
// inline edit never does, and text selected inside a composer or any other field is never quoted. The composer
// (Composer.tsx) takes the text through QUOTE_EVENT.

/** The page command the app's selection menu sends (CmuxNextPages PageSelectionMenu.swift). */
export const QUOTE_COMMAND = "quoteSelection";

/** The event a composer takes a quote through: `detail` is the selected text. */
export const QUOTE_EVENT = "hc-quote";

/** `text` as a Markdown quote, with a blank line after it for the reply. */
export function quoteMarkdown(text: string): string {
  const lines = text.replace(/\s+$/, "").split("\n");
  return `${lines.map((line) => (line ? `> ${line}` : ">")).join("\n")}\n\n`;
}

/** Quotes the selected message text in the open composer; false when nothing was quoted. */
export function quoteSelection(doc: Document): boolean {
  const selection = doc.getSelection();
  const text = selection?.toString() ?? "";
  if (!selection || selection.isCollapsed || !text.trim()) return false;
  const anchor = selection.anchorNode;
  const element = anchor?.nodeType === 1 ? (anchor as Element) : anchor?.parentElement;
  if (element?.closest(".hc-composer, input, textarea, [contenteditable]")) return false;
  const target =
    doc.querySelector(".lg-sheet .hc-composer:not(.hc-edit)") ??
    doc.querySelector(".lg-main-compose .hc-composer:not(.hc-edit)");
  if (!target) return false;
  const View = doc.defaultView ?? window;
  target.dispatchEvent(new View.CustomEvent(QUOTE_EVENT, { detail: text }));
  return true;
}
