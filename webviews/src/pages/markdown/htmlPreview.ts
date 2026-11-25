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

/** A safe copy of `html`; images go through `imageURL`, and blocked remote images get a control. */
export function htmlPreview(
  html: string,
  imageURL: (src: string) => string,
  blockedImage?: (src: string, alt: string) => HTMLElement,
): DocumentFragment | null {
  const parsed = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html").body;
  const fragment = document.createDocumentFragment();
  copyChildren(parsed, fragment, imageURL, blockedImage);
  return fragment.childNodes.length ? fragment : null;
}

function copyChildren(
  from: Node,
  to: Node,
  imageURL: (src: string) => string,
  blockedImage?: (src: string, alt: string) => HTMLElement,
): void {
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
        copyChildren(element, to, imageURL, blockedImage);
      }
      continue;
    }
    const source = tag === "img" ? (element.getAttribute("src") ?? "").trim() : "";
    const resolvedSource = source ? imageURL(source) : "";
    if (source && !resolvedSource && /^https?:\/\//i.test(source) && blockedImage) {
      to.appendChild(blockedImage(source, element.getAttribute("alt") ?? ""));
      continue;
    }
    const copy = document.createElement(tag);
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      // Preserve an authored name on an image-only link; keep all other attributes allowlisted.
      if (!ATTRIBUTES.has(name) && !(tag === "a" && name === "aria-label")) continue;
      let value = attribute.value;
      if (name === "href" && /^\s*(javascript|data|vbscript):/i.test(value)) continue;
      if (name === "src") {
        value = tag === "img" && value.trim() === source ? resolvedSource : imageURL(value);
        if (!value) continue;
      }
      if (name === "srcset") continue;
      copy.setAttribute(name, value);
    }
    copyChildren(element, copy, imageURL, blockedImage);
    to.appendChild(copy);
  }
}
