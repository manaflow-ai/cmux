// A recorded document: reply fences and completed file writes use one model. JSX is source only;
// HTML, SVG and Markdown can preview through the panel's existing renderers.
import { createContext } from "react";

export type ArtifactKind = "html" | "svg" | "markdown" | "jsx";
export type Artifact = {
  kind: ArtifactKind;
  lang: string;
  code: string;
  /// The render card it came from (its key, renderCall.ts `renderPages`), whose pages are its versions.
  render?: string;
  /// Written file identity, never a request to read or execute its path.
  path?: string;
  canonical?: string;
};

const KINDS: Record<string, ArtifactKind> = {
  html: "html",
  htm: "html",
  xhtml: "html",
  // A page the reply runs inline (renderCall.ts); its rewrites are versions of one document.
  "cmux-render": "html",
  svg: "svg",
  jsx: "jsx",
  markdown: "markdown",
  md: "markdown",
};

/// The kind of document a fence holds, when the panel can draw it: its language, or an `xml` fence
/// that holds one SVG image.
export function artifactKind(lang: string | undefined, code: string): ArtifactKind | undefined {
  const name = (lang ?? "").trim().toLowerCase();
  const kind = KINDS[name];
  if (kind) return kind;
  if (name === "xml" && /^\s*(<\?xml[^>]*\?>\s*)?<svg[\s>]/i.test(code)) return "svg";
  return undefined;
}

/// The HTML the render frame draws for an HTML/SVG preview. JSX never enters this renderer.
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

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" };

/// Opens a fence in the side panel; unset where the page has none (a gallery, a test).
export const ArtifactContext = createContext<((artifact: Artifact) => void) | undefined>(undefined);

/// Stable file identity when the harness supplied a path, without resolving or reading that path.
export const artifactPath = (artifact: Artifact): string | undefined =>
  artifact.path ? (artifact.canonical ?? artifact.path) : undefined;
