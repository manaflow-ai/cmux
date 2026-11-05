// Copying a selection inside a reply (Cmd-C) puts the reply's formatting on the clipboard as Claude
// and ChatGPT do: clean HTML (headings, bullets, bold, links, code, tables) with no transcript
// classes, colors or fonts, so a paste into Notes, Slack, Docs or Mail reads as the reply did and
// never takes the pane's dark-theme colors; and the same selection as Markdown for its plain text, so
// a paste into the composer or a terminal keeps its bullets (richClipboard.ts).
//
// It takes over only a selection inside one message's Markdown (`.cv-md`). A selection with math is
// mathCopy.ts's (the TeX as written), one that holds highlighted code (drawn in a shadow root the
// copy cannot read) or reaches across messages copies as the page would copy it.
import { htmlMarkdown } from "../richClipboard";

const MATH = "[data-tex]";
/// Attributes the copy keeps; every other one (classes, styles, data, aria) is the transcript's own.
const KEEP = new Set(["href", "start", "colspan", "rowspan", "src", "alt"]);
/// What the transcript draws around the text: icons and hidden labels. A button (a link chip, an
/// image that opens) is unwrapped, its words and picture kept.
const CHROME = "svg, [aria-hidden='true'], [hidden], .sr-only";

/// The document the listener is on: once per page, and again for a new one (a test's next DOM).
let installedOn: Document | undefined;

export function installSelectionCopy() {
  if (typeof document === "undefined" || installedOn === document) return;
  installedOn = document;
  document.addEventListener("copy", onCopy);
}

function elementOf(node: Node): Element | null {
  return node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
}

/** The selection's HTML, cleaned of the transcript's chrome and attributes; null when it is not one
 * this copy takes. */
export function selectionHtml(range: Range): string | null {
  const reply = elementOf(range.commonAncestorContainer)?.closest(".cv-md");
  if (!reply) return null;
  // Math is mathCopy.ts's, also a selection that starts or ends inside an equation (its clone
  // leaves out the element that holds the TeX); highlighted code draws in a shadow root, which a
  // clone leaves empty.
  if (elementOf(range.startContainer)?.closest(MATH) || elementOf(range.endContainer)?.closest(MATH)) return null;
  for (const element of reply.querySelectorAll("*"))
    if ((element.shadowRoot || element.matches(MATH)) && range.intersectsNode(element)) return null;
  const holder = document.createElement("div");
  holder.append(range.cloneContents());
  for (const element of holder.querySelectorAll(CHROME)) element.remove();
  for (const button of holder.querySelectorAll("button")) button.replaceWith(...button.childNodes);
  for (const element of holder.querySelectorAll("*"))
    for (const name of element.getAttributeNames()) if (!KEEP.has(name)) element.removeAttribute(name);
  return holder.innerHTML;
}

function onCopy(event: ClipboardEvent) {
  if (event.defaultPrevented || !event.clipboardData) return;
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const html = selectionHtml(selection.getRangeAt(0));
  if (!html) return;
  const markdown = htmlMarkdown(html);
  if (!markdown) return;
  event.clipboardData.setData("text/plain", markdown);
  event.clipboardData.setData("text/html", html);
  event.preventDefault();
}
