// Densities on the Settings page (plans/cmux-next/density-DESIGN.md): the built-ins, the custom
// ones in appearance.customDensities, and the token math the previews draw with. The rules are
// Swift `DensityTokens.resolve`, `textSize` and `space`; the compact/comfortable pairs are the
// `MetricTunables` and `Typography` values the previews show. density.test.ts pins both.

export const DENSITY_KEY = "appearance.density";
export const CUSTOM_DENSITY_KEY = "appearance.customDensity";
export const CUSTOM_DENSITIES_KEY = "appearance.customDensities";
/** Text Size: the chrome body size in points, over any density's. The density card draws its row. */
export const TEXT_SIZE_KEY = "appearance.metrics.chromeFontSize";
/** The rows the density card draws, left out of their group. */
export const DENSITY_ROWS: ReadonlySet<string> = new Set([DENSITY_KEY, CUSTOM_DENSITY_KEY, CUSTOM_DENSITIES_KEY]);
/** Every row the density card holds: DENSITY_ROWS, and Text Size as a normal row inside it. */
export const DENSITY_CARD_ROWS: ReadonlySet<string> = new Set([...DENSITY_ROWS, TEXT_SIZE_KEY]);

export type Density = {
  id: string;
  name: string;
  basedOn?: string;
  level: number;
  spacing?: number;
  fontSize?: number;
  tokens?: Record<string, number>;
};

export const LEVEL_RANGE = { min: -1, max: 2.5 } as const;
export const SPACING_RANGE = { min: 0.5, max: 2 } as const;
export const FONT_RANGE = { min: 9, max: 20 } as const;

/** Default's chrome body text in points: the ChatGPT and Codex desktop apps' size. */
const DEFAULT_BODY_POINTS = 14;

/** Swift `DensityTokens.half`: the nearest half point. */
const half = (value: number) => Math.round(value * 2) / 2;

// Keep the exported preset payload equal to Swift DensityPreset.reference.
const REFERENCE_TOKENS: Record<string, number> = {
  sidebarRowHeight: 28,
  browserRowHeight: 30,
  browserRowGap: 3,
  tabStripHeight: 36,
  tabTitleSize: 14,
  sidebarTitleSize: 14,
  chatEditorMin: 35,
  sidebarRowInset: 6,
  sidebarContentInset: 7,
  sidebarLineBoxBaseline: 1,
  sidebarIconColumn: 16.5,
  sidebarIconGap: 7,
  tabIconSize: 16.5,
  tabIconTitleGap: 7,
  tabGap: 3,
  tabMaxWidth: 201,
  rowCornerRadius: 9,
  tabCornerRadius: 9,
  omnibarCornerRadius: 8 / 0.9,
  omnibarPopupCornerRadius: 12,
  omnibarPopupRowCornerRadius: 8,
  toolbarGlyphSize: 14 / 0.9 / 0.617,
  omnibarHeight: 28 / 0.9,
  omnibarFontSize: (10 - 0.31) / 0.70459 / 0.9,
  omnibarLineBoxBaseline: 1,
  omnibarButtonSpacing: 3,
  omnibarEdgeInset: 2,
  omnibarFieldTrailingGap: 5,
  omnibarTrailingPadding: 8,
  omnibarTrailingIconSize: 18,
  omnibarIconViewSize: 25,
  omnibarIconSize: 12 / 0.9 / 0.697,
  omnibarIconLeading: 2,
  omnibarTextGap: 5,
  omnibarPopupTopOutset: 3,
  omnibarPopupSideOutset: 7,
  omnibarPopupRowGap: 2,
  omnibarPopupBottomPadding: 4,
};

const CHROME_OMNIBAR_HEIGHT = 34;

/** Swift `DensityPreset.isOmnibarToken`: every `omnibar*` size and the toolbar glyphs beside the bar. */
const omnibarTokens = (tokens: Record<string, number>) =>
  Object.fromEntries(Object.entries(tokens).filter(([key]) => key.startsWith("omnibar") || key === "toolbarGlyphSize"));

/** A built-in as Swift `DensityPreset.tokens` makes it: Default's level, spacing and body text times one factor,
 *  and the owner's row height exact (Lucas 2026-11-16: 24, 28, 30, 32 and 36 pt rows). */
