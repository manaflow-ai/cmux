// Copying a selection inside a reply (Cmd-C) puts the reply's formatting on the clipboard as Claude
// and ChatGPT do: clean HTML (headings, bullets, bold, links, code, tables) with no transcript
// classes, colors or fonts, so a paste into Notes, Slack, Docs or Mail reads as the reply did and
// never takes the pane's dark-theme colors; and the same selection as Markdown for its plain text, so
// a paste into the composer or a terminal keeps its bullets (richClipboard.ts).
//
// Across messages it copies the selected message bodies, including complete code cards, without
// timestamps or controls. Inside one message, math and code retain their specialized copy paths.
import { copyHref, htmlMarkdown } from "../richClipboard";
import { safeHref } from "../replyHref";
import { transcriptSelectionContents } from "./transcriptSelectionCopy";

const MATH = "[data-tex]";
/// Attributes the copy keeps; every other one (classes, styles, data, aria) is the transcript's own.
const KEEP = new Set(["href", "start", "colspan", "rowspan", "src", "alt"]);
/// What the transcript draws around the text: icons and hidden labels. A button (a link chip, an
/// image that opens) is unwrapped, its words and picture kept.
/// A list's drawn number and bullet are the list's own markers in the copy (`<ol>`, `<ul>`).
const CHROME = "svg, [aria-hidden='true'], [hidden], .sr-only, .cv-li__num, .cv-li__bullet";
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
  if (!reply) {
    const transcript = transcriptSelectionContents(range);
    return transcript ? cleanSelectionHtml(transcript) : null;
  }
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
  return cleanSelectionHtml(holder);
}

function cleanSelectionHtml(holder: HTMLElement): string {
  for (const element of holder.querySelectorAll(CHROME)) element.remove();
  for (const button of holder.querySelectorAll("button")) button.replaceWith(...button.childNodes);
  for (const element of holder.querySelectorAll("*"))
    for (const name of element.getAttributeNames()) {
      // A fenced code language is content metadata, not the transcript's styling.
      if (name === "class" && element.tagName === "CODE" && /^language-[\w+#-]+$/.test(element.className)) continue;
      // Plain prompts rely on pre-wrap for their line ends and indentation. This one safe style
      // is content layout; no transcript colors or fonts travel with it.
      if (name === "style" && element.tagName === "SPAN" && element.getAttribute(name) === "white-space: pre-wrap;")
        continue;
      if (!KEEP.has(name)) element.removeAttribute(name);
    }
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
