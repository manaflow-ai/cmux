// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// ui/Skeleton: one loading placeholder. Light and dark are the gallery's theme axis; the motion axis
// (Reduce Motion, static indicators) holds every look still.
// Picked and shipped: `breathe`, the opacity breath of agent work's dot on the shared clock
// (desktop.css cmux-breathe), so every placeholder and working mark on screen move as one; the Apps
// card skeleton already used it. Not picked: `pulse` (the reference kit's quick 2 s pulse, a second
// rhythm beside the shared one), `shimmer` (a band crossing the box: it reads as the Thinking line's
// shimmer, which means an agent is working, not that content is loading), `static` (no motion at all,
// as the diff viewer's and New Tab's placeholders: a slow load then looks stuck; it is still what every
// look becomes under Reduce Motion).
import { componentEntry } from "../gallery/format";
import { Skeleton } from "./Skeleton";

type Look = "breathe" | "pulse" | "shimmer" | "static";
type Layout = "card" | "rows";
type Props = { look: Look; layout?: Layout };

function SkeletonGallery({ look, layout = "card" }: Props) {
  return (
    <div
      className="ui-controls-stage ui-skeleton-gallery"
      data-look={look}
      data-gallery-capture=""
      aria-busy="true"
      aria-label="Loading"
    >
      {layout === "card" ? (
        <div className="ui-skeleton-gallery__cards">
          {Array.from({ length: 3 }, (_, index) => (
            <div key={index} className="ui-skeleton-gallery__card">
              <Skeleton className="ui-skeleton-gallery__icon" />
              <Skeleton shape="line" className="ui-skeleton-gallery__wide" />
              <Skeleton shape="line" className="ui-skeleton-gallery__half" />
              <Skeleton className="ui-skeleton-gallery__footer" />
            </div>
          ))}
        </div>
      ) : (
        <div className="ui-skeleton-gallery__rows">
          {Array.from({ length: 5 }, (_, index) => (
            <div key={index} className="ui-skeleton-gallery__row">
              <Skeleton shape="circle" className="ui-skeleton-gallery__avatar" />
              <Skeleton
                shape="line"
                className={index % 2 ? "ui-skeleton-gallery__half" : "ui-skeleton-gallery__wide"}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.skeleton",
  title: "Skeleton",
  area: "UI primitives",
  height: 240,
  keywords: ["loading", "placeholder", "shimmer", "pulse", "breathe"],
  covers: ["ui/Skeleton.tsx"],
  load: async () => SkeletonGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css"), import("./Skeleton.gallery.css")]),
  variants: {
    breathe: { props: { look: "breathe" }, note: "Picked: the shared breath, as the Apps cards had it." },
    "breathe-rows": { props: { look: "breathe", layout: "rows" }, note: "Picked, as list rows with a circle." },
    pulse: { props: { look: "pulse" }, note: "Not picked: the reference kit's pulse, a second rhythm." },
    shimmer: { props: { look: "shimmer" }, note: "Not picked: reads as an agent working, not loading." },
    static: { props: { look: "static" }, note: "Not picked: a slow load looks stuck; every look under Reduce Motion." },
  },
});
