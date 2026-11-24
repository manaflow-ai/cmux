// The restyled tooltips and hover cards (experiments.hoverLook, off by default; Leo, ask-68c2ce3e90:
// "i recall a lot of our existing hovers and errors and whatnot look like shit"): today's look and the
// three arms side by side, each with the same surfaces open at once, in their real classes: a
// labeled tooltip with its shortcut keycap, one with a detail line, a title tooltip and a hover
// card. The arms are paint only, so every surface is the same size in every variant.
// l10n-allow-file: gallery fixture labels, not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../gallery/format";
import { HOVER_LOOK_ATTRIBUTE, type HoverLook } from "./hoverLook.experiment";

type Props = { look?: HoverLook | "off" };

function HoverLookGallery({ look = "crisp" }: Props) {
  useLayoutEffect(() => {
    const root = document.documentElement;
    if (look === "off") root.removeAttribute(HOVER_LOOK_ATTRIBUTE);
    else root.setAttribute(HOVER_LOOK_ATTRIBUTE, look);
    return () => root.removeAttribute(HOVER_LOOK_ATTRIBUTE);
  }, [look]);
  return (
    <div className="hover-look-gallery">
      <div className="hover-look-gallery-row">
        <div className="ui-tooltip ui-glass" role="tooltip">
          <span className="ui-tooltip-hint">⌘T</span>
          <span className="ui-tooltip-text">New tab</span>
        </div>
        <div className="ui-tooltip ui-glass" role="tooltip">
          <span className="ui-tooltip-text">Fork from here</span>
          <span className="ui-tooltip-detail">Start a new thread. This one stays as it is.</span>
        </div>
        <div className="ui-title-tooltip ui-glass hover-look-gallery-title">Output 2.3K · cache reads 941.4K</div>
      </div>
      <div className="ui-tooltip ui-card ui-glass hover-look-gallery-card" role="tooltip">
        <strong>Fix the sidebar scroll jump</strong>
        <span>Claude · 3 min ago · 12 messages</span>
        <span>
          Moved the scroll anchor to the row under the pointer, so a new row above it no longer shifts the list.
        </span>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.hover-look",
  title: "Tooltip refresh (experiments.hoverLook)",
  area: "UI primitives",
  height: 320,
  widths: { narrow: 420, normal: 640, wide: 880 },
  checks: {
    layoutShiftMax: { value: 0, reason: "The arms are paint only: no surface changes size." },
  },
  covers: ["ui/hoverLook.css", "ui/hoverLook.ts#applyHoverLook", "ui/hoverLook.experiment.ts#hoverLook"],
  load: async () => HoverLookGallery,
  styles: () => import("./HoverLook.gallery.css"),
  variants: {
    off: { props: { look: "off" } },
    crisp: { props: { look: "crisp" } },
    ink: { props: { look: "ink" } },
    soft: { props: { look: "soft" } },
  },
});
