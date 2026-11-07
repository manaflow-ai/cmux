// The browser toolbar's data, commands and rules: plain mirrors of the native BrowserChromeCommand,
// BrowserToolbarButton / BrowserToolbarPolicy, BrowserToolbarLayout, PageInfoIndicator and
// OmnibarMetrics (Standard density). Pure, so the collapse order is testable with fixed numbers.
import type { PageInfoSite } from "../page-info/model";

/** The Standard density's sizes (OmnibarMetrics, OmnibarStyle, BrowserToolbarLayout.Metrics), in pt. */
export const TOOLBAR_METRICS = {
  /** The bar's height, and each suggestion row's. */
  bar: 28,
  /** The square toolbar buttons. */
  button: 28,
  /** Between neighboring buttons (the base padding). */
  spacing: 3,
  /** Reload to the bar, and the bar to the extensions (twice the base padding). */
  margin: 6,
  /** The pane's chrome line: the first button's hover shape starts under the first tab pill. */
  inset: 2,
  /** The space below the row, down to the page (the pane chrome's tab gap). */
  gapBelow: 2,
  /** Omnibar width kept before a pinned extension moves into the Extensions menu (tabMaxWidth). */
  preferredAddress: 200,
  /** Omnibar width kept before Forward hides (half of it). */
  minimumAddress: 100,
  /** Most pinned extension buttons shown before the rest overflow into the menu. */
  maxPinned: 6,
  /** The page-info chip: the bar less 2 pt on each side. */
  chip: 24,
  chipLeading: 2,
  textLeading: 5,
  trailingPadding: 8,
  /** The star's box: the trailing icon (18) with 1 pt around it. */
  trailingBox: 20,
} as const;

// MARK: Commands

/** Everything the toolbar can ask for. The navigation ones are `BrowserChromeCommand` cases. */
export type BrowserToolbarCommand =
  | { type: "goBack" }
  | { type: "goForward" }
  | { type: "reload" }
  | { type: "stop" }
  | { type: "focusAddressBar" }
  /** Right-click (or long press) on Back or Forward: the history menu under the button. */
  | { type: "navigationMenu"; direction: "back" | "forward" | "reload" }
  /** The page-info chip: open or close the bubble, anchored at the chip. */
  | { type: "pageInfo" }
  /** The star: bookmark the page, or edit its bookmark. */
  | { type: "bookmark" }
  | { type: "toolbarButton"; button: ToolbarButtonId }
  | { type: "extensionAction"; id: string }
  | { type: "extensionContextMenu"; id: string }
  | { type: "extensionsMenu" }
  /** The crashed-extension warning: reload the profile's crashed extensions. */
  | { type: "reloadCrashedExtensions" }
  /** Drag reorder of a pinned extension (its new index among the pinned). */
  | { type: "moveExtension"; id: string; index: number }
  | { type: "focusModeBadge" }
  | { type: "profileBadge" }
  | { type: "machineBadge" };

// MARK: The omnibar's page-info chip (PageInfoIndicator)

export type ChipLabel = "notSecure" | "dangerous" | "file" | "product" | { keyword: string };

export type PageInfoChip = {
  /** A pack icon name. */
  icon: string;
  label?: ChipLabel;
  tone: "neutral" | "danger";
  /** Opens the bubble. False while the user edits or the bar is empty. */
  triggerable: boolean;
};

/**
 * The chip for `site` (null: an empty or blank page). While focused the label hides; while the
 * user types, `editingIcon` (search, or the selected suggestion's kind) replaces the page's.
 */
export function resolveChip(site: PageInfoSite | null, focused = false, editingIcon?: string): PageInfoChip {
  if (editingIcon) return { icon: editingIcon, tone: "neutral", triggerable: false };
  const chip = pageChip(site);
  return focused ? { ...chip, label: undefined } : chip;
}

function pageChip(site: PageInfoSite | null): PageInfoChip {
  if (!site) return { icon: "browser.omnibox.search", tone: "neutral", triggerable: false };
  switch (site.kind) {
    case "web":
      switch (site.connection ?? "secure") {
        case "secure":
          return { icon: "browser.omnibox.pageinfo", tone: "neutral", triggerable: true };
        case "insecure":
        case "mixedContent":
          return {
            icon: "browser.omnibox.notsecure",
            label: "notSecure",
            tone: "neutral",
            triggerable: true,
          };
        case "certificateError":
          return {
            icon: "browser.omnibox.dangerous",
            label: "notSecure",
            tone: "danger",
            triggerable: true,
          };
        case "dangerous":
          return {
            icon: "browser.omnibox.dangerous",
            label: "dangerous",
            tone: "danger",
            triggerable: true,
          };
      }
      break;
    case "file":
      return { icon: "file", label: "file", tone: "neutral", triggerable: true };
    case "extensionPage":
      return { icon: "browser.toolbar.extensions", tone: "neutral", triggerable: true };
    default:
      return { icon: "terminal", label: "product", tone: "neutral", triggerable: true };
  }
  return { icon: "browser.omnibox.pageinfo", tone: "neutral", triggerable: true };
}

