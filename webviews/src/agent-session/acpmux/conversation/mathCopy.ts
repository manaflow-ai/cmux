// Copying a selection that holds typeset math (Math.tsx) puts the TeX on the clipboard as the
// reply wrote it: `$…$` inline, `$$…$$` on its own line, instead of KaTeX's glyphs and MathML.
// A selection that starts or ends inside an equation takes the whole equation. The HTML copy
// keeps the reply's formatting with each equation as its source.
//
// It takes over only a selection inside one reply's Markdown (`.cv-md`) and reads what the page
// shows: text that cannot be selected (`user-select: none`) or is hidden stays out. A selection
// with no math, one across replies, or one that holds highlighted code (drawn in a shadow root
// the copy cannot read) copies as the page would copy it. Installed when KaTeX first loads.

const MATH = "[data-tex]";
const BLOCK = /^(P|DIV|LI|PRE|BLOCKQUOTE|H[1-6]|UL|OL|TABLE|TR|FIGURE)$/;
const CELL = /^(TD|TH)$/;

let installed = false;

export function installMathCopy() {
  if (installed || typeof document === "undefined") return;
  installed = true;
  document.addEventListener("copy", onCopy);
}

function elementOf(node: Node): Element | null {
  return node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
}

function onCopy(event: ClipboardEvent) {
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed || !event.clipboardData) return;
  const range = selection.getRangeAt(0).cloneRange();
  const first = elementOf(range.startContainer)?.closest<HTMLElement>(MATH);
  if (first) range.setStartBefore(first);
  const last = elementOf(range.endContainer)?.closest<HTMLElement>(MATH);
  if (last) range.setEndAfter(last);
  if (!elementOf(range.commonAncestorContainer)?.closest(".cv-md")) return;
  const text = plainText(range);
  if (text === null) return;
  event.clipboardData.setData("text/plain", text);
  event.clipboardData.setData("text/html", html(range));
  event.preventDefault();
}

function skipped(element: Element): boolean {
  const style = getComputedStyle(element);
  const select = style.userSelect || style.getPropertyValue("-webkit-user-select");
  return select === "none" || style.display === "none" || style.visibility === "hidden";
}

/**
 * The selection's text as shown, each equation as its TeX and a line break around each block;
 * null when it holds no math or reaches into a shadow root.
 */
function plainText(range: Range): string | null {
  let out = "";
  let math = false;
  let shadow = false;
  const breakLine = () => {
    if (out && !out.endsWith("\n")) out += "\n";
  };
  const walk = (node: Node) => {
    if (shadow || !range.intersectsNode(node)) return;
    if (node.nodeType === Node.TEXT_NODE) {
      const value = node.textContent ?? "";
      const start = node === range.startContainer ? range.startOffset : 0;
      const end = node === range.endContainer ? range.endOffset : value.length;
      out += value.slice(start, end);
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const element = node as HTMLElement;
    if (element.shadowRoot) {
      shadow = true;
      return;
    }
    if (element.matches(MATH)) {
      math = true;
      const tex = element.dataset.tex ?? "";
      if (element.classList.contains("cv-math-display")) {
        breakLine();
        out += `$$${tex}$$\n`;
      } else out += element.classList.contains("cv-math--display") ? `$$${tex}$$` : `$${tex}$`;
      return;
    }
    if (skipped(element)) return;
    if (element.tagName === "BR") {
      out += "\n";
      return;
    }
    const block = BLOCK.test(element.tagName);
    if (block) breakLine();
    if (CELL.test(element.tagName) && out && !out.endsWith("\n") && !out.endsWith("\t")) out += "\t";
    element.childNodes.forEach(walk);
    if (block) breakLine();
  };
  walk(range.commonAncestorContainer);
  if (!math || shadow) return null;
  return out.replace(/\n+$/, "");
}

/** The selection's HTML with each equation replaced by its TeX. */
function html(range: Range): string {
  const holder = document.createElement("div");
  holder.append(range.cloneContents());
  for (const element of holder.querySelectorAll<HTMLElement>(MATH)) {
    const tex = element.dataset.tex ?? "";
    const display = element.classList.contains("cv-math-display") || element.classList.contains("cv-math--display");
    element.replaceWith(document.createTextNode(display ? `$$${tex}$$` : `$${tex}$`));
  }
  return holder.innerHTML;
}
