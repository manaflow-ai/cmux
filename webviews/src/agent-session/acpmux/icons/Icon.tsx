import { useId } from "react";
import { MISSING_ICON, resolveIcon } from "./iconPack";
import { iconLayers } from "./iconLayers";
import { ICON_FLOOR, ROW_VIEWBOX } from "./iconSize";
import { useIcons } from "./IconsContext";
import { opticalRowFit } from "./opticalFit";
import type { IconLayer } from "./types";

/// Drawn when neither the icon nor the pack's icon.missing exists: a dashed square.
const PLACEHOLDER: IconLayer[] = [{ d: "M5 5L19 5L19 19L5 19Z", op: "stroke", w: 1.5, dash: [2, 2] }];

const warned = new Set<string>();

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
}: {
  name: string;
  selected?: boolean;
  size?: number;
  row?: boolean;
  fit?: boolean;
  title?: string;
  className?: string;
  color?: string;
}) {
  const { pack, accent } = useIcons();
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
  return (
    <svg
      viewBox={fitted?.viewBox ?? (row ? ROW_VIEWBOX : "0 0 24 24")}
      width={px}
      height={px}
      overflow={row ? "visible" : undefined}
      className={className}
      style={color ? { color } : undefined}
      data-icon={name}
      role={title ? "img" : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title && <title>{title}</title>}
      {iconLayers(fitted?.layers ?? layers, `cmux-icon-${id}`)}
    </svg>
  );
}
