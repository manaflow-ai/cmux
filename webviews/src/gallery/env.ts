// The gallery's controls: one value set, kept in the URL query, so a link reproduces a view.
// The query keys are the one contract of every gallery tool: the shell, the stage frames, the
// matrix manifest (scripts/gallery-matrix) and the native gallery (CmuxNextGallery
// GalleryEnvironment) read the same names: entry, variant, locale, theme, colorScheme, fontFamily,
// fontSize, density, scale, width, height, reducedMotion, highContrast, dynamicSize, windowKey,
// frame, window, zoom, layout.
// The shell keeps it in its own URL and passes the same query to every stage frame; the matrix
// runner builds frame URLs from it. Defaults are left out of the query, so links stay short.
import { DEFAULT_DARK_THEME } from "./theme/ghostty";
import { PANE_LAYOUTS, WINDOW_PRESETS, type PaneLayout } from "./window";

/** The 21 languages the app ships (Localizable.xcstrings, scripts/pages/gen-strings.mjs LOCALES). */
export const LOCALES = [
  "en",
  "ar",
  "bs",
  "da",
  "de",
  "es",
  "fr",
  "it",
  "ja",
  "km",
  "ko",
  "nb",
  "pl",
  "pt-BR",
  "ru",
  "th",
  "tr",
  "uk",
  "vi",
  "zh-Hans",
  "zh-Hant",
] as const;

/** Pseudo-locales (pseudo.ts): long accented text, and right-to-left. Never shipped. */
export const PSEUDO_LOCALES = ["en-XA", "ar-XB"] as const;

/** Pane widths of web entries; an entry may name its own (format.ts `widths`). */
export const WIDTHS = { narrow: 420, normal: 760, wide: 1200 } as const;
/** Native entries' widths in points (the Home and Chief views'). */
export const NATIVE_WIDTHS = { narrow: 320, normal: 560, wide: 900 } as const;
export type WidthName = keyof typeof WIDTHS;

/** Native only: the text size (Dynamic Type) and whether the window is key. */
export const DYNAMIC_SIZES = ["default", "large", "xlarge"] as const;
export type DynamicSize = (typeof DYNAMIC_SIZES)[number];

export const DENSITIES = ["comfortable", "compact"] as const;
export type Density = (typeof DENSITIES)[number];

export const SCALES = [0.8, 0.9, 1, 1.1, 1.25, 1.5] as const;

export type GalleryEnv = {
  locale: string;
  /** The Ghostty theme the window shows (a shipped theme's file name). */
  theme: string;
  /** The window appearance; `auto` is the theme's own (dark when its background is darker). */
  colorScheme: "auto" | "dark" | "light";
  /** Empty: the page's own font. */
  fontFamily: string;
  /** Px; 0 is the page's own size. */
  fontSize: number;
  density: Density;
  /** Interface scale (WKWebView pageZoom, DesignSettings.uiScale). */
  scale: number;
  /** A named width or a number of px. */
  width: WidthName | number;
  /** Px; 0 fits the state's own height. */
  height: number;
  reducedMotion: boolean;
  highContrast: boolean;
  /** Native only (web pages have no input for it). */
  dynamicSize: DynamicSize;
  /** Native only: the window is key or inactive. */
  windowKey: "key" | "inactive";
  /** `window`: the entry at its real size in a cmux window; `component`: the entry alone. */
  frame: "window" | "component";
  /** The window's size: a preset (window.ts) or `<width>x<height>`. */
  window: string;
  /** The shell's scale of a window: `fit` the view, or a fraction. */
  zoom: "fit" | number;
  /** The panes around the entry. */
  layout: PaneLayout;
};

