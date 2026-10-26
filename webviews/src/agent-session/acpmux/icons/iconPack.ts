import bundled from "./cmuxIcons.json";
import custom from "./cmuxIconsCustom.json";
import type { IconAccent, IconLayer, IconPack, IconStyle } from "./types";

/// `pack` with `overlay`'s drawings in place of its own (Debug Settings `icons.family`).
export function overlaidIconPack(pack: IconPack, overlay: IconPack): IconPack {
  return { ...pack, icons: { ...pack.icons, ...overlay.icons } };
}

/// The pack built into the pane.
export const bundledIconPack = bundled as IconPack;

/// The bundled pack with the cmux custom family laid over it (Debug Settings `icons.family` = custom).
export const customIconPack = overlaidIconPack(bundledIconPack, custom as IconPack);

/// The family the host set on the page (`data-icon-family`, AgentPaneTunables.documentAttributes); none is
/// the pack. A pooled page learns it when it is claimed, after its first render, so readers subscribe.
export function documentIconFamily(): string | undefined {
  return typeof document === "undefined" ? undefined : document.documentElement.dataset.iconFamily;
}

const familyListeners = new Set<() => void>();
let familyObserver: MutationObserver | null = null;

/// Calls `listener` when the page's icon family changes; one observer serves every subscriber.
export function subscribeIconFamily(listener: () => void): () => void {
  familyListeners.add(listener);
  if (!familyObserver && typeof MutationObserver !== "undefined" && typeof document !== "undefined") {
    familyObserver = new MutationObserver(() => familyListeners.forEach((notify) => notify()));
    familyObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-icon-family"] });
  }
  return () => {
    familyListeners.delete(listener);
    if (familyListeners.size === 0) {
      familyObserver?.disconnect();
      familyObserver = null;
    }
  };
}

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
