// The Feed's glyphs: the app's own icon pack (iconPack.ts, the drawings the Swift Feed used), drawn
// as SVG in `currentColor`. A knockout layer (clearStroke, clearFill) cuts through the layers under
// it with a mask, as the pack's canvas does. No SF Symbols (coordinator Q5).
import { useId } from "react";
import { ICON_PACK, type IconLayer } from "./iconPack";

export type FeedIconSize = 12 | 14 | 16 | 20 | 32 | 44;

/** The owner's `row.icon` names this page draws; anything else draws the notice bell. */
export function iconName(name: string | undefined): string {
  return name && name in ICON_PACK ? name : "notification";
}

function layer(item: IconLayer, index: number, cut: boolean) {
  const paint = cut ? "black" : "currentColor";
  if (item.op === "fill" || item.op === "clearFill") return <path key={index} d={item.d} fill={paint} />;
  return (
    <path
      key={index}
      d={item.d}
      fill="none"
      stroke={paint}
      strokeWidth={item.w ?? 1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  );
}

export function FeedIcon({
  name,
  size = 16,
  solid = false,
  className,
}: {
  name: string;
  size?: FeedIconSize;
  solid?: boolean;
  className?: string;
}) {
  const mask = useId();
  const entry = ICON_PACK[iconName(name)]!;
  const layers = (solid && entry.solid) || entry.line;
  const isCut = (item: IconLayer) => item.op === "clearStroke" || item.op === "clearFill";
  // A knockout cuts the layers drawn before it; the ones after it paint over the cut.
  const lastCut = layers.reduce((last, item, index) => (isCut(item) ? index : last), -1);
  const cuts = lastCut >= 0;
  const under = layers.slice(0, Math.max(0, lastCut)).filter((item) => !isCut(item));
  const over = layers.slice(lastCut + 1);
  const drawn = cuts ? under : layers;
  return (
    <svg
      className={className ? `feed-icon ${className}` : "feed-icon"}
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden="true"
      data-icon={iconName(name)}
    >
      {cuts ? (
        <>
          <mask id={mask} maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
            <rect width="24" height="24" fill="white" />
            {layers.map((item, index) => (isCut(item) ? layer(item, index, true) : null))}
          </mask>
          <g mask={`url(#${mask})`}>{drawn.map((item, index) => layer(item, index, false))}</g>
          {over.map((item, index) => layer(item, index, false))}
        </>
      ) : (
        drawn.map((item, index) => layer(item, index, false))
      )}
    </svg>
  );
}
