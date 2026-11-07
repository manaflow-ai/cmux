// A pasted or dropped attachment still being read: its tile is the composer's own glass (ui-glass
// ui-glass-material, never a solid fill), dim at first and coming up as it loads, and only a read
// that passes 400 ms shows an indicator (Leo, 2026-11-07: "do we necessarily need a spinner for it?
// Or should it just sort of, like, be dimmed to start and then, like, gradually become more there as
// it actually loads in? ... Or actually, could we do both?"). The look is the experiment's arm
// (pastePlaceholder.experiment.ts, read by pasteLoadingLook.ts); the motion is CSS only (composerAttachments.css "Loading"), with
// no timer: each animation runs once and ends, and the tile leaves with the read.
import type { ReactNode } from "react";
import { Spinner } from "../conversation/icons";

/// What a loading tile shows inside its glass: an upload's progress ring (`upload`, its
/// attachmentIntake.tsx UploadProgress), else the arm's late indicator; both fade in only after
/// 400 ms (`.acpmux-paste-late`).
export function PasteLoadingMark({
  look,
  upload,
  size,
  className,
}: {
  look: string;
  upload: ReactNode;
  size: number;
  className?: string;
}) {
  if (upload) return <span className="acpmux-paste-late">{upload}</span>;
  if (look === "glass-bar") return <span className="acpmux-paste-late acpmux-paste-bar" aria-hidden="true" />;
  if (look === "glass-dim") return null;
  return (
    <span className="acpmux-paste-late">
      <Spinner loading size={size} {...(className ? { className } : {})} />
    </span>
  );
}