function preset(id: string, name: string, nameKey: string, factor: number, row: number): Density & { nameKey: string } {
  const tokens = Object.fromEntries(
    Object.entries(REFERENCE_TOKENS).map(([key, value]) => [key, half(value * factor)]),
  );
  for (const key of ["tabTitleSize", "sidebarTitleSize", "omnibarFontSize"])
    tokens[key] = REFERENCE_TOKENS[key]! * factor;
  tokens.sidebarLineBoxBaseline = 1;
  tokens.omnibarLineBoxBaseline = 1;
  tokens.densityScale = factor;
  tokens.composerZoom = factor;
  tokens.sidebarRowHeight = row - half(2 * factor);
  tokens.browserRowHeight = row;
  tokens.tabStripHeight = row + 2 * half(3 * factor);
  // Default's omnibar is Compact's (Swift `DensityPreset.omnibarScaleFactor`), on Chrome's 34 pt bar
  // (Swift `DensityPreset.chromeOmnibarHeight`) rounded at Helium's 8 on 28.
  if (id === "cozy") {
    Object.assign(tokens, omnibarTokens(preset("compact", "", "", 0.9, 28).tokens!));
    tokens.omnibarHeight = CHROME_OMNIBAR_HEIGHT;
    tokens.omnibarCornerRadius = half((CHROME_OMNIBAR_HEIGHT * 8) / 28);
  }
  return {
    id,
    name,
    nameKey,
    level: Math.round(((0.5 + 3) * factor - 3) * 1000) / 1000,
    spacing: factor,
    fontSize: Math.round(DEFAULT_BODY_POINTS * factor * 1000) / 1000,
    tokens,
  };
}

/** The built-ins, densest first (Swift `DensityPreset`); `name` is the catalog key of the
 * localized name. Default keeps the id `cozy` so saved files still name it. Each is Default times one factor. */
export const PRESETS: ReadonlyArray<Density & { nameKey: string }> = [
  preset("ultraCompact", "Ultra-compact", "settings.choice.ultraCompact", 0.8, 24),
  preset("compact", "Compact", "settings.choice.compact", 0.9, 28),
  preset("cozy", "Default", "settings.choice.default", 1, 30),
  preset("comfortable", "Comfortable", "settings.choice.comfortable", 1.1, 32),
  preset("spacious", "Spacious", "settings.choice.spacious", 1.2, 36),
];
/** The density when appearance.density is unset (Swift `DensitySetting.fallback`). */
export const DEFAULT_DENSITY = "cozy";

/** The metrics a preview draws and the editor's exact sizes: [compact, comfortable] in points. */
export const PAIRS = {
  sidebarRowHeight: [24, 32],
  tabHeight: [24, 30],
  tabStripHeight: [28, 36],
  itemCornerRadius: [6, 7],
  iconSize: [14, 16],
} as const satisfies Record<string, readonly [number, number]>;
const BODY = [12, 13] as const;
const CAPTION = [10.5, 11] as const;

/** The icon scale glyph boxes sit on (Swift `DensityTokens.iconScale`, design/grid.md). */
export const ICON_SCALE = [12, 14, 16, 20, 24] as const;
/** Swift `resolveGlyph`: the level's point on the nearest icon-scale step; a tie goes down below
 * level 0.5 and up from it, so no density draws a 13, 15 or 18 px glyph. */
const glyph = (pair: readonly [number, number], level: number) => {
  const value = at(pair, level, Math.round);
  return ICON_SCALE.reduce((best, step) => {
    const d = Math.abs(step - value) - Math.abs(best - value);
    return d < 0 || (d === 0 && (level < 0.5 ? step < best : step > best)) ? step : best;
  });
};
const at = (pair: readonly [number, number], level: number, round: (value: number) => number) =>
  level === 0 ? pair[0] : level === 1 ? pair[1] : round(pair[0] + (pair[1] - pair[0]) * level);

export type Resolved = {
  sidebarRowHeight: number;
  tabHeight: number;
  tabStripHeight: number;
  itemCornerRadius: number;
  iconSize: number;
  body: number;
  caption: number;
  inset: number;
};

/** The fill native sidebar rows add to a preset copy's stored base height. */
export function densityRowFill(density: Density): number {
  return density.tokens?.densityScale === undefined ? 0 : half(2 * (density.spacing ?? 1));
}

/** Map displayed sizes to the tokens read by the native sidebar and tab strip. */
export function setExactMetric(density: Density, name: keyof typeof PAIRS, value: number): Density {
  const tokens = { ...density.tokens, [name]: value };
  if (name === "sidebarRowHeight") tokens.sidebarRowHeight = Math.max(0, value - densityRowFill(density));
  if (name === "itemCornerRadius") {
    tokens.rowCornerRadius = value;
    tokens.tabCornerRadius = value;
  }
  if (name === "iconSize") {
    tokens.tabIconSize = value;
    // Native workspace glyph scale divides by the column, even when a zero-size icon is hidden.
    tokens.sidebarIconColumn = Math.max(1, value);
  }
  return { ...density, tokens };
}

