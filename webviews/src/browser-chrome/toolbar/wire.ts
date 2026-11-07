// The browser toolbar's wire to its native host (CmuxNextBrowser BrowserToolbarWebView, through
// CmuxNextPages BrowserChromeWebHost). Two pages:
//
// - `cmux-page://cmux.browser-toolbar/`: one per browser pane (and per popup window or Markdown bar),
//   the whole toolbar row: Back, Forward, Reload, the omnibar (chip, field, badges, star), the pinned
//   extension actions and the Extensions button, the trailing buttons and More. It owns the omnibar
//   state machine (../omnibox reduce) for every tab of the pane: one resting state per `tab` slot.
// - `cmux-page://cmux.omnibox-popup/`: the suggestion card, in its own panel under the bar (a Chromium
//   page is a child window above the main window, so the card cannot be part of the toolbar page).
//   It only draws rows and reports the pointer; the host relays its hover and picks to the toolbar
//   page, which decides.
//
// The host pushes the newest state on `cmux.<page>.state`; the page calls `cmux.<page>.command` with
// one of the commands below, and the popup also `cmux.omnibox-popup.size`. One-shot requests from the
// host (focus the field, rows arrived, a row was clicked) ride in the state as `events`, numbered;
// the toolbar page handles each `seq` once, in order, and acks the newest it handled, after which the
// host stops resending it. A page that subscribes late (its first load, a reload) still gets them.
import type { PageInfoSite } from "../page-info/model";
import type {
  BrowserSuggestion,
  OmnibarEffect,
  OmnibarFocusSource,
  OmnibarKey,
  OmnibarKeyword,
  SearchEngine,
} from "../omnibox/types";
import type { ExtensionAction } from "../ui/toolbarModel";

export const TOOLBAR_PAGE = "cmux.browser-toolbar";
export const POPUP_PAGE = "cmux.omnibox-popup";

// MARK: Host -> toolbar page

