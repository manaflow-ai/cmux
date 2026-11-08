// What the toolbar page draws from the omnibar and the host's state: the chip, the bar's surface,
// the star, the resting address's emphasis, and the commands the toolbar sends. Pure.
import type { PageInfoSite } from "../page-info/model";
import { GLOBE_SYMBOL, type OmnibarChip, type OmnibarPresentation } from "../omnibox/presentation";
import type { OmnibarPhase } from "../omnibox/state";
import { urlHostRange } from "../omnibox/url-display";
import { resolveChip, type BrowserToolbarCommand, type PageInfoChip } from "../ui/toolbarModel";
import type { OmnibarLookWire, ToolbarHostState, ToolbarPageCommand } from "./wire";

/** The pack icon for the reducer's chip symbol (SF Symbols' globe is the typed-address row's). */
function iconFor(symbol: string): string {
  return symbol === GLOBE_SYMBOL ? "browser" : symbol;
}

/** `PageInfoIndicator.resolve(site:chip:)`. */
export function chipFor(site: PageInfoSite | null, chip: OmnibarChip): PageInfoChip {
  switch (chip.kind) {
    case "input":
      return resolveChip(site, true, iconFor(chip.symbol));
    case "page":
      return resolveChip(site, false);
    case "keyword":
      return { icon: "browser.toolbar.extensions", label: { keyword: chip.name }, tone: "neutral", triggerable: false };
    case "engineKeyword":
      return { icon: "browser.omnibox.search", label: { keyword: chip.label }, tone: "neutral", triggerable: false };
  }
}

/** The star hides while the user edits (`updateStarVisibility`). */
export function starFor(bookmark: ToolbarHostState["bookmark"], phase: OmnibarPhase): ToolbarHostState["bookmark"] {
  return phase === "editing" ? "hidden" : bookmark;
}

/** The resting address's full-strength range: the host of a compact URL; null draws it all plain. */
export function emphasisFor(presentation: OmnibarPresentation): readonly [number, number] | null {
  const style = presentation.style;
  if (style.kind === "plain") return null;
  const host = urlHostRange(presentation.text, style.url);
  return host ? [host.location, host.location + host.length] : [0, presentation.text.length];
}

/** The bar's resting and hovered fills, as CSS colors (`--bc-bar-fill`, `--bc-bar-hover`). */
export type BarFills = { fill: string; hover: string };

/** The tonal steps of the theme text over the toolbar, at rest and hovered, in percent. */
export const BAR_STEPS = { rest: 7, hover: 10 } as const;

/**
 * The flat bar's fills (`AddressBarSurface.fill(state, coverage:)`): the theme background at the
 * coverage (`backgroundOpacity`, raised to the host's legibility floor), with the text color's tonal
 * step over it. Coverage 0 keeps the window's transparency and still draws the step; 1 is an opaque
 * bar. The step is opaque, so `color-mix` with the under-layer composites the step over it (its
 * premultiplied mix is source-over). The transparent material, and a glass bar (`look.glass`: the
 * host draws Liquid Glass under the page), draw no fill, only the see-through hover fill
 * (OmnibarViews: `Palette.hoverFill` / `chipHoverFill`).
 */
export function barFills(look: OmnibarLookWire): BarFills {
  if (look.material === "transparent" || look.glass) return { fill: "transparent", hover: "var(--ds-color-hover)" };
  const requested = look.coverage ?? look.backgroundOpacity;
  const coverage = Number.isFinite(requested) ? Math.min(1, Math.max(0, requested)) : 0;
  const percent = Math.round(coverage * 1000) / 10;
  const under = percent > 0 ? `color-mix(in srgb, var(--ds-color-surface) ${percent}%, transparent)` : "transparent";
  const step = (value: number) => `color-mix(in srgb, var(--ds-color-fg) ${value}%, ${under})`;
  return { fill: step(BAR_STEPS.rest), hover: step(BAR_STEPS.hover) };
}

/** The toolbar's command as the host takes it; null for one the page handles itself. */
export function wireCommand(command: BrowserToolbarCommand): ToolbarPageCommand | null {
  return command.type === "focusAddressBar" ? null : command;
}