// MARK: The omnibar

export type OmnibarState = {
  /** The compact URL at rest; the full address or the typed text while editing. */
  text: string;
  /** The host's UTF-16 range inside `text`, drawn at full strength while the rest dims. */
  host?: readonly [number, number];
  chip: PageInfoChip;
  bookmark: "hidden" | "off" | "on";
  /** The field has focus (the neutral ring, no host emphasis). */
  editing?: boolean;
  /** The suggestion card is open: the bar is its top (card fill, no ring). */
  suggestionsOpen?: boolean;
  /** The card opens above the bar (toolbar at the bottom of the pane). */
  upward?: boolean;
  /** The Page Info bubble is open: the chip keeps its pressed fill. */
  pageInfoOpen?: boolean;
};

// MARK: Trailing buttons (BrowserToolbarButton, BrowserToolbarPolicy)

export type ToolbarButton =
  | { id: "media" }
  | { id: "zoom"; percent: number }
  | { id: "favorites" }
  | {
      id: "downloads";
      inProgress?: boolean;
      /** 0...1, negative while the size is unknown. */ progress?: number;
    }
  | { id: "designMode"; active?: boolean; enabled?: boolean }
  | { id: "profile"; name?: string }
  | { id: "theme"; scheme: "system" | "light" | "dark" }
  | { id: "devTools"; available: boolean; needsChromium?: boolean; open?: boolean }
  | { id: "overflow" };

export type ToolbarButtonId = ToolbarButton["id"];

/** A trailing button as the host resolved it (`BrowserToolbarPolicy`): drawn as given. */
export type ResolvedToolbarButton = {
  id: ToolbarButtonId;
  /** A pack icon name. */
  icon: string;
  /** Accessibility label; also the tooltip when `tooltip`. */
  label: string;
  enabled: boolean;
  active: boolean;
  tooltip: boolean;
  /** Downloads' ring: 0...1, negative while unsized; absent draws none. */
  progress?: number;
  /** A right-click presses it too (it opens a menu). */
  opensMenu: boolean;
  /** Its menu or popup is open: drawn pressed. */
  pressed?: boolean;
  /** How early it hides as the pane narrows (null: never, More). */
  collapseLevel: number | null;
};

/** The trailing badges inside the omnibar, before the star; the texts come localized. */
export type OmnibarBadges = {
  /** `help`: how to leave it (the Escape hint), the badge's tooltip. */
  focusMode?: { text: string; help?: string } | null;
  /** `symbol`: the host's template image of an SF Symbol monogram, drawn as a mask (else the monogram as text). */
  profile?: { monogram: string; symbol?: string | null; color?: string | null; name: string; help?: string } | null;
  machine?: { text: string; help: string } | null;
};

/** The catalog's order. */
export const TOOLBAR_BUTTON_ORDER: readonly ToolbarButtonId[] = [
  "media",
  "zoom",
  "favorites",
  "downloads",
  "designMode",
  "profile",
  "theme",
  "devTools",
  "overflow",
];

/** How early a button hides as the pane narrows; More never does and lists the hidden ones. */
export function collapseLevel(id: ToolbarButtonId): number | null {
  if (id === "designMode" || id === "devTools") return 1;
  return id === "overflow" ? null : 2;
}

/** A pinned extension action. */
export type ExtensionAction = {
  id: string;
  /** The tooltip: the action's title, else the extension's name. */
  name: string;
  /** What VoiceOver names it (the extension's name); absent: `name`. */
  label?: string;
  /** The badge the icon draws, read as the button's value; absent: none. */
  value?: string;
  /** The action's icon (a data or extension URL); absent: the name's initial. */
  iconUrl?: string;
  badge?: { text: string; color?: string };
  enabled?: boolean;
};

// MARK: Layout (BrowserToolbarLayout + BrowserChromeView.widthLeftByToolbarButtons)

export type ToolbarLayout = {
  /** Trailing buttons hidden at this level and below (0 shows all). */
  collapse: number;
  visiblePinned: number;
  showsForward: boolean;
  /** The omnibar's width at this layout. */
  addressWidth: number;
};

