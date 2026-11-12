// l10n-allow-file: gallery labels and content are deterministic fixture text.
// The scroll area's keyboard focus ring. Base UI makes an overflowing viewport a Tab stop; the page ring is an
// outline outside the viewport, which the root's `overflow: hidden` clips, so `before` shows nothing at all.
// Picked and shipped: `inset`, the shared ring width and colour drawn just inside the viewport's edge, which no
// parent can clip and which matches every other control's ring. Kept for comparison, not picked:
// `outer` (the ring outside the root: a flush scroller such as the Settings sidebar or a popup list has no room
// for it and it is clipped again), `edge-glow` (an inset ring-tinted glow: a new look no other control uses).
// `both-bars` shows Base UI's Corner where the two bars meet, so neither thumb runs under the other.
import type { HTMLAttributes } from "react";
import type { Play } from "../gallery/play";
import { componentEntry } from "../gallery/format";
import { ScrollArea } from "./ScrollArea";

type Look = "before" | "inset" | "outer" | "edge-glow";
type Props = { look: Look; wide?: boolean };

/** A `data-focus-ring` value of the gallery's own, which the component's ring skips and desktop.css does not. */
const optOut = (look: Look): HTMLAttributes<HTMLDivElement> => ({ ["data-focus-ring" as string]: `gallery-${look}` });

function ScrollAreaFocusGallery({ look, wide = false }: Props) {
  return (
    <div className="scroll-area-motion-gallery scroll-area-focus-gallery" data-look={look}>
      <div className="scroll-area-motion-gallery__controls">
        <button type="button" className="ui-button" data-testid="scroll-focus-before">
          Before the list
        </button>
      </div>
      <ScrollArea
        className="scroll-area-focus-gallery__scroll"
        viewportClassName="scroll-area-motion-gallery__viewport"
        // Only the inset look is the component's own ring; the others opt out of it and draw theirs here.
        viewportProps={look === "inset" ? undefined : optOut(look)}
        horizontal={wide}
      >
        {Array.from({ length: 18 }, (_, index) => (
          <div
            key={index}
            className="scroll-area-motion-gallery__item scroll-area-focus-gallery__item"
            style={wide ? { width: "200%" } : undefined}
          >
            Transcript line {index + 1}
            {wide && " with a long command that runs wider than the scroller"}
          </div>
        ))}
      </ScrollArea>
    </div>
  );
}

const tabIntoScroller: Play = async (ctx) => {
  await ctx.focus({ testId: "scroll-focus-before" });
  await ctx.press("Tab");
  await ctx.waitFor(() => document.activeElement?.classList.contains("scroll-area-motion-gallery__viewport"));
};

export default componentEntry<Props>({
  id: "ui.scroll-area-focus",
  title: "Scroll area focus ring",
  area: "UI primitives",
  height: 260,
  keywords: ["keyboard", "focus", "ring", "scroller", "corner"],
  covers: ["ui/ScrollArea.tsx#ScrollArea"],
  load: async () => ScrollAreaFocusGallery,
  styles: () => Promise.all([import("./ui.css"), import("./ScrollArea.gallery.css")]),
  variants: {
    before: {
      props: { look: "before" },
      play: tabIntoScroller,
      note: "Before: the page ring is clipped by the root, so a focused scroller shows nothing.",
    },
    inset: {
      props: { look: "inset" },
      play: tabIntoScroller,
      note: "Picked and shipped: the shared ring just inside the edge; nothing can clip it.",
    },
    outer: {
      props: { look: "outer" },
      play: tabIntoScroller,
      note: "Not picked: outside the root, so a flush scroller or a popup list clips it again.",
    },
    "edge-glow": {
      props: { look: "edge-glow" },
      play: tabIntoScroller,
      note: "Not picked: an inset glow in the ring colour, a look no other control uses.",
    },
    "both-bars": {
      props: { look: "inset", wide: true },
      play: tabIntoScroller,
      note: "Both bars: the Corner keeps the vertical thumb clear of the horizontal one.",
    },
  },
});
