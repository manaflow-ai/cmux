// Reference variants for the shared compact tooltip surface: the compact title/detail hierarchy
// with an above-first anchor, and how a tooltip sizes to its text (Leo, 2026-11-07: "you just have
// this, like, one, one and a half words on a second line, and it's like, okay, why is this even so
// wide in the first place?"). The token variants are a title tooltip (ui/titleTooltips.ts) with a
// stats list at three layouts: one balanced string, two rows, one stat per row, all sized by the shared
// fit (ui/tooltipFit.ts); the chat's own token hover is its plain-words line (turnTokensModel.ts
// tokenDetail). The stage's desktop layer installs title tooltips as every page's does. Long and short text and the window's edge (#22693) use Base UI's tooltip.
// l10n-allow-file: gallery fixture labels, not shipped UI.
import { Button } from "./Button";
import { Tooltip, TooltipProvider } from "./Tooltip";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";

type Mode = "above" | "below" | "detail" | "long" | "edge" | "tokens-balanced" | "tokens-two-rows" | "tokens-rows";
type Props = { mode?: Mode };

const STATS = ["Output 2.3K", "fresh input 14", "cache reads 941.4K", "cache writes 5K"];
const capital = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);
const TOKEN_TITLES: Record<string, string> = {
  "tokens-balanced": STATS.join(" · "),
  "tokens-two-rows": `${STATS.slice(0, 2).join(" · ")}\n${capital(STATS.slice(2).join(" · "))}`,
  "tokens-rows": STATS.map(capital).join("\n"),
};
const COPY: Record<Mode, [string, string]> = {
  above: ["Above, compact", "Content-sized bubble with the same glass and shared spacing scale."],
  below: ["Below, compact", "Content-sized bubble with the same glass and shared spacing scale."],
  detail: ["Compact title and detail", "The selected hierarchy: an emphasized title with a dimmer second line."],
  long: ["Long text", "Wraps balanced, and the box narrows to its widest line."],
  edge: ["At the window's edge", "Never breaks inside a word next to the edge (#22693)."],
  "tokens-balanced": ["A: one balanced string", "The token hover as one line of stats, wrapped even."],
  "tokens-two-rows": ["B: two rows", "Output and fresh input, then the cache."],
  "tokens-rows": ["C: one stat per row", "Each count on its own short row."],
};

function TooltipGallery({ mode = "detail" }: Props) {
  const [title, note] = COPY[mode];
  const copy = (
    <div className="tooltip-gallery-copy">
      <strong>{title}</strong>
      <span>{note}</span>
    </div>
  );
  const tokens = TOKEN_TITLES[mode];
  if (tokens)
    return (
      <div className="tooltip-gallery-stage">
        {copy}
        <span className="tooltip-gallery-tokens" title={tokens}>
          ↓ 2.3K out ↑ 946.4K in
        </span>
      </div>
    );
  const trigger = (label: string) => (
    <Button className="tooltip-gallery-control" size="sm">
      {label}
    </Button>
  );
  return (
    <TooltipProvider>
      <div className={mode === "edge" ? "tooltip-gallery-stage is-edge" : "tooltip-gallery-stage"}>
        {copy}
        {mode === "detail" ? (
          <Tooltip label="Fork from here" detail="Start a new thread. This one stays as it is.">
            {trigger("Fork")}
          </Tooltip>
        ) : mode === "long" ? (
          <Tooltip label="Open the pull request for this branch in the browser, next to the agent chat">
            {trigger("Open")}
          </Tooltip>
        ) : mode === "edge" ? (
          <Tooltip label="Chat summary of the whole session" side="bottom">
            {trigger("Summary")}
          </Tooltip>
        ) : (
          <Tooltip label="Copy response" side={mode === "above" ? "top" : "bottom"}>
            {trigger("Copy")}
          </Tooltip>
        )}
      </div>
    </TooltipProvider>
  );
}

const hover: Play = async (ctx) => {
  await ctx.hover({ selector: ".tooltip-gallery-control" });
  await ctx.waitFor(() => {
    const popup = ctx.document.querySelector<HTMLElement>('[role="tooltip"]');
    return popup && ctx.document.defaultView?.getComputedStyle(popup).opacity === "1";
  });
};

const hoverTitle: Play = async (ctx) => {
  await ctx.hover({ selector: ".tooltip-gallery-tokens" });
  await ctx.waitFor(() => {
    const tip = ctx.document.querySelector<HTMLElement>(".ui-title-tooltip");
    return tip && !tip.hidden && ctx.document.defaultView?.getComputedStyle(tip).opacity === "1";
  });
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
  covers: ["ui/Tooltip.tsx#Tooltip", "ui/titleTooltips.ts#installTooltips", "ui/tooltipFit.ts#fitTooltipWidth"],
  load: async () => TooltipGallery,
  styles: () => Promise.all([import("./Tooltip.gallery.css"), import("./controls.css")]),
  variants: {
    "above-compact": { props: { mode: "above" }, play: hover },
    "below-compact": { props: { mode: "below" }, play: hover },
    "title-detail": { props: { mode: "detail" }, play: hover },
    "long-text": { props: { mode: "long" }, play: hover },
    "window-edge": { props: { mode: "edge" }, play: hover },
    "tokens-balanced": { props: { mode: "tokens-balanced" }, play: hoverTitle },
    "tokens-two-rows": { props: { mode: "tokens-two-rows" }, play: hoverTitle },
    "tokens-rows": { props: { mode: "tokens-rows" }, play: hoverTitle },
  },
});
