// SVG sanitizing for the picker's preview and early refusal. The asset owner (the daemon's blob
// store for daemon-owned objects) sanitizes again with the same allowlist before it stores
// anything; this copy only keeps the page from showing or sending an SVG the owner would refuse.
// Allowlist, not denylist: shapes, paint servers, clip paths, masks and internal `<use>` only.
// No scripts, no event attributes, no external references (href, url(), @import), no
// foreignObject, no images, no animation, no text (fonts are external resources).

export const MAX_SVG_BYTES = 64 * 1024;

const ELEMENTS = new Set([
  "svg",
  "g",
  "path",
  "circle",
  "ellipse",
  "line",
  "polyline",
  "polygon",
  "rect",
  "defs",
  "lineargradient",
  "radialgradient",
  "stop",
  "clippath",
  "mask",
  "symbol",
  "use",
  "title",
  "desc",
]);

const ATTRIBUTES = new Set([
  "viewbox",
  "width",
  "height",
  "x",
  "y",
  "x1",
  "x2",
  "y1",
  "y2",
  "cx",
  "cy",
  "r",
  "rx",
  "ry",
  "fx",
  "fy",
  "d",
  "points",
  "transform",
  "fill",
  "fill-opacity",
  "fill-rule",
  "clip-rule",
  "stroke",
  "stroke-width",
  "stroke-opacity",
  "stroke-linecap",
  "stroke-linejoin",
  "stroke-miterlimit",
  "stroke-dasharray",
  "stroke-dashoffset",
  "opacity",
  "offset",
  "stop-color",
  "stop-opacity",
  "gradientunits",
  "gradienttransform",
  "spreadmethod",
  "clippathunits",
  "maskunits",
  "maskcontentunits",
  "clip-path",
  "mask",
  "id",
  "href",
  "xlink:href",
  "preserveaspectratio",
  "xmlns",
  "xmlns:xlink",
  "version",
]);

export type SanitizeResult =
  | { readonly ok: true; readonly svg: string }
  | { readonly ok: false; readonly reason: SanitizeRefusal };
export type SanitizeRefusal = "tooLarge" | "notSVG";

/** An id reference: `#` and an id of letters, digits, `_`, `.` and `-` (the daemon's rule). */
const ID_REFERENCE = /^#[A-Za-z0-9_.-]+$/;

/**
 * A paint or reference value is safe only when every url() names an id in this document and the
 * value has no `\` (escapes could hide a scheme) and no `:` (no scheme, including after `//`).
 * Same rules as the daemon's sanitizer.
 */
function safeReference(value: string): boolean {
  if (value.includes("\\") || value.includes(":")) return false;
  for (const match of value.matchAll(/url\(\s*(['"]?)(.*?)\1\s*\)/gi)) {
    if (!ID_REFERENCE.test(match[2])) return false;
  }
  return !/url\(/i.test(value.replace(/url\(\s*(['"]?)#[A-Za-z0-9_.-]+\1\s*\)/gi, ""));
}

function clean(element: Element, removed: { count: number }) {
  // Array.from: removing nodes while iterating the live collections would skip some.
  for (const child of Array.from(element.children)) {
    if (!ELEMENTS.has(child.localName.toLowerCase()) || child.namespaceURI !== "http://www.w3.org/2000/svg") {
      child.remove();
      removed.count++;
      continue;
    }
    clean(child, removed);
  }
  for (const attribute of Array.from(element.attributes)) {
    const name = attribute.name.toLowerCase();
    const isHref = name === "href" || name === "xlink:href";
    const isNamespace = name === "xmlns" || name === "xmlns:xlink";
    const keep =
      ATTRIBUTES.has(name) &&
      (isNamespace || (isHref ? ID_REFERENCE.test(attribute.value) : safeReference(attribute.value)));
    if (!keep) {
      element.removeAttribute(attribute.name);
      removed.count++;
    }
  }
}

/** The sanitized SVG text, or why it was refused. */
export function sanitizeSVG(text: string, parser: DOMParser = new DOMParser()): SanitizeResult {
  if (new TextEncoder().encode(text).length > MAX_SVG_BYTES) return { ok: false, reason: "tooLarge" };
  const doc = parser.parseFromString(text, "image/svg+xml");
  const root = doc.documentElement;
  if (
    !root ||
    root.localName !== "svg" ||
    root.namespaceURI !== "http://www.w3.org/2000/svg" ||
    doc.querySelector("parsererror")
  ) {
    return { ok: false, reason: "notSVG" };
  }
  clean(root, { count: 0 });
  return { ok: true, svg: new XMLSerializer().serializeToString(root) };
}
