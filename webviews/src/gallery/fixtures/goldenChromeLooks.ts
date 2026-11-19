// l10n-allow-file: gallery fixtures, public-safe look names and notes.
// The golden chrome preview's looks: each one is a theme file fragment, written with the keys a theme file
// takes (`density` with Density Playground tokens, and look keys such as `tabs.plusButton`), so a look picked
// here ships as theme values, not as a fork of the chrome. `proposed` holds the few choices that have no
// setting yet (toolbar button style, Home card style, inline Session Info); the preview draws them and says so.

/** Density Playground tokens the preview reads (`DensityTokenCatalog`), in points. */
export type GoldenDensityTokens = {
  sidebarWidth: number;
  sidebarRowHeight: number;
  sidebarCornerRadius: number;
  verticalTabCornerRadius: number;
  browserRowHeight: number;
  tabGap: number;
  tabCornerRadius: number;
  controlHeight: number;
  itemCornerRadius: number;
  panelCornerRadius: number;
};

/** What a theme file says: a `density` block and look keys (`ThemeFileOverlay.lookKeys`). */
export type GoldenThemeFragment = {
  density?: { basedOn?: "compact" | "cozy" | "comfortable"; tokens: Partial<GoldenDensityTokens> };
  "appearance.chromeStyle"?: "default" | "card" | "flat" | "floating" | "blocks";
  "agentPane.display.sessionInfo.placement"?: "push" | "overlay";
  "tabs.plusButton"?: "hover" | "always";
  "layout.paneCornerRadius"?: number;
};

/** Choices with no setting yet: drawn, and named as proposals in the preview's key line. */
export type GoldenProposed = {
  "tabs.toolbarButtonStyle"?: "plain" | "grouped" | "glass";
  "home.cardStyle"?: "flat" | "raised" | "glass";
  "agentPane.display.sessionInfo.placement"?: "inline";
};

export type GoldenLook = {
  /** The area this look varies (its sheet), or `look` for a whole-window look. */
  area: "tabs" | "sidebar-width" | "session-info" | "toolbar-buttons" | "home-cards" | "look";
  label: string;
  note: string;
  theme: GoldenThemeFragment;
  proposed?: GoldenProposed;
};

/** Default's sizes (`DensityPreset.reference`, `MetricTunables.sidebarWidth` comfortable). */
export const GOLDEN_DEFAULT_TOKENS: GoldenDensityTokens = {
  sidebarWidth: 240,
  sidebarRowHeight: 28,
  sidebarCornerRadius: 9,
  verticalTabCornerRadius: 9,
  browserRowHeight: 30,
  tabGap: 3,
  tabCornerRadius: 9,
  controlHeight: 26,
  itemCornerRadius: 7,
  panelCornerRadius: 12,
};

/** A shape moves the horizontal tabs, the sidebar's rows and its vertical tabs together. */
const shape = (radius: number, extra: Partial<GoldenDensityTokens> = {}): Partial<GoldenDensityTokens> => ({
  tabCornerRadius: radius,
  sidebarCornerRadius: radius,
  verticalTabCornerRadius: radius,
  itemCornerRadius: Math.min(radius, 16),
  ...extra,
});

