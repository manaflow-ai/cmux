// A document a reply carries in a fence (cx-ncc.63, Claude parity): HTML, SVG and Markdown open in the
// side panel beside the chat (ArtifactPanel.tsx), drawn as they render with their source a tab away.
import { createContext } from "react";

export type ArtifactKind = "html" | "svg" | "markdown";
export type Artifact = {
  kind: ArtifactKind;
  lang: string;
  code: string;
  /// The render card it came from (its key, renderCall.ts `renderPages`), whose pages are its versions.
  render?: string;
  /// Stable row/fence identity and the accepted source revision while a reply streams.
  identity?: string;
  revision?: number;
  /** Full file identity when the artifact came from a completed write. */
  path?: string;
};

const KINDS: Record<string, ArtifactKind> = {
  html: "html",
  jsx: "html",
  tsx: "html",
  htm: "html",
  xhtml: "html",
  // A page the reply runs inline (renderCall.ts); its rewrites are versions of one document.
  "cmux-render": "html",
  svg: "svg",
  markdown: "markdown",
  md: "markdown",
};

/// The kind of document a fence holds, when the panel can draw it: its language, or an `xml` fence
/// that holds one SVG image.
export function artifactKind(lang: string | undefined, code: string): ArtifactKind | undefined {
  const name = (lang ?? "").toLowerCase();
  const kind = KINDS[name];
  if (kind) return kind;
  if (name === "xml" && /^\s*(<\?xml[^>]*\?>\s*)?<svg[\s>]/i.test(code)) return "svg";
  return undefined;
}

/// The HTML the render frame draws for a preview: an SVG image centered and fit to the panel.
export function previewHtml(artifact: Artifact): string {
  if (artifact.kind !== "svg") return artifact.code;
  return `<style>body{display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center}svg{max-width:100%;height:auto}</style>${artifact.code}`;
}

/// The name a saved document is offered under: an HTML or SVG `<title>`, a Markdown document's first
/// heading; empty when it has none (the host names it).
export function documentName(artifact: Artifact): string {
  if (artifact.kind === "markdown") {
    // A `#` line inside a code fence is code, not a heading.
    const prose = artifact.code.replace(/^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^ {0,3}\1[^\n]*$|(?![\s\S]))/gm, "");
    const heading = /^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/m.exec(prose);
    return (heading?.[1] ?? "").replace(/\s+/g, " ").trim();
  }
  const title = /<title[^>]*>([^<]*)<\/title>/i.exec(artifact.code)?.[1] ?? "";
  return title
    .replace(/&(amp|lt|gt|quot|#39);/g, (_, name: string) => ENTITIES[name])
    .replace(/\s+/g, " ")
    .trim();
}

/** Prefer a document's own title, then the filename recorded by its completed write. */
export function artifactFileName(artifact: Artifact): string {
  return documentName(artifact) || artifact.path?.split(/[\\/]/).pop() || "";
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" };

/// Opens a fence in the side panel; unset where the page has none (a gallery, a test).
export const ArtifactContext = createContext<((artifact: Artifact) => void) | undefined>(undefined);
