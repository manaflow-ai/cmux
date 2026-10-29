// Shared read-only HTML/SVG preview. The caller supplies localized UI and owns layout; this
// component owns the passive sandbox, explicit Run gate and native one-shot render transport.
import { useState, type ReactNode } from "react";
import { artifactFrameURL, artifactGallery, artifactNeedsRun, galleryArtifactDocument } from "./artifactSandbox";
import { renderFrameCSS } from "./renderBase";
import { ranRenders, useRenderFrame } from "./renderFrame";

export type ArtifactPreviewProps = {
  html: string;
  title: string;
  runLabel: string;
  /** JSX needs Run before compilation even if its source contains no script element. */
  requiresRun?: boolean;
  /** An optional renderer (such as JSX compilation), mounted only after the Run gate. */
  children?: ReactNode;
};

export function ArtifactPreview(props: ArtifactPreviewProps) {
  // Capability is checked here too, so a consumer cannot bypass the panel's source-only fallback.
  if (!artifactFrameURL() && !artifactGallery()) return null;
  // A changed document never inherits the mounted component's prior Run state.
  return <PreviewDocument key={props.html} {...props} />;
}

function PreviewDocument({ html, title, runLabel, requiresRun, children }: ArtifactPreviewProps) {
  const [allowed, setAllowed] = useState(() => ranRenders.has(html));
  if (!requiresRun && !artifactNeedsRun(html))
    return (
      <iframe
        className="acpmux-artifact-frame"
        srcDoc={galleryArtifactDocument(html, renderFrameCSS())}
        title={title}
        sandbox=""
        referrerPolicy="no-referrer"
      />
    );
  if (!allowed)
    return (
      <div className="acpmux-artifact-run">
        <button
          type="button"
          className="acpmux-review-changes"
          onClick={() => {
            ranRenders.add(html);
            setAllowed(true);
          }}
        >
          {runLabel}
        </button>
      </div>
    );
  return children ?? <ArtifactRunningFrame html={html} title={title} />;
}

/** Native frame used only after Run, including after JSX compilation. Gallery fixtures retain
 * their existing scripted srcdoc fallback; ordinary dev pages never receive that capability. */
export function ArtifactRunningFrame({ html, title }: { html: string; title: string }) {
  const { frame } = useRenderFrame(html);
  const endpoint = artifactFrameURL();
  const gallery = !endpoint && artifactGallery();
  if (!endpoint && !gallery) return null;
  return (
    <iframe
      ref={frame}
      className="acpmux-artifact-frame"
      src={gallery ? undefined : endpoint}
      srcDoc={gallery ? galleryArtifactDocument(html, renderFrameCSS()) : undefined}
      title={title}
      sandbox="allow-scripts"
      referrerPolicy="no-referrer"
    />
  );
}
