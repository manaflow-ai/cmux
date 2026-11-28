// The text of a paste. WebKit withholds a paste's text/plain whenever the pasteboard holds file
// URLs (so a page never reads a file's path), and gives only its files and its HTML. A copy of
// text with an image beside it (a composer's Select All and Copy, Notes, Mail, a chat with a
// screenshot in it) then pasted as the image alone (issue 59851: "it only copies the image and not
// the text"). Its text is still in the HTML: every composer reads a paste's text here.

const BLOCK_TAG = /^(P|DIV|LI|PRE|BLOCKQUOTE|H[1-6]|UL|OL|TABLE|TR|SECTION|ARTICLE|HEADER|FOOTER)$/;
const KEEPS_SPACES = /white-space\s*:\s*(pre|pre-wrap|break-spaces)\b/i;
const KEEPS_LINES = /white-space\s*:\s*pre-line\b/i;

/** HTML pasted with no plain text, as its text: each `<br>` and block (a `<p>`) ends a line, and
 * text laid out as written (`<pre>`, `white-space: pre-wrap`, as a composer's copy is) keeps its
 * own line ends and spaces. */
export function htmlText(html: string): string {
  if (!html) return "";
  const template = document.createElement("template");
  template.innerHTML = html;
  let out = "";
  const walk = (node: Node, space: "collapse" | "lines" | "keep") => {
    if (node.nodeType === Node.TEXT_NODE) {
      const text = (node.textContent ?? "").replace(/\r\n?/g, "\n");
      out += space === "keep" ? text : space === "lines" ? text.replace(/[^\S\n]+/g, " ") : text.replace(/\s+/g, " ");
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const element = node as Element;
    const tag = element.tagName;
    if (tag === "BR") {
      out += "\n";
      return;
    }
    if (tag === "STYLE" || tag === "SCRIPT" || tag === "META" || tag === "TITLE" || element.hasAttribute("hidden"))
      return;
    const style = element.getAttribute("style") ?? "";
    const inner = tag === "PRE" || KEEPS_SPACES.test(style) ? "keep" : KEEPS_LINES.test(style) ? "lines" : space;
    const block = BLOCK_TAG.test(tag);
    if (block && out && !out.endsWith("\n")) out += "\n";
    for (const child of element.childNodes) walk(child, inner);
    if (block) out += "\n";
  };
  for (const child of template.content.childNodes) walk(child, "collapse");
  return out.replace(/[ \t]+\n/g, "\n").replace(/^\n+|\n+$/g, "");
}

/** The text a paste carries: its plain text, or, when WebKit withheld that for the files beside
 * it, its HTML's text. */
export function pastedPlainText(transfer: Pick<DataTransfer, "getData" | "files">): string {
  const plain = transfer.getData("text/plain");
  if (plain || !transfer.files.length) return plain;
  return htmlText(transfer.getData("text/html"));
}
