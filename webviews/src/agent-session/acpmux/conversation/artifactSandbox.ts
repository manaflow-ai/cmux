// Passive previews run public-safe markup in srcdoc. Explicit Run uses the native /artifact endpoint,
// whose response CSP and navigation delegate also deny self-navigation (CSP cannot).
export const ARTIFACT_FRAME_URL = "cmux-agent://render/artifact";
export const PAGE_ARTIFACT_FRAME_URL = "cmux-page://cmux.agent/__artifact";

/** Exact bundled parent origins only. An arbitrary page or another custom-scheme host cannot
 * opt into script execution by importing the shared preview. Keep the legacy agent route intact. */
export function artifactFrameURL(): string | undefined {
  if (typeof location === "undefined") return undefined;
  try {
    const url = new URL(location.href);
    if (url.username || url.password || url.port) return undefined;
    const host = url.hostname.toLowerCase();
    if (url.protocol === "cmux-agent:" && host === "pane") return ARTIFACT_FRAME_URL;
    if (url.protocol === "cmux-page:" && (host === "cmux.agent" || host === "cmux.artifacts"))
      return PAGE_ARTIFACT_FRAME_URL;
  } catch {
    // An absent or malformed location grants no native capability.
  }
  return undefined;
}
export const artifactGallery = () =>
  typeof location !== "undefined" &&
  location.pathname.endsWith("/frame.html") &&
  new URLSearchParams(location.search).has("entry");
export const ARTIFACT_POLICY =
  "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";
export function galleryArtifactDocument(html: string, theme: string): string {
  // l10n-allow: HTML document syntax and CSP directives, not user-visible text.
  return `<!doctype html><meta http-equiv="Content-Security-Policy" content="${ARTIFACT_POLICY}"><style>${theme}</style>${html}`;
}

/// Whether an artifact must wait for Run before it receives a frame with script capability. Parse in
/// an inert template when the browser provides one; if parsing is unavailable or throws, fall back to
/// a conservative source check. A false negative is never allowed to grant script capability.
export function artifactNeedsRun(code: string): boolean {
  if (typeof document !== "undefined" && typeof document.createElement === "function") {
    try {
      const template = document.createElement("template");
      template.innerHTML = code;
      for (const element of template.content.querySelectorAll("*")) {
        if (element.localName.toLowerCase() === "script") return true;
        for (const attribute of Array.from(element.attributes)) {
          if (attribute.name.toLowerCase().startsWith("on") || isJavaScriptURL(attribute.value)) return true;
        }
      }
      return false;
    } catch {
      // A parser failure is untrusted input: require explicit Run.
    }
  }
  const decoded = decodeEntities(code);
  // oxlint-disable-next-line no-control-regex -- Match the browser's normalization of a URL scheme.
  const normalized = decoded.replace(/[\u0000-\u0020\u007f-\u009f]/g, "");
  return /<\s*script\b|(?:\s|\/)on[a-z][\w:-]*\s*=/i.test(decoded) || /javascript:/i.test(normalized);
}

function isJavaScriptURL(value: string): boolean {
  return (
    value
      // oxlint-disable-next-line no-control-regex -- URL parsing ignores these controls in a javascript scheme.
      .replace(/[\u0000-\u0020\u007f-\u009f]/g, "")
      .toLowerCase()
      .startsWith("javascript:")
  );
}

function decodeEntities(value: string): string {
  return value
    .replace(
      /&(colon|tab|newline);?/gi,
      (_, name: string) => ({ colon: ":", tab: "\t", newline: "\n" })[name.toLowerCase()]!,
    )
    .replace(/&#x([\da-f]+);?|&#(\d+);?/gi, (_, hex: string | undefined, decimal: string | undefined) => {
      const codePoint = Number.parseInt(hex ?? decimal!, hex ? 16 : 10);
      return Number.isInteger(codePoint) && codePoint >= 0 && codePoint <= 0x10ffff
        ? String.fromCodePoint(codePoint)
        : "";
    });
}