export const DEFAULT_ENV: GalleryEnv = {
  locale: "en",
  theme: DEFAULT_DARK_THEME,
  colorScheme: "auto",
  fontFamily: "",
  fontSize: 0,
  density: "comfortable",
  scale: 1,
  width: "normal",
  height: 0,
  reducedMotion: false,
  highContrast: false,
  dynamicSize: "default",
  windowKey: "key",
  frame: "window",
  window: "16x9",
  zoom: "fit",
  layout: "one",
};

export const ZOOMS = ["fit", 0.5, 0.75, 1] as const;

const KEYS = Object.keys(DEFAULT_ENV) as (keyof GalleryEnv)[];

export function widthPx(width: GalleryEnv["width"], presets: Partial<Record<WidthName, number>> = WIDTHS): number {
  return typeof width === "number" ? width : (presets[width] ?? WIDTHS[width]);
}

const flag = (value: string | null) => value === "1" || value === "true";

function finite(value: string | null, fallback: number, min: number, max: number): number {
  const parsed = Number(value);
  return value !== null && Number.isFinite(parsed) ? Math.min(Math.max(parsed, min), max) : fallback;
}

/** The controls a query names; anything missing or invalid keeps its default. */
export function readEnv(params: URLSearchParams): GalleryEnv {
  const env: GalleryEnv = { ...DEFAULT_ENV };
  const locale = params.get("locale");
  if (locale && ([...LOCALES, ...PSEUDO_LOCALES] as readonly string[]).includes(locale)) env.locale = locale;
  env.theme = params.get("theme") || env.theme;
  const scheme = params.get("colorScheme");
  if (scheme === "dark" || scheme === "light") env.colorScheme = scheme;
  env.fontFamily = (params.get("fontFamily") ?? "").slice(0, 200);
  env.fontSize = finite(params.get("fontSize"), 0, 0, 40);
  if (params.get("density") === "compact") env.density = "compact";
  env.scale = finite(params.get("scale"), 1, 0.5, 3);
  const width = params.get("width");
  if (width && width in WIDTHS) env.width = width as WidthName;
  else if (width && /^\d+$/.test(width)) env.width = Math.min(Math.max(Number(width), 240), 3000);
  env.height = finite(params.get("height"), 0, 0, 4000);
  env.reducedMotion = flag(params.get("reducedMotion"));
  env.highContrast = flag(params.get("highContrast"));
  const dynamicSize = params.get("dynamicSize");
  if ((DYNAMIC_SIZES as readonly string[]).includes(dynamicSize ?? "")) env.dynamicSize = dynamicSize as DynamicSize;
  if (params.get("windowKey") === "inactive") env.windowKey = "inactive";
  if (params.get("frame") === "component") env.frame = "component";
  const window = params.get("window");
  if (window && (window in WINDOW_PRESETS || /^\d{3,4}x\d{3,4}$/.test(window))) env.window = window;
  const zoom = params.get("zoom");
  if (zoom && zoom !== "fit") env.zoom = finite(zoom, 1, 0.1, 2);
  const layout = params.get("layout");
  if (layout && layout in PANE_LAYOUTS) env.layout = layout as PaneLayout;
  return env;
}

/** The query for `env`, without the defaults. */
export function writeEnv(env: GalleryEnv, params = new URLSearchParams()): URLSearchParams {
  for (const key of KEYS) {
    params.delete(key);
    const value = env[key];
    if (value === DEFAULT_ENV[key]) continue;
    params.set(key, typeof value === "boolean" ? "1" : String(value));
  }
  return params;
}

/**
 * What a stage frame renders: one variant of one entry, under the controls. `tune` is the web
 * gallery's edited tunables (experiments/tunable.ts `writeTunes`), outside the shared contract:
 * the native gallery has no tunables.
 */
export type StageAddress = { entry: string; variant: string; tune?: string };

export function frameQuery(address: StageAddress, env: GalleryEnv): string {
  const params = writeEnv(env);
  params.set("entry", address.entry);
  params.set("variant", address.variant);
  if (address.tune) params.set("tune", address.tune);
  return params.toString();
}
