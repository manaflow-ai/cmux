import { createContext, useContext, useId, type CSSProperties } from "react";
import { MISSING_ICON, resolveIcon } from "./iconPack";
import { iconLayers } from "./iconLayers";
import { iconMarkup } from "./iconMarkup";
import "./iconMask.css";
import { ICON_FLOOR, ICON_STROKE, ROW_VIEWBOX } from "./iconSize";
import { useIcons } from "./iconsContextModel";
import { opticalRowFit } from "./opticalFit";
import type { IconLayer, IconPack } from "./types";

/// Drawn when neither the icon nor the pack's icon.missing exists: a dashed square.
const PLACEHOLDER: IconLayer[] = [{ d: "M5 5L19 5L19 19L5 19Z", op: "stroke", w: 1.5, dash: [2, 2] }];

const warned = new Set<string>();

/// Inside it, an <Icon> draws as one element: a span masked by the svg it would draw
/// (`.cmux-icon-mask`), the same pixels with no path children to style. A transcript row's footer
/// (MessageActions.tsx MessageFooterRow) draws its buttons' icons so: a row mounts about a quarter
/// fewer elements for an older page of a long chat to style. An icon with a title (an image to
/// assistive tech), a row icon (its ink may leave the box) or an accent layer (a mask reads only
/// alpha) still draws its svg.
export const IconMaskContext = createContext(false);

/// The mask image of each drawing, made once per pack, icon, form, accent, crop and stroke.
const maskUrls = new WeakMap<IconPack, Map<string, string>>();
function maskUrl(pack: IconPack, key: string, draw: () => string): string {
  let urls = maskUrls.get(pack);
  if (!urls) maskUrls.set(pack, (urls = new Map()));
  let url = urls.get(key);
  if (!url) {
    url = `url("data:image/svg+xml,${encodeURIComponent(draw())}")`;
    urls.set(key, url);
  }
  return url;
}

/// One cmux icon from the active pack, in the text color. Selected draws the Solid form; `row`
/// crops the grid margin so the icon sits on a label line (size it with rowIconSize); `color`
/// replaces the text color (a machine's own color); `fit`, with `row`, centres the glyph's ink and sizes
/// it to one shared ink box at the pack's stroke weight (opticalFit.ts), for a column of mixed glyphs.
/// Decorative unless it has a title.
export function Icon({
  name,
  selected = false,
  size = 16,
  row = false,
  fit = false,
  title,
  className,
  color,
  style: cssStyle,
}: {
  name: string;
  selected?: boolean;
  size?: number;
  row?: boolean;
  fit?: boolean;
  title?: string;
  className?: string;
  color?: string;
  style?: CSSProperties;
}) {
  const { pack, accent } = useIcons();
  const masks = useContext(IconMaskContext);
  const id = useId().replace(/[^\w-]/g, "");
  const style = selected ? "solid" : "line";
  let layers = resolveIcon(pack, name, style, accent);
  if (!layers) {
    if (!warned.has(name)) {
      warned.add(name);
      console.warn(`cmux icon "${name}" is not in pack ${pack.id}`);
    }
    layers = resolveIcon(pack, MISSING_ICON, style, accent) ?? PLACEHOLDER;
  }
  const fitted = row && fit ? opticalRowFit(layers) : undefined;
  const px = Math.max(ICON_FLOOR, size);
  const viewBox = fitted?.viewBox ?? (row ? ROW_VIEWBOX : "0 0 24 24");
  const span = Number(viewBox.split(" ")[2]);
  // Normalize in viewBox units, including the optical crop. The same glyph then
  // has the same rendered stroke in a row, a fitted column, or a plain button.
  const strokeWidth = selected ? undefined : (ICON_STROKE * span) / 16;
  const drawn = fitted?.layers ?? layers;
  if (masks && !title && !row && !drawn.some((layer) => layer.accent)) {
    const key = `${accent}:${name}:${style}:${viewBox}:${strokeWidth}`;
    const mask = maskUrl(pack, key, () => iconMarkup(viewBox, iconLayers(drawn, "m", strokeWidth)));
    return (
      <span
        className={className ? `cmux-icon-mask ${className}` : "cmux-icon-mask"}
        style={{
          ...cssStyle,
          ...(color && { color }),
          ["--cmux-icon-size" as string]: `${px}px`,
          ["--cmux-icon-mask" as string]: mask,
        }}
        data-icon={name}
        aria-hidden
      />
    );
  }
  return (
    <svg
      viewBox={viewBox}
      width={px}
      height={px}
      overflow={row ? "visible" : undefined}
      className={className}
      style={color ? { ...cssStyle, color } : cssStyle}
      data-icon={name}
      role={title ? "img" : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title && <title>{title}</title>}
      {iconLayers(fitted?.layers ?? layers, `cmux-icon-${id}`, strokeWidth)}
    </svg>
  );
}
