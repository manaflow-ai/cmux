import { bundledIconPack, customIconPack, documentIconFamily, MISSING_ICON, resolveIcon } from "./iconPack";
import { ICON_STROKE } from "./iconSize";
import type { IconLayer, IconPack } from "./types";

// One cmux icon as a CSS mask image (`url("data:image/svg+xml,…")`), for a pseudo-element that
// cannot hold the <Icon> component: the draft's link chip (composer/deeplinkTitles.ts) draws its
// kind's icon with it, in the color its `background-color` gives, as <Icon size={14}> draws it in a
// sent message's chip. A mask reads only alpha, so every layer draws opaque black; a clear layer
// erases through an SVG mask as iconLayers.tsx does.

const cache = new Map<string, string>();

const attr = (value: string | number) => String(value).replace(/[&"<>]/g, (c) => `&#${c.charCodeAt(0)};`);

function strokeAttrs(layer: IconLayer, width: number): string {
  const dash = layer.dash?.length ? ` stroke-dasharray="${attr(layer.dash.join(" "))}"` : "";
  const phase = layer.dashPhase !== undefined ? ` stroke-dashoffset="${attr(layer.dashPhase)}"` : "";
  return ` fill="none" stroke-width="${attr(width)}" stroke-linecap="${layer.cap ?? "round"}" stroke-linejoin="${layer.join ?? "round"}"${dash}${phase}`;
}

function shape(layer: IconLayer, width: number, color: string): string {
  const rule = layer.rule ? ` fill-rule="${layer.rule}"` : "";
  const alpha = layer.alpha !== undefined && color === "black" ? ` opacity="${attr(layer.alpha)}"` : "";
  if (layer.op === "fill" || layer.op === "clearFill")
    // l10n-allow: SVG markup for a CSS mask image, never shown as text
    return `<path d="${attr(layer.d)}" fill="${color}"${rule}${alpha}/>`;
  // l10n-allow: SVG markup for a CSS mask image, never shown as text
  return `<path d="${attr(layer.d)}" stroke="${color}"${strokeAttrs(layer, width)}${alpha}/>`;
}

/// `layers` as an SVG string on the 24-unit grid, `width` the stroke in grid units.
export function iconSvg(layers: IconLayer[], width: number): string {
  let drawn = "";
  let masks = 0;
  for (let index = 0; index < layers.length; index += 1) {
    const layer = layers[index];
    if (layer.op !== "clearFill" && layer.op !== "clearStroke") {
      drawn += shape(layer, width, "black");
      continue;
    }
    let clears = "";
    while (index < layers.length && (layers[index].op === "clearFill" || layers[index].op === "clearStroke")) {
      clears += shape(layers[index], width, "black");
      index += 1;
    }
    index -= 1;
    const id = `m${masks++}`;
    drawn = `<mask id="${id}" maskUnits="userSpaceOnUse" x="-24" y="-24" width="72" height="72"><rect x="-24" y="-24" width="72" height="72" fill="white"/>${clears}</mask><g mask="url(#${id})">${drawn}</g>`;
  }
  // l10n-allow: SVG markup for a CSS mask image, never shown as text
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${drawn}</svg>`;
}

/// The page's pack, as useIcons() picks it with no provider (the app's agent pane has none).
function pagePack(): IconPack {
  return documentIconFamily() === "custom" ? customIconPack : bundledIconPack;
}

/// `name`'s line drawing as a CSS `url(…)` for `mask-image`, at <Icon size={14}>'s stroke.
export function iconMaskUrl(name: string, pack: IconPack = pagePack()): string {
  const key = `${pack.id}:${pack.version}:${pack === customIconPack ? "custom" : ""}:${name}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const layers = resolveIcon(pack, name, "line", "none") ?? resolveIcon(pack, MISSING_ICON, "line", "none") ?? [];
  // <Icon>'s stroke (Icon.tsx): ICON_STROKE per 16 px, in the 24-unit viewBox.
  const url = `url("data:image/svg+xml,${encodeURIComponent(iconSvg(layers, (ICON_STROKE * 24) / 16))}")`;
  cache.set(key, url);
  return url;
}