/** The sizes the layout reads; the host may send its density's (`ToolbarMetrics`). */
export type LayoutMetrics = {
  button: number;
  spacing: number;
  margin: number;
  inset: number;
  /** The row's trailing inset; the leading `inset` when absent. */
  trailingInset?: number;
  preferredAddress: number;
  minimumAddress: number;
  maxPinned: number;
};

/** The row's sizes at the app's density, in CSS px (the host's `ToolbarMetrics`). */
export type ToolbarRowMetrics = LayoutMetrics & {
  bar: number;
  fontSize: number;
  toolbarIcon: number;
  trailingIcon: number;
  starIcon: number;
  chipIcon: number;
  cornerRadius: number;
};

/** A trailing button the layout can collapse: a catalog button, or one the host resolved with its level. */
export type CollapsibleButton = { id: string; collapseLevel?: number | null };

function levelOf(button: CollapsibleButton): number | null {
  return button.collapseLevel !== undefined ? button.collapseLevel : collapseLevel(button.id as ToolbarButtonId);
}

function navigationWidth(forward: boolean, m: LayoutMetrics): number {
  return forward ? 3 * m.button + 2 * m.spacing : 2 * m.button + m.spacing;
}

function extensionsWidth(count: number, showsExtensions: boolean, m: LayoutMetrics): number {
  return showsExtensions ? (count + 1) * m.button + count * m.spacing : 0;
}

/** The buttons other than More shown at collapse `level`, in the order given. */
export function visibleButtons<T extends CollapsibleButton>(buttons: readonly T[], level: number): T[] {
  return buttons.filter((button) => {
    if (button.id === "overflow") return false;
    const at = levelOf(button);
    return at === null || at > level;
  });
}

export function trailingWidth(
  buttons: readonly CollapsibleButton[],
  level: number,
  m: LayoutMetrics = TOOLBAR_METRICS,
): number {
  // More always shows.
  const count = visibleButtons(buttons, level).length + 1;
  return count * m.button + Math.max(0, count - 1) * m.spacing;
}

/** The buttons shown at collapse `level`, in catalog order, More always last. */
export function shownButtons(buttons: readonly ToolbarButton[], level: number): ToolbarButton[] {
  const shown = visibleButtons(buttons, level);
  shown.sort((a, b) => TOOLBAR_BUTTON_ORDER.indexOf(a.id) - TOOLBAR_BUTTON_ORDER.indexOf(b.id));
  return [...shown, { id: "overflow" }];
}

/**
 * The layout at pane `width`: trailing buttons collapse first (design mode and DevTools, then the
 * rest) while the omnibar would drop under its minimum; then pinned extensions move to the menu,
 * last pinned first, while it is under its preferred width; then Forward hides. Back, Reload, the
 * omnibar, the Extensions button and More always stay. `metrics` defaults to the Standard density.
 */
export function resolveLayout(
  width: number,
  buttons: readonly CollapsibleButton[],
  pinned: number,
  showsExtensions: boolean,
  metrics: LayoutMetrics = TOOLBAR_METRICS,
): ToolbarLayout {
  const m = metrics;
  const fixed = m.inset + (m.trailingInset ?? m.inset) + 2 * m.margin;
  const roomy = (left: number) => left - fixed - navigationWidth(true, m) - extensionsWidth(0, showsExtensions, m);
  const level =
    [0, 1, 2].find(
      (candidate) => roomy(width - trailingWidth(buttons, candidate, m) - m.spacing) >= m.minimumAddress,
    ) ?? 2;
  const left = width - trailingWidth(buttons, level, m) - m.spacing;
  const maxPinned = showsExtensions ? Math.min(pinned, m.maxPinned) : 0;
  let visiblePinned = 0;
  let showsForward = true;
  const fits = (count: number) =>
    fixed + navigationWidth(true, m) + extensionsWidth(count, showsExtensions, m) + m.preferredAddress <= left;
  for (let count = maxPinned; count > 0; count--) {
    if (fits(count)) {
      visiblePinned = count;
      break;
    }
  }
  if (visiblePinned === 0)
    showsForward = fixed + navigationWidth(true, m) + extensionsWidth(0, showsExtensions, m) + m.minimumAddress <= left;
  const addressWidth =
    left - fixed - navigationWidth(showsForward, m) - extensionsWidth(visiblePinned, showsExtensions, m);
  return { collapse: level, visiblePinned, showsForward, addressWidth };
}
