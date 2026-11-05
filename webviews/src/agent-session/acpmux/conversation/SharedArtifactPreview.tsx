// Shared read-only HTML/SVG preview for every page the opaque artifact host serves (the agent pane
// and the Artifacts page). The caller owns layout; this is the side panel's own frame (ArtifactPanel.tsx
// ArtifactFrame: inert passive markup in the native artifact frame, an explicit Run gate for script),
// behind the same capability check the panel makes, so a consumer cannot bypass the source-only fallback.
import { ArtifactFrame } from "./ArtifactPanel";
import { artifactCanRender, artifactGallery } from "./artifactSandbox";
import { canRender } from "./RenderCard";

export type ArtifactPreviewProps = {
  html: string;
  title: string;
  /** The source shown when the preview cannot draw it; defaults to `html`. */
  code?: string;
  lang?: string;
  /** JSX needs Run and compilation even if its source contains no script element. */
  jsx?: boolean;
  /** A render tool call's page, drawn in the render frame. */
  render?: boolean;
};

export function ArtifactPreview({
  html,
  title,
  code = html,
  lang = "html",
  jsx = false,
  render = false,
}: ArtifactPreviewProps) {
  if (!(render ? canRender() : artifactCanRender()) && !artifactGallery()) return null;
  // A changed document never inherits the mounted frame's prior Run state.
  return <ArtifactFrame key={html} html={html} code={code} lang={lang} title={title} jsx={jsx} render={render} />;
}
