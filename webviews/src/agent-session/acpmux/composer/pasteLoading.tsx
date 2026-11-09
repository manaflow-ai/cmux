// A pasted or dropped attachment still being read: its tile is the composer's own glass (ui-glass
// ui-glass-material, never a solid fill), dim at first and coming up as it loads, and only a read
// that passes 400 ms shows an indicator (Leo, 2026-11-07: "do we necessarily need a spinner for it?
// Or should it just sort of, like, be dimmed to start and then, like, gradually become more there as
// it actually loads in? ... Or actually, could we do both?"). The look is the experiment's arm
// (pastePlaceholder.experiment.ts, read by pasteLoadingLook.ts). The 400 ms wait is one timer per
// tile, never a CSS animation delay (the host's animations-off setting forces every delay to 0): it
// fires once, or is cleared when the tile leaves (the read ended, or the chip was cancelled). The fades
// are CSS (composerAttachments.css "Loading"): each runs once and ends.
import { type ReactNode, useEffect, useState } from "react";
import { Spinner } from "../conversation/icons";

/// How long a read runs before its tile shows an indicator: a quick paste never flashes one.
const LATE_MS = 400;

/// What a loading tile shows inside its glass: an upload's progress ring (`upload`, its
/// attachmentIntake.tsx UploadProgress), else the arm's late indicator; both stay hidden until the
/// read passes 400 ms (`data-late`), the upload's assistive `<progress>` read all along.
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
  const [late, setLate] = useState(false);
  useEffect(() => {
    // timeout: a quick read shows no indicator at all; cleared when the tile leaves.
    const timer = setTimeout(() => setLate(true), LATE_MS);
    return () => clearTimeout(timer);
  }, []);
  const lateAttr = late ? { "data-late": "" } : {};
  if (upload)
    return (
      <span className="acpmux-paste-late" {...lateAttr}>
        {upload}
      </span>
    );
  if (look === "glass-dim") return null;
  if (look === "glass-bar")
    return <span className="acpmux-paste-late acpmux-paste-bar" aria-hidden="true" {...lateAttr} />;
  return (
    <span className="acpmux-paste-late" {...lateAttr}>
      {late && <Spinner loading size={size} {...(className ? { className } : {})} />}
    </span>
  );
}
