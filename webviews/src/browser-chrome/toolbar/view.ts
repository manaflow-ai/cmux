// What the toolbar page draws from the omnibar and the host's state: the chip, the bar's surface,
// the star, the resting address's emphasis, and the commands the toolbar sends. Pure.
import type { PageInfoSite } from "../page-info/model";
import { GLOBE_SYMBOL, type OmnibarChip, type OmnibarPresentation } from "../omnibox/presentation";
import type { OmnibarPhase } from "../omnibox/state";
import { urlHostRange } from "../omnibox/url-display";
import { resolveChip, type BrowserToolbarCommand, type PageInfoChip } from "../ui/toolbarModel";
import type { ToolbarHostState, ToolbarPageCommand } from "./wire";

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

/** The toolbar's command as the host takes it; null for one the page handles itself. */
export function wireCommand(command: BrowserToolbarCommand): ToolbarPageCommand | null {
  return command.type === "focusAddressBar" ? null : command;
}