/** The sizes `density` draws (Swift `DensityTokens`): exact tokens win, else the level's point. */
export function resolve(density: Density): Resolved {
  const level = density.level;
  const factor = density.tokens?.densityScale;
  const metric = (name: keyof typeof PAIRS) =>
    density.tokens?.[name] ??
    (factor === undefined ? at(PAIRS[name], level, Math.round) : half(at(PAIRS[name], 0.5, Math.round) * factor));
  const levelBody = at(BODY, level, half);
  const text = (pair: readonly [number, number]) => {
    if (factor !== undefined) {
      const reference = half((at(pair, 0.5, half) * DEFAULT_BODY_POINTS) / at(BODY, 0.5, half));
      return reference * (density.fontSize === undefined ? factor : density.fontSize / DEFAULT_BODY_POINTS);
    }
    const size = at(pair, level, half);
    return density.fontSize === undefined ? size : half((size * density.fontSize) / levelBody);
  };
  const spacing = density.spacing ?? 1;
  // A tab is the density's row unless the density sets its own (Swift `Metrics.tabHeight`, tabs follow rows); a strip
  // without its own height grows by as much as the tab outgrows the level's tab (Swift `Metrics.tabStripHeight`).
  const rowHeight = metric("sidebarRowHeight") + densityRowFill(density);
  const tabHeight = density.tokens?.tabHeight ?? density.tokens?.browserRowHeight ?? rowHeight;
  const levelStrip =
    at(PAIRS.tabStripHeight, level, Math.round) + Math.max(0, tabHeight - at(PAIRS.tabHeight, level, Math.round));
  return {
    sidebarRowHeight: rowHeight,
    tabHeight,
    tabStripHeight:
      density.tokens?.browserRowGap === undefined
        ? (density.tokens?.tabStripHeight ?? levelStrip)
        : tabHeight + 2 * density.tokens.browserRowGap,
    // A row's corner is Chrome's tab corner on its height, 8 on 30 (Swift `chromeRowCornerRadius`), so every
    // density rounds alike.
    itemCornerRadius:
      density.tokens?.rowCornerRadius ?? density.tokens?.itemCornerRadius ?? Math.round((rowHeight * 8) / 30),
    iconSize:
      density.tokens?.tabIconSize ??
      density.tokens?.iconSize ??
      (factor === undefined ? glyph(PAIRS.iconSize, level) : half(glyph(PAIRS.iconSize, 0.5) * factor)),
    body: density.fontSize ?? levelBody,
    caption: text(CAPTION),
    inset: spacing === 1 ? 6 : half(6 * spacing),
  };
}

const clamp = (value: number, range: { min: number; max: number }) => Math.min(Math.max(value, range.min), range.max);

/** The custom densities stored in `value` (a cmux.json list); anything else is none. */
export function customDensities(value: unknown): Density[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry): Density[] => {
    if (typeof entry !== "object" || entry === null) return [];
    const item = entry as Record<string, unknown>;
    if (typeof item.id !== "string" || typeof item.name !== "string") return [];
    const number = (key: string) => (typeof item[key] === "number" ? (item[key] as number) : undefined);
    const tokens =
      typeof item.tokens === "object" && item.tokens !== null ? (item.tokens as Record<string, number>) : undefined;
    return [
      {
        id: item.id,
        name: item.name,
        ...(typeof item.basedOn === "string" ? { basedOn: item.basedOn } : {}),
        level: number("level") ?? 0,
        ...(number("spacing") !== undefined ? { spacing: number("spacing") } : {}),
        ...(number("fontSize") !== undefined ? { fontSize: number("fontSize") } : {}),
        ...(tokens ? { tokens } : {}),
      },
    ];
  });
}

/** The JSON a density is stored and exported as (Swift `CustomDensitiesSetting.json`). */
export function toJSON(density: Density): Record<string, unknown> {
  const out: Record<string, unknown> = { id: density.id, name: density.name, level: clamp(density.level, LEVEL_RANGE) };
  if (density.basedOn) out.basedOn = density.basedOn;
  if (density.spacing !== undefined && density.spacing !== 1) out.spacing = clamp(density.spacing, SPACING_RANGE);
  if (density.fontSize !== undefined) out.fontSize = clamp(density.fontSize, FONT_RANGE);
  if (density.tokens && Object.keys(density.tokens).length > 0) out.tokens = density.tokens;
  return out;
}

/** An id for `name` that no built-in and none of `existing` uses (Swift `CustomDensitiesSetting.uniqueID`). */
export function uniqueID(name: string, existing: ReadonlyArray<Density>): string {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  const base = slug === "" ? "custom" : slug;
  const taken = new Set([...existing.map((density) => density.id), ...PRESETS.map((preset) => preset.id)]);
  if (!taken.has(base)) return base;
  let index = 2;
  while (taken.has(`${base}-${index}`)) index += 1;
  return `${base}-${index}`;
}

/** A custom copy of `base` named `name`. */
export function duplicate(base: Density, name: string, existing: ReadonlyArray<Density>): Density {
  const builtIn = PRESETS.some((preset) => preset.id === base.id);
  const { nameKey: _nameKey, ...plain } = base as Density & { nameKey?: string };
  return { ...plain, id: uniqueID(name, existing), name, basedOn: builtIn ? base.id : base.basedOn };
}

/** A density read from exported JSON text; null when it is not one. */
export function parseExport(text: string, existing: ReadonlyArray<Density>): Density | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  const [density] = customDensities([value]);
  if (!density || density.name.trim() === "") return null;
  return {
    ...density,
    id: uniqueID(density.id, existing),
    basedOn: PRESETS.some((preset) => preset.id === density.id) ? density.id : density.basedOn,
  };
}
