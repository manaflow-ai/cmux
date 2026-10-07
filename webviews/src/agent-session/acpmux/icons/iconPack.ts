import bundled from "./cmuxIcons.json";
import type { IconAccent, IconLayer, IconPack, IconStyle } from "./types";

/// The pack built into the pane.
export const bundledIconPack = bundled as IconPack;

/// The name whose drawing stands in for an unknown icon.
export const MISSING_ICON = "icon.missing";

/// The layers `name` draws in `style`, or null when the pack has no such icon. The Cat drawing replaces
/// Line only; selected icons stay Solid.
export function resolveIcon(pack: IconPack, name: string, style: IconStyle, accent: IconAccent): IconLayer[] | null {
  const drawing = Object.hasOwn(pack.icons, name) ? pack.icons[name] : undefined;
  if (!drawing) return null;
  if (style === "line" && accent === "cat" && drawing.cat) return drawing.cat;
  return drawing[style];
}
