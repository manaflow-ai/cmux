// l10n-allow-file: gallery fixture labels and card content are public-safe sample UI.
import { useMemo, useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { AnchoredCard, Tooltip, TooltipProvider } from "./Tooltip";
import type { UiAnchor } from "./Popover";

type Props = {
  side?: "top" | "bottom";
  anchorMode?: "element" | "rect";
};

function GalleryTooltip({ side = "bottom", anchorMode = "element" }: Props) {
  const [cardAnchor, setCardAnchor] = useState<UiAnchor>(null);
  const cardTrigger = useRef<HTMLButtonElement>(null);
  const rect = useMemo(() => ({ left: 116, top: 108, right: 246, bottom: 140 }), []);
  const openCard = () => setCardAnchor(anchorMode === "rect" ? rect : cardTrigger.current);

  return (
    <TooltipProvider>
      <div
        className="tooltip-gallery"
        style={{
          alignItems: "center",
          display: "flex",
          flexWrap: "wrap",
          gap: 12,
          justifyContent: "center",
          minHeight: 220,
          padding: 32,
        }}
      >
        <Tooltip label="Primary action" side={side}>
          <button type="button" aria-label="Primary action" className="tooltip-gallery-button">
            Primary
          </button>
        </Tooltip>
        <Tooltip label="Secondary action" side={side}>
          <button type="button" aria-label="Secondary action" className="tooltip-gallery-button">
            Secondary
          </button>
        </Tooltip>
        <button
          ref={cardTrigger}
          type="button"
          aria-expanded={cardAnchor !== null}
          aria-label={cardAnchor === null ? "Show preview card" : "Hide preview card"}
          className="tooltip-gallery-button"
          onClick={() => (cardAnchor === null ? openCard() : setCardAnchor(null))}
        >
          Preview
        </button>
        <AnchoredCard
          anchor={cardAnchor}
          className="tooltip-gallery-card"
          state={cardAnchor === null ? "closed" : "open"}
        >
          <strong>Preview card</strong>
          <span>Anchored details stay out of document flow.</span>
        </AnchoredCard>
      </div>
    </TooltipProvider>
  );
}

const hoverTooltip: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: "Primary action" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip")?.textContent === "Primary action");
};

const focusTooltip: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Primary action" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip")?.textContent === "Primary action");
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip") === null);
};

const switchTooltip: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: "Primary action" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip")?.textContent === "Primary action");
  await ctx.hover({ role: "button", name: "Secondary action" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip")?.textContent === "Secondary action");
};

const cardOpenClose: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Show preview card" });
  await ctx.waitFor(() => ctx.document.querySelector('.ui-card[data-state="open"]'));
  await ctx.click({ role: "button", name: "Hide preview card" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-card") === null);
};

export default componentEntry<Props>({
  id: "ui.tooltip",
  title: "Tooltip and anchored card",
  area: "Shared UI",
  height: 280,
  widths: { narrow: 360, normal: 540, wide: 720 },
  anchors: [{ selector: ".tooltip-gallery" }],
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./Tooltip.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Tooltip and anchored-card portals must leave the trigger row geometry fixed.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Portaled hints and cards must not add document flow around their controls.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Local tooltip interactions should complete within one display frame after their delay.",
    },
    settleMaxMs: {
      value: 900,
      reason: "The shared tooltip intentionally waits 500 ms before opening, then settles promptly.",
    },
    popupLayer: {
      value: true,
      reason: "Portaled hints must remain visible above the gallery surface without clipping.",
    },
  },
  covers: ["ui/Tooltip.tsx#TooltipProvider", "ui/Tooltip.tsx#Tooltip", "ui/Tooltip.tsx#AnchoredCard"],
  load: async () => GalleryTooltip,
  variants: {
    closed: { props: {} },
    "hover-tooltip": { props: {}, play: hoverTooltip },
    "focus-escape": { props: {}, play: focusTooltip },
    "switch-tooltip": { props: {}, play: switchTooltip },
    "card-open-close": { props: {}, play: cardOpenClose },
    "card-rect-anchor": { props: { anchorMode: "rect" }, play: cardOpenClose },
    "top-aligned": { props: { side: "top" }, play: hoverTooltip },
  },
});
