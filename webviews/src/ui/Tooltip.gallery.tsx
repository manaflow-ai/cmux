// Reference variants for the shared compact tooltip surface. The matrix captures the three
// placement/content choices beside the ChatGPT and Claude references; the shipped choice is the
// compact title/detail hierarchy with an above-first anchor.
import { Tooltip, TooltipProvider } from "./Tooltip";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";

type Props = { mode?: "above" | "below" | "detail" };

function TooltipGallery({ mode = "detail" }: Props) {
  if (mode === "detail")
    return (
      <TooltipProvider>
        <div className="tooltip-gallery-stage">
          <div className="tooltip-gallery-copy">
            <strong>Compact title and detail</strong>
            <span>The selected hierarchy: an emphasized title with a dimmer second line.</span>
          </div>
          <button className="tooltip-gallery-control" title="Fork from here" data-tooltip-detail="Start a new thread">
            Fork
          </button>
        </div>
      </TooltipProvider>
    );
  return (
    <TooltipProvider>
      <div className="tooltip-gallery-stage">
        <div className="tooltip-gallery-copy">
          <strong>{mode === "above" ? "Above, compact" : "Below, compact"}</strong>
          <span>Content-sized bubble with the same glass and shared spacing scale.</span>
        </div>
        <Tooltip label={mode === "above" ? "Copy response" : "Copy response"} side={mode === "above" ? "top" : "bottom"}>
          <button className="tooltip-gallery-control">Copy</button>
        </Tooltip>
      </div>
    </TooltipProvider>
  );
}

const hover: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: /Copy|Fork/ });
};

export default componentEntry<Props>({
  id: "ui.tooltip",
  title: "Tooltip",
  area: "UI primitives",
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".tooltip-gallery-control" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Showing a tooltip must not move its trigger." },
    layoutShiftMax: { value: 0, reason: "The portaled tooltip must not shift the gallery stage." },
    settleMaxMs: { value: 500, reason: "Tooltip hover uses the shared warm-group delay." },
  },
  covers: ["ui/Tooltip.tsx#Tooltip", "ui/titleTooltips.ts#installTooltips"],
  load: async () => TooltipGallery,
  styles: () => import("./Tooltip.gallery.css"),
  variants: {
    "above-compact": { props: { mode: "above" }, play: hover },
    "below-compact": { props: { mode: "below" }, play: hover },
    "title-detail": { props: { mode: "detail" }, play: hover },
  },
});
