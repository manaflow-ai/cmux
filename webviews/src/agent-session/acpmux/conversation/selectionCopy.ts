// Copying a selection inside a reply (Cmd-C) puts the reply's formatting on the clipboard as Claude
// and ChatGPT do: clean HTML (headings, bullets, bold, links, code, tables) with no transcript
// classes, colors or fonts, so a paste into Notes, Slack, Docs or Mail reads as the reply did and
// never takes the pane's dark-theme colors; and the same selection as Markdown for its plain text, so
// a paste into the composer or a terminal keeps its bullets (richClipboard.ts).
//
// It takes over only a selection inside one message's Markdown (`.cv-md`). A selection with math is
// mathCopy.ts's (the TeX as written), one that holds highlighted code (drawn in a shadow root the
// copy cannot read) or reaches across messages copies as the page would copy it.
//
// A cmux link drawn as its chip (chips/CmuxLinkChip.tsx: a workspace's or chat's title) copies as
// the link, as the plain link did before the chips (review of #38166, F3): in a reply's copy, and in
// any other selection that holds one (a sent prompt's text), whose plain text is then the page's
// with each chip's words swapped for its link.
import { copyHref, htmlMarkdown } from "../richClipboard";
import { safeHref } from "../replyHref";

const MATH = "[data-tex]";
/// Attributes the copy keeps; every other one (classes, styles, data, aria) is the transcript's own.
const KEEP = new Set(["href", "start", "colspan", "rowspan", "src", "alt"]);
/// What the transcript draws around the text: icons and hidden labels. A button (a link chip, an
/// image that opens) is unwrapped, its words and picture kept.
/// A list's drawn number and bullet are the list's own markers in the copy (`<ol>`, `<ul>`).
const CHROME = "svg, [aria-hidden='true'], [hidden], .sr-only, .cv-li__num, .cv-li__bullet";
/// A cmux link's chip, whose words are a title: it copies as its link.
const LINK_CHIP = "a[data-cmux-link]";

/// Each cmux link chip in `root` as its link's text, a chip the selection cut into included.
function chipsAsLinks(root: ParentNode) {
  for (const chip of root.querySelectorAll(LINK_CHIP)) chip.replaceWith(chip.getAttribute("href") ?? "");
}

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
  // leaves out the element that holds the TeX). Code is the page's own copy: highlighted code draws
  // in a shadow root a clone leaves empty, and plain code draws each line as its own element, whose
  // indentation and line ends only the page's copy keeps.
  if (
    elementOf(range.startContainer)?.closest(`${MATH}, pre`) ||
    elementOf(range.endContainer)?.closest(`${MATH}, pre`)
  )
    return null;
  for (const element of reply.querySelectorAll("*"))
    if ((element.shadowRoot || element.matches(`${MATH}, pre`)) && range.intersectsNode(element)) return null;
  // A selection inside one table clones bare cells with no row or table around them: the page's
  // own copy keeps their separators.
  if (elementOf(range.commonAncestorContainer)?.closest("table")) return null;
  const holder = document.createElement("div");
  holder.append(range.cloneContents());
  // A selection inside one list clones its items without the list: put them back in it, an ordered
  // list numbered from its first selected item.
  const list = elementOf(range.commonAncestorContainer)?.closest("ul, ol");
  if (list && reply.contains(list) && [...holder.children].some((child) => child.tagName === "LI")) {
    const wrapper = document.createElement(list.tagName.toLowerCase());
    if (list.tagName === "OL") {
      const items = [...list.children].filter((child) => child.tagName === "LI");
      const first = items.findIndex((item) => range.intersectsNode(item));
      const start = (Number(list.getAttribute("start") ?? 1) || 1) + Math.max(first, 0);
      if (start !== 1) wrapper.setAttribute("start", String(start));
    }
    wrapper.append(...holder.childNodes);
    holder.append(wrapper);
  }
  chipsAsLinks(holder);
  for (const element of holder.querySelectorAll(CHROME)) element.remove();
  for (const button of holder.querySelectorAll("button")) button.replaceWith(...button.childNodes);
  for (const element of holder.querySelectorAll("*"))
    for (const name of element.getAttributeNames()) if (!KEEP.has(name)) element.removeAttribute(name);
  // A target goes into another app only where it is safe there (a web or mail link, a web picture).
  for (const link of holder.querySelectorAll("[href]")) {
    const href = copyHref(link.getAttribute("href") ?? "");
    if (href) link.setAttribute("href", href);
    else link.removeAttribute("href");
  }
  for (const image of holder.querySelectorAll("[src]")) {
    const src = safeHref(image.getAttribute("src") ?? "");
    if (src) image.setAttribute("src", src);
    else image.remove();
  }
  return holder.innerHTML;
}

/** The plain text of a selection outside a reply's copy that holds a cmux link chip, each chip as
 * its link; null when it holds none (the page's own copy), or math or code (theirs). */
export function chipSelectionText(range: Range): string | null {
  const chips = [...document.querySelectorAll(LINK_CHIP)].filter((chip) => range.intersectsNode(chip));
  if (!chips.length) return null;
  for (const element of document.querySelectorAll(`${MATH}, pre`)) if (range.intersectsNode(element)) return null;
  // Laid out as the selection's own box is (a prompt's kept line ends), off screen, for its text.
  const around = elementOf(range.commonAncestorContainer);
  const holder = (around?.cloneNode(false) as HTMLElement | undefined) ?? document.createElement("div");
  holder.removeAttribute("id");
  holder.setAttribute("aria-hidden", "true");
  holder.style.cssText = "position:fixed;left:-100000px;top:0;";
  holder.append(range.cloneContents());
  chipsAsLinks(holder);
  for (const element of holder.querySelectorAll(CHROME)) element.remove();
  document.body.append(holder);
  try {
    // innerText reads the layout's line ends; a DOM with no layout has textContent only.
    return (typeof holder.innerText === "string" ? holder.innerText : holder.textContent) ?? "";
  } finally {
    holder.remove();
  }
}

function onCopy(event: ClipboardEvent) {
  if (event.defaultPrevented || !event.clipboardData) return;
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  const html = selectionHtml(range);
  if (!html) {
    const text = chipSelectionText(range);
    if (!text) return;
    event.clipboardData.setData("text/plain", text);
    event.preventDefault();
    return;
  }
  const markdown = htmlMarkdown(html);
  if (!markdown) return;
  event.clipboardData.setData("text/plain", markdown);
  event.clipboardData.setData("text/html", html);
  event.preventDefault();
}
