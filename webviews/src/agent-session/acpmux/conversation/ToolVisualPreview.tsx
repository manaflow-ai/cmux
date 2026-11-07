import { useState, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { mediaKind } from "../chips/ReplyMedia";
import { useHoverCard } from "../chips/useHoverCard";
import "./toolVisualPreview.css";

/** Keep audio and video in their existing players, including inline MCP media. */
export function isStillVisual(source: string): boolean {
  return source.startsWith("data:image/") || (!source.startsWith("data:") && !mediaKind(source));
}

export function ToolVisualRow({ sources, label, children }: { sources: string[]; label: string; children: ReactNode }) {
  const source = sources.find(isStillVisual);
  if (!source) return <>{children}</>;
  return (
    <div className="cv-tool-with-visual">
      {children}
      <ToolVisualPreview source={source} label={label} />
    </div>
  );
}

function ToolVisualPreview({ source, label }: { source: string; label: string }) {
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLSpanElement | null>(null);
  // ReplyImage shares the host load with the existing output strip and preserves its path,
  // remote-image, provenance and permission rules. The portal mounts only while previewing.
  const picture = (thumb: boolean) =>
    source.startsWith("data:image/") ? (
      <OpenableImage src={source} alt={label} thumb={thumb} />
    ) : (
      <ReplyImage key={source} src={source} alt={label} thumb={thumb} hideMissing fallback={null} />
    );
  return (
    <>
      <span ref={setAnchor} className="cv-tool-visual" {...hover.trigger}>
        {picture(true)}
      </span>
      <AnchoredCard
        anchor={anchor}
        open={hover.open}
        className="ui-glass ui-glass-floats cv-tool-visual-card"
        side="top"
        interactive
        hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
        onPointerEnter={hover.card.onPointerEnter}
        onPointerLeave={hover.card.onPointerLeave}
        ariaLabel={label}
      >
        <div className="cv-tool-visual-card__body" {...hover.card}>
          {hover.open && picture(false)}
          <span className="cv-tool-visual-card__caption">{label}</span>
        </div>
      </AnchoredCard>
    </>
  );
}
