// The document an inline preview frame draws (InlinePreview.tsx): a closed ```html or ```svg fence in
// a reply, behind the artifact policy (artifactSandbox.ts) with no network at all. The frame is
// sandboxed with `allow-scripts` and never `allow-same-origin`, so its document is an opaque origin
// that cannot reach the pane. Before Run the only script allowed is the client's height reporter,
// which carries a nonce made for that frame: the document's own scripts, handlers and `javascript:`
// URLs are refused by the policy, since text written before the frame existed cannot know the nonce.
// leo-workspace design/artifacts.md.
import { ARTIFACT_POLICY } from "./artifactSandbox";
import { artifactKind, type ArtifactKind } from "./artifactPreview";

/// The frame's sandbox: scripts for the height reporter, and nothing else (no same-origin, top
/// navigation, popups, forms or modals).
export const INLINE_PREVIEW_SANDBOX = "allow-scripts";
/// The message the frame's reporter posts with its document's height.
export const INLINE_PREVIEW_SIZE = "cmux-preview-size";
export const INLINE_PREVIEW_MIN_HEIGHT = 48;
/// The tallest an inline preview draws until the reader expands it; a taller document scrolls.
export const INLINE_PREVIEW_MAX_HEIGHT = 480;
/// The tallest an expanded preview draws.
export const INLINE_PREVIEW_EXPANDED_MAX_HEIGHT = 4000;

/// The kind of document a closed fence previews inline: HTML or SVG (an ```svg fence, or an ```xml one
/// that holds one SVG image). JSX needs the artifact runtime and Markdown already draws as Markdown,
/// so both stay code cards with Open.
export function inlinePreviewKind(lang: string, code: string): Extract<ArtifactKind, "html" | "svg"> | undefined {
  const name = lang.toLowerCase();
  if (name === "jsx" || name === "tsx" || name === "cmux-render" || !code.trim()) return undefined;
  const kind = artifactKind(lang, code);
  return kind === "html" || kind === "svg" ? kind : undefined;
}

/// A fresh nonce for one frame.
export function previewNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// The policy a frame's document runs under: the artifact policy, with scripts limited to `nonce`'s
/// (before Run) or inline scripts (after Run, where no native frame exists: the gallery).
export function previewPolicy(nonce: string | undefined): string {
  return nonce ? ARTIFACT_POLICY.replace("script-src 'unsafe-inline'", `script-src 'nonce-${nonce}'`) : ARTIFACT_POLICY;
}

/// The frame's own script, the first to run in it: it reports the document's height to the parent
/// whenever it changes (ResizeObserver coalesces, so there is no timer, and it goes with the frame),
/// and keeps the frame on its document: a link click is refused (a `#fragment` still scrolls). With
/// `inertMeta` that leaves no way for markup without script to navigate the frame; a frame that
/// leaves its document anyway is torn down by the parent (InlinePreview.tsx counts its loads), since
/// the policy is the document's and a page the frame navigated to would run without it.
const REPORTER = `(()=>{const post=()=>parent.postMessage({type:"${INLINE_PREVIEW_SIZE}",height:Math.ceil(document.documentElement.scrollHeight)},"*");new ResizeObserver(post).observe(document.documentElement);addEventListener("load",post);addEventListener("click",(event)=>{const link=event.target instanceof Element&&event.target.closest("a,area");if(link&&!(link.getAttribute("href")||"").startsWith("#"))event.preventDefault();},true);})();`;

/// The document with every `http-equiv` attribute made inert. `<meta http-equiv="refresh">` is the one
/// way markup with no script navigates its frame by itself (neither the policy nor the sandbox stops
/// it), to a page that would run without the policy. An attribute name cannot be written with an
/// entity or split, and only ASCII case folds, so no spelling survives; text that merely mentions it
/// reads `data-http-equiv` in the preview (Code shows the source as written).
export function inertMeta(html: string): string {
  return html.replace(/http-equiv/gi, "data-http-equiv");
}

/// The `srcdoc` of an inline preview: the policy first, then the pane's theme, the frame's script and
/// the document. `nonce` set: only the frame's script runs (passive). Unset: inline scripts run too
/// (Run, in the gallery).
export function inlinePreviewDocument(
  kind: "html" | "svg",
  code: string,
  theme: string,
  nonce: string | undefined,
): string {
  // An SVG image centers at its own size, no wider than the card. Not the panel's 100vh fit
  // (previewHtml): a frame sized from its document's height would never shrink back from it.
  const html = inertMeta(
    kind === "svg"
      ? `<style>body{display:flex;justify-content:center}svg{max-width:100%;height:auto}</style>${code}`
      : code,
  );
  const script = nonce ? `<script nonce="${nonce}">${REPORTER}</script>` : `<script>${REPORTER}</script>`;
  // l10n-allow: HTML document syntax and CSP directives, not user-visible text.
  return `<!doctype html><meta http-equiv="Content-Security-Policy" content="${previewPolicy(nonce)}"><style>${theme}</style>${script}${html}`;
}

/// The height a frame's report asks for, clamped to the card's bounds; nil for any other message.
export function reportedHeight(data: unknown, max: number): number | undefined {
  if (!data || typeof data !== "object") return undefined;
  const message = data as { type?: unknown; height?: unknown };
  if (message.type !== INLINE_PREVIEW_SIZE || typeof message.height !== "number" || !Number.isFinite(message.height))
    return undefined;
  return Math.min(max, Math.max(INLINE_PREVIEW_MIN_HEIGHT, Math.ceil(message.height)));
}
