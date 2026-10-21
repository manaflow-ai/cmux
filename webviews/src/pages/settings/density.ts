// Densities on the Settings page (plans/cmux-next/density-DESIGN.md): the built-ins, the custom
// ones in appearance.customDensities, and the token math the previews draw with. The rules are
// Swift `DensityTokens.resolve`, `textSize` and `space`; the compact/comfortable pairs are the
// `MetricTunables` and `Typography` values the previews show. density.test.ts pins both.

export const DENSITY_KEY = "appearance.density";
export const CUSTOM_DENSITY_KEY = "appearance.customDensity";
export const CUSTOM_DENSITIES_KEY = "appearance.customDensities";
/** The rows the density card draws, left out of their group. */
export const DENSITY_ROWS: ReadonlySet<string> = new Set([DENSITY_KEY, CUSTOM_DENSITY_KEY, CUSTOM_DENSITIES_KEY]);

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

/** The built-ins, densest first; `name` is the catalog key of the localized name. */
export const PRESETS: ReadonlyArray<Density & { nameKey: string }> = [
  { id: "ultraCompact", name: "Ultra-compact", nameKey: "settings.choice.ultraCompact", level: -0.5, spacing: 0.75 },
  { id: "compact", name: "Compact", nameKey: "settings.choice.compact", level: 0 },
  { id: "cozy", name: "Cozy", nameKey: "settings.choice.cozy", level: 0.5 },
  { id: "comfortable", name: "Comfortable", nameKey: "settings.choice.comfortable", level: 1 },
  { id: "spacious", name: "Spacious", nameKey: "settings.choice.spacious", level: 1.75, spacing: 1.25 },
];

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

const half = (value: number) => Math.round(value * 2) / 2;
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

/** The sizes `density` draws (Swift `DensityTokens`): exact tokens win, else the level's point. */
export function resolve(density: Density): Resolved {
  const level = density.level;
  const metric = (name: keyof typeof PAIRS) => density.tokens?.[name] ?? at(PAIRS[name], level, Math.round);
  const levelBody = at(BODY, level, half);
  const text = (pair: readonly [number, number]) => {
    const size = at(pair, level, half);
    return density.fontSize === undefined ? size : half((size * density.fontSize) / levelBody);
  };
  const spacing = density.spacing ?? 1;
  return {
    sidebarRowHeight: metric("sidebarRowHeight"),
    tabHeight: metric("tabHeight"),
    tabStripHeight: metric("tabStripHeight"),
    itemCornerRadius: metric("itemCornerRadius"),
    iconSize: metric("iconSize"),
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
  return { ...density, id: uniqueID(density.id, existing) };
}
