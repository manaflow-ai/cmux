// The document an inline preview frame draws (InlinePreview.tsx): a closed ```html or ```svg fence in
// a reply, behind the artifact policy (artifactSandbox.ts) with no network at all. The frame is
// sandboxed with `allow-scripts` and never `allow-same-origin`, so its document is an opaque origin
// that cannot reach the pane. The only script allowed is the client's own frame script,
// which carries a nonce made for that frame: the document's own scripts, handlers and `javascript:`
// URLs are refused by the policy, since text written before the frame existed cannot know the nonce.
// A document that carries script never previews inline (InlinePreview.tsx): it opens in the side
// panel, where Run is.
// leo-workspace design/artifacts.md.
import { ARTIFACT_POLICY, artifactNeedsRun } from "./artifactSandbox";
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

/// The policy a frame's document runs under: the artifact policy, with scripts limited to `nonce`'s.
/// Without one, inline scripts run under the sandbox alone (the isolation test's case).
export function previewPolicy(nonce: string | undefined): string {
  return nonce ? ARTIFACT_POLICY.replace("script-src 'unsafe-inline'", `script-src 'nonce-${nonce}'`) : ARTIFACT_POLICY;
}

/// The frame's own script, the first to run in it: it reports the document's height to the parent
/// whenever it changes (ResizeObserver coalesces, so there is no timer, and it goes with the frame),
/// and keeps the frame on its document: every link click is refused, and a `#fragment` scrolls to its
/// target here (in srcdoc a `#x` resolves against the parent page, so following it would leave). With
/// `inertDocument` that leaves no way for markup without script to navigate the frame; a frame that
/// leaves its document anyway is torn down by the parent (InlinePreview.tsx counts its loads), since
/// the policy is the document's and a page the frame navigated to would run without it.
const REPORTER = `(()=>{const post=()=>parent.postMessage({type:"${INLINE_PREVIEW_SIZE}",height:Math.ceil(document.documentElement.scrollHeight)},"*");new ResizeObserver(post).observe(document.documentElement);addEventListener("load",post);addEventListener("click",(event)=>{const link=event.target instanceof Element&&event.target.closest("a,area");if(!link)return;event.preventDefault();const href=link.getAttribute("href")||"";if(href.length>1&&href.startsWith("#")){const id=decodeURIComponent(href.slice(1));(document.getElementById(id)||document.getElementsByName(id)[0])?.scrollIntoView();}},true);})();`;

/// A link attribute and its value; the character before it keeps it an attribute boundary (text that
/// merely reads `href=` is renamed too, which only changes what the preview shows).
/// The boundary is a lookbehind, never consumed: a quote that closes one attribute's value is also
/// the boundary before the next (`<a xlink:href="#x"href="https://…">`).
const LINK_ATTRIBUTE = /(?<=[\s"'/])((?:xlink:)?href)(\s*=\s*)("[^"]*"|'[^']*'|[^\s"'=<>`]+)/gi;

/// The document with what the policy cannot stop made inert. Every link that leaves the document
/// (`href` and `xlink:href` other than a `#fragment` or an inline `data:`/`blob:` image): an engine
/// may resolve its host speculatively, which the policy does not stop, so it becomes `#` and the
/// original stays in `data-href` (a click on it is refused anyway). Every `http-equiv` attribute:
/// `<meta http-equiv="refresh">` is the one way markup with no script navigates its frame by itself
/// (neither the policy nor the sandbox stops it), to a page that would run without the policy. Every
/// `<link>` element: resource hints (`dns-prefetch`, `preconnect`) reach the network outside
/// `connect-src` and `default-src`. A tag or attribute name cannot be written with an entity or
/// split, and only ASCII case folds, so no spelling survives; an unknown `<cmux-inert-link>` does
/// nothing, and text that merely mentions either reads renamed in the preview (Code shows the source
/// as written).
export function inertDocument(html: string): string {
  return html
    .replace(/http-equiv/gi, "data-http-equiv")
    .replace(/<link(?=[\s/>])/gi, "<cmux-inert-link")
    .replace(LINK_ATTRIBUTE, (whole, name: string, equals: string, value: string) => {
      const target = value.replace(/^["']|["']$/g, "");
      if (target.startsWith("#") || /^(?:data|blob):/i.test(target)) return whole;
      // `#` unquoted and first: the rewrite may sit inside another attribute's value
      // (`title="href='x' …"`), where a quote it added would close that value and expose what
      // follows as live attributes; and the original value, last, ends exactly where it did, so the
      // rest of the tag reads as written (an unquoted `#` before `/>` would swallow the slash).
      return `${name}=# data-${name}${equals}${value}`;
    });
}

/// The inert document of script-free markup, or nil when the rewrite left it needing Run after all
/// (`artifactNeedsRun` of the result, parsed as the frame would): only then may it go to a frame
/// that allows inline script (the native artifact frame), since the rewrite is text, not a parse.
export function passiveDocument(html: string): string | undefined {
  const inert = inertDocument(html);
  return artifactNeedsRun(html) || artifactNeedsRun(inert) ? undefined : inert;
}

/// Turns off the browser's own DNS prefetch of the document's link targets.
const NO_DNS_PREFETCH = '<meta http-equiv="x-dns-prefetch-control" content="off">';

/// The document an inline preview draws, made inert (`inertDocument`): an SVG image centered at its
/// own size, no wider than the card (not the panel's 100vh fit, previewHtml: a frame sized from its
/// document's height would never shrink back from it). The native artifact frame takes this as is.
export function inlinePreviewHtml(kind: "html" | "svg", code: string): string {
  return inertDocument(
    kind === "svg"
      ? `<style>body{display:flex;justify-content:center}svg{max-width:100%;height:auto}</style>${code}`
      : code,
  );
}

/// The `srcdoc` of an inline preview (the gallery, which has no native frame; a srcdoc frame takes
/// its parent's policy too, which in the app allows no inline script): the policy first, then the pane's theme, the frame's script and
/// the document. `nonce` set: only the frame's script runs. Unset: inline scripts run too, under the
/// sandbox alone.
export function inlinePreviewDocument(
  kind: "html" | "svg",
  code: string,
  theme: string,
  nonce: string | undefined,
): string {
  return previewFrameDocument(inlinePreviewHtml(kind, code), theme, nonce);
}

/// The `srcdoc` of a preview frame around `html`, which the caller has made inert (`inertDocument`):
/// the inline preview's, and the side panel's passive frame in the gallery (ArtifactPanel.tsx).
export function previewFrameDocument(html: string, theme: string, nonce: string | undefined): string {
  const script = nonce ? `<script nonce="${nonce}">${REPORTER}</script>` : `<script>${REPORTER}</script>`;
  // l10n-allow: HTML document syntax and CSP directives, not user-visible text.
  return `<!doctype html><meta http-equiv="Content-Security-Policy" content="${previewPolicy(nonce)}">${NO_DNS_PREFETCH}<style>${theme}</style>${script}${html}`;
}

/// The height a frame's report asks for, clamped to the card's bounds; nil for any other message.
export function reportedHeight(data: unknown, max: number): number | undefined {
  if (!data || typeof data !== "object") return undefined;
  const message = data as { type?: unknown; height?: unknown };
  if (message.type !== INLINE_PREVIEW_SIZE || typeof message.height !== "number" || !Number.isFinite(message.height))
    return undefined;
  return Math.min(max, Math.max(INLINE_PREVIEW_MIN_HEIGHT, Math.ceil(message.height)));
}
