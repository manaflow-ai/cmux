// The preview of an HTML block (README badges, <details>, <p align="center"><img></p>): parsed
// inertly and rebuilt from an allowlist, so a markdown file cannot run script or load anything but
// its own images in the page. The editor keeps the HTML source verbatim; this is display only.
const TAGS = new Set([
  "a",
  "abbr",
  "b",
  "blockquote",
  "br",
  "code",
  "dd",
  "del",
  "details",
  "div",
  "dl",
  "dt",
  "em",
  "figcaption",
  "figure",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "i",
  "img",
  "ins",
  "kbd",
  "li",
  "mark",
  "ol",
  "p",
  "picture",
  "pre",
  "q",
  "s",
  "samp",
  "small",
  "source",
  "span",
  "strong",
  "sub",
  "summary",
  "sup",
  "table",
  "tbody",
  "td",
  "tfoot",
  "th",
  "thead",
  "tr",
  "u",
  "ul",
  "var",
]);
const ATTRIBUTES = new Set([
  "align",
  "alt",
  "colspan",
  "height",
  "href",
  "open",
  "rowspan",
  "src",
  "srcset",
  "title",
  "width",
]);

/** A safe copy of `html` as a fragment; images go through `imageURL`, links keep their href. */
export function htmlPreview(html: string, imageURL: (src: string) => string): DocumentFragment | null {
  const parsed = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html").body;
  const fragment = document.createDocumentFragment();
  copyChildren(parsed, fragment, imageURL);
  return fragment.childNodes.length ? fragment : null;
}

function copyChildren(from: Node, to: Node, imageURL: (src: string) => string): void {
  for (const child of Array.from(from.childNodes)) {
    if (child.nodeType === 3) {
      to.appendChild(document.createTextNode(child.textContent ?? ""));
      continue;
    }
    if (child.nodeType !== 1) continue;
    const element = child as Element;
    const tag = element.tagName.toLowerCase();
    if (!TAGS.has(tag)) {
      // Unknown wrappers keep their content; script, style and embeds are dropped whole.
      if (!["script", "style", "iframe", "object", "embed", "template", "noscript", "svg", "math"].includes(tag)) {
        copyChildren(element, to, imageURL);
      }
      continue;
    }
    const copy = document.createElement(tag);
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (!ATTRIBUTES.has(name)) continue;
      let value = attribute.value;
      if (name === "href" && /^\s*(javascript|data|vbscript):/i.test(value)) continue;
      if (name === "src") value = imageURL(value);
      if (name === "srcset") continue;
      copy.setAttribute(name, value);
    }
    copyChildren(element, copy, imageURL);
    to.appendChild(copy);
  }
}
