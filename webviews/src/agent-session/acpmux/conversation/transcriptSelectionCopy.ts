// A selection spanning message bodies keeps their Markdown structure. Walk only intersecting
// bodies, not transcript chrome; complete code cards use the same source as Copy Code, since
// their highlighted lines live in a shadow root and Range.cloneContents cannot read them.
import { menuPartAt } from "./menuParts";

const BODY = ".cv-md, .cv-user__text";
const OMIT = "svg, [aria-hidden='true'], [hidden], .sr-only, .cv-li__num, .cv-li__bullet, script, style";
const CHROME = `${OMIT}, .cv-iconbtn, .cv-user__actions, .cv-turn-actions, .cv-message-footer-row, .cv-user__more, time`;

function elementOf(node: Node): Element | null {
  return node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
}

/** Null leaves a selection outside message text, or inside a code card, to its existing copier. */
export function transcriptSelectionContents(range: Range): HTMLElement | null {
  const first = elementOf(range.startContainer)?.closest(BODY);
  const last = elementOf(range.endContainer)?.closest(BODY);
  if (!first || !last || first === last) return null;
  if (
    elementOf(range.startContainer)?.closest(".cv-codeblock, pre") ||
    elementOf(range.endContainer)?.closest(".cv-codeblock, pre")
  )
    return null;
  const scope = elementOf(range.commonAncestorContainer);
  if (!scope) return null;
  const holder = range.startContainer.ownerDocument!.createElement("div");
  // Do not silently drop tool results, attachments or new kinds of transcript rows. Only known
  // message bodies and their controls are safe to serialize; everything else keeps page copy.
  const supported = (node: Node): boolean => {
    if (!range.intersectsNode(node)) return true;
    if (node.nodeType === Node.TEXT_NODE) return !(node.textContent ?? "").trim();
    if (node.nodeType !== Node.ELEMENT_NODE) return true;
    const element = node as Element;
    if (element.matches(CHROME)) return true;
    if (element.matches(BODY)) return true;
    if (element.matches("img, video, canvas, pre, button") || element.shadowRoot) return false;
    return [...element.childNodes].every(supported);
  };
  if (!supported(scope)) return null;
  const literal = (value: string): HTMLElement => {
    const span = holder.ownerDocument.createElement("span");
    span.setAttribute("style", "white-space: pre-wrap;");
    span.textContent = value;
    return span;
  };
  let unsupported = false;
  const clone = (node: Node): Node | null => {
    if (!range.intersectsNode(node)) return null;
    if (node.nodeType === Node.TEXT_NODE) {
      const value = node.textContent ?? "";
      const start = node === range.startContainer ? range.startOffset : 0;
      const end = node === range.endContainer ? range.endOffset : value.length;
      const selected = value.slice(start, end);
      return node.parentElement?.closest(BODY)?.matches(".cv-user__text")
        ? literal(selected)
        : holder.ownerDocument.createTextNode(selected);
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    const element = node as HTMLElement;
    if (element.matches(CHROME)) return null;
    if (
      element.matches("img, video, canvas, button") ||
      (element.tagName === "TABLE" && (element.contains(range.startContainer) || element.contains(range.endContainer)))
    ) {
      unsupported = true;
      return null;
    }
    if (element.matches(".cv-math-source")) return literal(element.textContent ?? "");
    if (element.matches(".cv-code-handoff")) {
      // During the handoff both plain and highlighted cards are mounted with the same source.
      const card = element.querySelector(".cv-codeblock");
      return card ? clone(card) : null;
    }
    if (element.matches(".cv-codeblock")) {
      const part = menuPartAt(element);
      const source = part?.code;
      if (source === undefined) {
        unsupported = true;
        return null;
      }
      const pre = holder.ownerDocument.createElement("pre");
      const code = holder.ownerDocument.createElement("code");
      code.textContent = source;
      if (part?.codeLanguage && /^[\w+#-]+$/.test(part.codeLanguage)) code.className = `language-${part.codeLanguage}`;
      pre.append(code);
      return pre;
    }
    if (element.shadowRoot) {
      unsupported = true;
      return null;
    }
    if (element.hasAttribute("data-tex")) {
      const display = element.matches(".cv-math-display, .cv-math--display");
      const fence = display ? "$$" : "$";
      return holder.ownerDocument.createTextNode(`${fence}${element.getAttribute("data-tex") ?? ""}${fence}`);
    }
    const copy = element.cloneNode(false) as HTMLElement;
    // A partial ordered list still starts at the first selected item's number.
    if (element.tagName === "OL") {
      const items = [...element.children].filter((child) => child.tagName === "LI");
      const firstItem = items.findIndex((item) => range.intersectsNode(item));
      const start = (Number(element.getAttribute("start") ?? 1) || 1) + Math.max(firstItem, 0);
      if (start !== 1) copy.setAttribute("start", String(start));
    }
    for (const child of element.childNodes) {
      const selected = clone(child);
      if (selected) copy.append(selected);
    }
    return copy;
  };
  for (const body of scope.querySelectorAll(BODY)) {
    // A Markdown prompt is inside cv-user__text: copy it only once.
    if (body.parentElement?.closest(BODY) || !range.intersectsNode(body)) continue;
    const selected = clone(body);
    if (selected) holder.append(selected);
  }
  return unsupported || !holder.hasChildNodes() ? null : holder;
}