export const GOLDEN_LOOKS = {
  // Tabs: horizontal and the sidebar's vertical ones, one corner.
  "tabs-soft": {
    area: "tabs",
    label: "Soft",
    note: "Today's corner (9 pt) on tabs, sidebar rows and vertical tabs.",
    theme: { density: { tokens: shape(9) } },
  },
  "tabs-capsule": {
    area: "tabs",
    label: "Capsule",
    note: "Half the tab height: capsule tabs and rows.",
    theme: { density: { tokens: shape(15, { sidebarRowHeight: 30, panelCornerRadius: 18 }) } },
  },
  "tabs-square": {
    area: "tabs",
    label: "Square",
    note: "Blocky: 2 pt corners, tabs edge to edge.",
    theme: { density: { tokens: shape(2, { tabGap: 1, panelCornerRadius: 4 }) }, "layout.paneCornerRadius": 4 },
  },
  // Sidebar width.
  "sidebar-240": {
    area: "sidebar-width",
    label: "240 pt",
    note: "Today's default width.",
    theme: { density: { tokens: { sidebarWidth: 240 } } },
  },
  "sidebar-280": {
    area: "sidebar-width",
    label: "280 pt",
    note: "Room for longer titles and status.",
    theme: { density: { tokens: { sidebarWidth: 280 } } },
  },
  "sidebar-320": {
    area: "sidebar-width",
    label: "320 pt",
    note: "A wide list with roomy rows.",
    theme: { density: { tokens: { sidebarWidth: 320, sidebarRowHeight: 32 } } },
  },
  // Session Info.
  "session-docked": {
    area: "session-info",
    label: "Docked",
    note: "Session Info pushes the chat aside (placement push).",
    theme: { "agentPane.display.sessionInfo.placement": "push" },
  },
  "session-floating": {
    area: "session-info",
    label: "Floating card",
    note: "Session Info floats over the chat (placement overlay).",
    theme: { "agentPane.display.sessionInfo.placement": "overlay" },
  },
  "session-inline": {
    area: "session-info",
    label: "Inline",
    note: "Session Info as a band over the chat: a proposed placement.",
    theme: {},
    proposed: { "agentPane.display.sessionInfo.placement": "inline" },
  },
  // Top right buttons.
  "buttons-plain": {
    area: "toolbar-buttons",
    label: "Plain icons",
    note: "Bare glyphs; a fill only on hover.",
    theme: { "tabs.plusButton": "always" },
    proposed: { "tabs.toolbarButtonStyle": "plain" },
  },
  "buttons-grouped": {
    area: "toolbar-buttons",
    label: "Grouped pill",
    note: "One filled pill holds the buttons.",
    theme: { "tabs.plusButton": "always" },
    proposed: { "tabs.toolbarButtonStyle": "grouped" },
  },
  "buttons-glass": {
    area: "toolbar-buttons",
    label: "Glass capsule",
    note: "A glass capsule with a rim over the window.",
    theme: { "tabs.plusButton": "always", density: { tokens: { controlHeight: 28 } } },
    proposed: { "tabs.toolbarButtonStyle": "glass" },
  },
  // Home cards.
  "home-flat": {
    area: "home-cards",
    label: "Flat",
    note: "Tonal fill, no edge, no shade.",
    theme: {},
    proposed: { "home.cardStyle": "flat" },
  },
  "home-raised": {
    area: "home-cards",
    label: "Raised",
    note: "An elevated card with a hairline and a soft shadow.",
    theme: {},
    proposed: { "home.cardStyle": "raised" },
  },
  "home-glass": {
    area: "home-cards",
    label: "Glass",
    note: "See-through cards with a rim over the window's picture.",
    theme: {},
    proposed: { "home.cardStyle": "glass" },
  },
  // Whole-window looks: the showcase themes' shapes (examples/customize-showcase, examples/customize/leo).
  "look-stock": {
    area: "look",
    label: "Stock",
    note: "Today's chrome: soft tabs, 240 pt sidebar, docked Session Info.",
    theme: {},
  },
  "look-arcade": {
    area: "look",
    label: "Arcade",
    note: "Square tabs, rows, buttons and panes; a tight strip; a 260 pt sidebar.",
    theme: {
      density: {
        basedOn: "compact",
        tokens: shape(2, {
          sidebarWidth: 260,
          tabGap: 1,
          browserRowHeight: 26,
          sidebarRowHeight: 24,
          panelCornerRadius: 3,
        }),
      },
      "layout.paneCornerRadius": 2,
      "appearance.chromeStyle": "blocks",
    },
    proposed: { "tabs.toolbarButtonStyle": "grouped", "home.cardStyle": "flat" },
  },
  "look-neon": {
    area: "look",
    label: "Neon",
    note: "Capsule tabs and rows, a 280 pt sidebar, glass buttons and cards.",
    theme: {
      density: { tokens: shape(15, { sidebarWidth: 280, sidebarRowHeight: 30, panelCornerRadius: 18 }) },
      "agentPane.display.sessionInfo.placement": "overlay",
      "appearance.chromeStyle": "floating",
    },
    proposed: { "tabs.toolbarButtonStyle": "glass", "home.cardStyle": "glass" },
  },
  "look-dusk": {
    area: "look",
    label: "Dusk",
    note: "Soft rounded tabs, a 300 pt sidebar, raised cards, inline Session Info.",
    theme: {
      density: {
        basedOn: "comfortable",
        tokens: shape(12, { sidebarWidth: 300, sidebarRowHeight: 30, panelCornerRadius: 16 }),
      },
      "appearance.chromeStyle": "card",
    },
    proposed: { "agentPane.display.sessionInfo.placement": "inline", "home.cardStyle": "raised" },
  },
} satisfies Record<string, GoldenLook>;

export type GoldenLookId = keyof typeof GOLDEN_LOOKS;

/** The look resolved: tokens over Default's, and every choice the preview draws. */
export function resolveGoldenLook(id: GoldenLookId) {
  const look: GoldenLook = GOLDEN_LOOKS[id];
  const tokens = { ...GOLDEN_DEFAULT_TOKENS, ...look.theme.density?.tokens };
  return {
    look,
    tokens,
    sessionInfo:
      look.proposed?.["agentPane.display.sessionInfo.placement"] ??
      look.theme["agentPane.display.sessionInfo.placement"] ??
      "push",
    buttons: look.proposed?.["tabs.toolbarButtonStyle"] ?? "plain",
    cards: look.proposed?.["home.cardStyle"] ?? "raised",
    chrome: look.theme["appearance.chromeStyle"] ?? "default",
    paneRadius: look.theme["layout.paneCornerRadius"] ?? tokens.panelCornerRadius,
  };
}