/** A trailing button as the host resolved it (`BrowserToolbarPolicy`: localized label with its shortcut). */
export type WireToolbarButton = {
  id: "media" | "zoom" | "favorites" | "downloads" | "designMode" | "profile" | "theme" | "devTools" | "overflow";
  /** A pack icon name (`IconName.rawValue`). */
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

/** Sizes at the app's density, in CSS px (ToolbarRowMetrics). The page lays the row out with them. */
export type ToolbarMetrics = {
  /** The bar's height, and each suggestion row's. */
  bar: number;
  /** The square toolbar buttons. */
  button: number;
  /** The bar's text size. */
  fontSize: number;
  toolbarIcon: number;
  trailingIcon: number;
  chipIcon: number;
  /** Space between neighboring buttons. */
  spacing: number;
  /** Reload to the bar, and the bar to the extensions. */
  margin: number;
  /** Leading inset of the row (the pane's chrome line). */
  inset: number;
  /** Trailing inset of the row (More under the tab bar's ⋮). */
  trailingInset: number;
  /** The bar's top inside the page's viewport (the row is the viewport's height). */
  barTop: number;
  /** The bar's corner radius (the look's, capped at half the bar). */
  cornerRadius: number;
  /** Omnibar width kept before a pinned extension moves into the menu. */
  preferredAddress: number;
  /** Omnibar width kept before Forward hides. */
  minimumAddress: number;
  /** Most pinned extension buttons shown. */
  maxPinned: number;
};

/** `browser.omnibar.glass` and `backgroundOpacity`: the bar's fill at rest. */
export type OmnibarLookWire = {
  /** `transparent`: no fill at rest; anything else: the flat theme fill. */
  material: "transparent" | "off" | "regular" | "clear";
  /** `browser.omnibar.backgroundOpacity`: how much the bar covers a see-through window, 0 to 1. */
  backgroundOpacity: number;
  /**
   * `backgroundOpacity` raised to the text's legibility floor in this window
   * (`AddressBarSurface.resolvedCoverage`); absent: `backgroundOpacity` as it is.
   */
  coverage?: number;
};

export type ToolbarBadges = {
  /** Browser focus mode: "Focus Mode", or "Esc again to exit" once armed. A press leaves it. */
  focusMode?: { text: string } | null;
  /** The tab's browser profile (more than one profile exists): a monogram on its color. */
  profile?: { monogram: string; color?: string | null; name: string } | null;
  /** The machine whose localhost the tab sees. A press opens its menu. */
  machine?: { text: string; help: string } | null;
};

/** What the omnibar's resolver and reducer need (the native engine's settings). */
export type OmnibarConfig = {
  /** A sign-in window's bar: shows and selects, never edits (AddressBarView.isReadOnly). */
  readOnly: boolean;
  /** Chromium tabs load chrome:// and chrome-extension:// pages too. */
  allowsChromiumSchemes: boolean;
  /** The user's home folder (`~/…` paths). */
  home: string;
  /** `browser.omnibar.showFullURLs`. */
  showFullURLs: boolean;
  searchEngine: SearchEngine;
  /** The tab's extension keywords, then the search engines' (tab to search). */
  keywords: OmnibarKeyword[];
  /** Bare words the intranet probe found (`wiki` loads http://wiki/). */
  intranetHosts: string[];
  /** Typed hosts whose TLD typo was fixed once (typed again: loaded as typed). */
  fixedTypoHosts: string[];
  /** The card opens above the bar (toolbar at the bottom of the pane). */
  upward: boolean;
  /** "Search %@" (`IDS_OMNIBOX_KEYWORD_TEXT`), localized; `%@` is the engine's name. */
  searchKeywordFormat: string;
};

/**
 * Text a tab left in its omnibar unsent, with its selection ([location, length]). It travels with the
 * tab when it moves to another pane, whose page has no slot for it.
 */
export type OmnibarDraft = { text: string; selection: [number, number] };

export type ToolbarHostEvent =
  /** Focus the field: Cmd-L and new tabs (`keyboard`), a return to the tab (`programmatic`). */
  | { kind: "focus"; source: OmnibarFocusSource }
  /** The host took the keys away (the web view resigned first responder). */
  | { kind: "blur" }
  /** A key the App routed: Return with a disposition (`omnibar.openIn…` actions), Opt-Cmd-F. */
  | { kind: "key"; key: OmnibarKey }
  | { kind: "suggestions"; generation: number; rows: BrowserSuggestion[] }
  | { kind: "moreSuggestions"; generation: number; rows: BrowserSuggestion[]; capacity: number }
  /** Relayed from the popup page. `pointer` is in screen points (a hover with no move is no hover). */
  | { kind: "rowHover"; row: number | null; pointer: { x: number; y: number } }
  /** The page turns the modifiers into a disposition as Return does (Cmd: background tab, ...). */
  | { kind: "rowClick"; row: number; modifiers: { meta: boolean; shift: boolean; alt: boolean } }
  /** Show the page's address again (a commit that opened elsewhere). */
  | { kind: "showPageURL" }
  /** Paste and Go / Paste and Search from the field's menu. */
  | { kind: "pasteAndGo"; text: string }
  /** A native drop on the bar. */
  | { kind: "dropped"; text: string }
  /** Tab slot `tab` closed or moved to another pane: forget its resting omnibar. */
  | { kind: "forgetTab"; tab: string }
  /** Type `text` into the field and (with `commit`) press Return (`debug.omnibar_type`). */
  | { kind: "debugType"; text: string; commit: boolean };

export type ToolbarHostState = {
  revision: number;
  /** The tab slot shown now. Each slot keeps its own omnibar state (`OmniboxView::SaveStateToTab`). */
  tab: string;
  /**
   * The draft `tab` brought from the pane it left (null: none). The page rests on it only when it has
   * no slot for `tab`; its own slot is newer.
   */
  draft?: OmnibarDraft | null;
  /** The shown page's address (null: none, the New Tab page shows an empty bar). */
  url: string | null;
  /** What the chip describes (null: an empty or blank page). */
  site: PageInfoSite | null;
  /** The page's title, for a drag of the address out of the chip. */
  title: string | null;
  navigation: { canGoBack: boolean; canGoForward: boolean; loading: boolean };
  /** The row has the navigation buttons and trailing buttons (false: the omnibar alone, a popup window). */
  showsButtons: boolean;
  bookmark: "hidden" | "off" | "on";
  pageInfoOpen: boolean;
  badges: ToolbarBadges;
  extensions: {
    shows: boolean;
    pinned: ExtensionAction[];
    /** The pinned action whose menu or popup is open (drawn pressed). */
    pressed?: string | null;
    /** The Extensions bubble is open (its button drawn pressed). */
    extensionsPressed?: boolean;
    /**
     * An extension of the tab's profile crashed: a warning button (icon
     * `browser.toolbar.extensions.crashed`, `label` as its name and tooltip) before the Extensions
     * button; a press sends `reloadCrashedExtensions`. Rect key `extensionsCrashed`.
     */
    crashed?: { label: string } | null;
  };
  /** The pinned trailing buttons that have something to show, More included, in catalog order. */
  buttons: WireToolbarButton[];
  omnibar: OmnibarConfig;
  look: OmnibarLookWire;
  metrics: ToolbarMetrics;
  /** Host requests not yet acked, oldest first. */
  events: { seq: number; event: ToolbarHostEvent }[];
};

// MARK: Toolbar page -> host

/** A rect in the web view, CSS px from its top-left: [x, y, width, height]. */
export type WireRect = [number, number, number, number];

export type ToolbarPageCommand =
  // Buttons (the host runs the same registry actions as before).
  | { type: "goBack" }
  | { type: "goForward" }
  | { type: "reload" }
  | { type: "stop" }
  /** Right-click on Back or Forward: the history menu under the button; on Reload, the reload menu. */
  | { type: "navigationMenu"; direction: "back" | "forward" | "reload" }
  | { type: "pageInfo" }
  | { type: "bookmark" }
  | { type: "toolbarButton"; button: WireToolbarButton["id"] }
  | { type: "extensionAction"; id: string }
  | { type: "extensionContextMenu"; id: string }
  | { type: "extensionsMenu" }
  | { type: "reloadCrashedExtensions" }
  /** Drag reorder of a pinned extension (its new index among the pinned). */
  | { type: "moveExtension"; id: string; index: number }
  | { type: "focusModeBadge" }
  | { type: "profileBadge" }
  | { type: "machineBadge" }
  /** The pointer went down on the field (or the bar around it): give the web view the keys. */
  | { type: "requestFocus" }
  /** One of the reducer's effects, in order, for the host to run (queries, began/ended, beep, ...). */
  | { type: "effect"; effect: OmnibarEffect }
  /** The omnibar after each step that changed any of these (the App reads them synchronously). */
  | {
      type: "status";
      phase: "idle" | "focused" | "editing" | "committing";
      editing: boolean;
      popupOpen: boolean;
      text: string;
      selection: [number, number] | null;
      elided: boolean;
      rows: string[];
      highlighted: number | null;
      /** The tab slot this status describes. */
      tab: string | null;
      /** What the tab would leave unsent if it left now (the host keeps it with the tab). */
      draft: OmnibarDraft | null;
    }
  /** The card: rows to show (empty closes it), the highlighted one, and the side. */
  | { type: "popup"; rows: BrowserSuggestion[]; highlighted: number | null; upward: boolean }
  /**
   * Where the controls are, after each layout that moved one: keys "back", "forward", "reload",
   * "omnibar", "chip", "text" (the I-beam area), "star", "extensions", "action:<id>",
   * "button:<id>", "badge:focusMode|profile|machine". Hidden controls are absent.
   */
  | { type: "layout"; rects: Record<string, WireRect>; showsForward: boolean; visiblePinned: number; collapse: number }
  /** Host events handled up to `seq`. */
  | { type: "ack"; seq: number };

// MARK: Host -> popup page

export type PopupRow = {
  kind: BrowserSuggestion["kind"];
  title: string;
  detail: string;
  /** A data URL of the row's site icon, once the host fetched it. */
  faviconUrl?: string;
};

export type PopupHostState = {
  revision: number;
  rows: PopupRow[];
  highlighted: number | null;
  upward: boolean;
  metrics: ToolbarMetrics;
  /** Card corner radius (the bar's). */
  cornerRadius: number;
  /** Space around the card inside the panel, for its shadow: [top, right, bottom, left]. */
  margin: [number, number, number, number];
};

// MARK: Popup page -> host

export type PopupPageCommand =
  /** The pointer is over row `index` (null: left the rows); `pointer` in screen points (screenX/Y). */
  | { type: "hover"; index: number | null; pointer: { x: number; y: number } }
  | { type: "pick"; index: number; modifiers: { meta: boolean; shift: boolean; alt: boolean } };
// The popup also calls `cmux.omnibox-popup.size` with `{ height, revision }` after each state.
