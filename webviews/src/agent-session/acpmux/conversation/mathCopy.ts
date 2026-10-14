// Copying a selection that holds typeset math (Math.tsx) puts the TeX on the clipboard as the
// reply wrote it: `$…$` inline, `$$…$$` on its own line, instead of KaTeX's glyphs and MathML.
// A selection that starts or ends inside an equation takes the whole equation. A selection
// with no math copies as the page would copy it. Installed when KaTeX first loads.

const MATH = "[data-tex]";
const BLOCK = /^(P|DIV|LI|PRE|BLOCKQUOTE|H[1-6]|UL|OL|TABLE|TR)$/;

let installed = false;

export function installMathCopy() {
  if (installed || typeof document === "undefined") return;
  installed = true;
  document.addEventListener("copy", onCopy);
}

function mathAround(node: Node): HTMLElement | null {
  const element = node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
  return element?.closest<HTMLElement>(MATH) ?? null;
}

function onCopy(event: ClipboardEvent) {
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed || !event.clipboardData) return;
  const range = selection.getRangeAt(0).cloneRange();
  const first = mathAround(range.startContainer);
  if (first) range.setStartBefore(first);
  const last = mathAround(range.endContainer);
  if (last) range.setEndAfter(last);
  const fragment = range.cloneContents();
  if (!fragment.querySelector(MATH)) return;
  event.clipboardData.setData("text/plain", plainText(fragment));
  event.preventDefault();
}

/** The fragment's text with each equation as its TeX and a line break around each block. */
function plainText(fragment: DocumentFragment): string {
  let out = "";
  const breakLine = () => {
    if (out && !out.endsWith("\n")) out += "\n";
  };
  const walk = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      out += node.textContent ?? "";
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      node.childNodes.forEach(walk);
      return;
    }
    const element = node as HTMLElement;
    if (element.matches(MATH)) {
      const tex = element.dataset.tex ?? "";
      if (element.classList.contains("cv-math-display")) {
        breakLine();
        out += `$$${tex}$$\n`;
      } else out += element.classList.contains("cv-math--display") ? `$$${tex}$$` : `$${tex}$`;
      return;
    }
    if (element.tagName === "BR") {
      out += "\n";
      return;
    }
    const block = BLOCK.test(element.tagName);
    if (block) breakLine();
    element.childNodes.forEach(walk);
    if (block) breakLine();
  };
  walk(fragment);
  return out.replace(/\n+$/, "");
}
