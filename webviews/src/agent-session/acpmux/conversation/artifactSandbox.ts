// The gallery runs public-safe fixtures in srcdoc. The bundled pane uses the native /artifact
// endpoint, whose response CSP and navigation delegate also deny self-navigation (CSP cannot).
export const ARTIFACT_FRAME_URL = "cmux-agent://render/artifact";
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
