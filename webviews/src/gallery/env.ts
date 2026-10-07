// The gallery's controls: one value set, kept in the URL query, so a link reproduces a view.
// The shell keeps it in its own URL and passes the same query to every stage frame; the matrix
// runner builds frame URLs from it. Defaults are left out of the query, so links stay short.
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME } from "./theme/ghostty";

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
  scheme: "dark" | "light";
  /** The Ghostty theme for each scheme, as `theme = light:A,dark:B` names them. */
  dark: string;
  light: string;
  /** Empty: the page's own font. */
  font: string;
  /** Px; 0 is the page's own size. */
  size: number;
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
};

export const DEFAULT_ENV: GalleryEnv = {
  locale: "en",
  scheme: "dark",
  dark: DEFAULT_DARK_THEME,
  light: DEFAULT_LIGHT_THEME,
  font: "",
  size: 0,
  density: "comfortable",
  scale: 1,
  width: "normal",
  height: 0,
  reducedMotion: false,
  highContrast: false,
  dynamicSize: "default",
  windowKey: "key",
};

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
  if (params.get("scheme") === "light") env.scheme = "light";
  env.dark = params.get("dark") || env.dark;
  env.light = params.get("light") || env.light;
  env.font = (params.get("font") ?? "").slice(0, 200);
  env.size = finite(params.get("size"), 0, 0, 40);
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

/** The Ghostty theme the scheme shows. */
export const activeTheme = (env: GalleryEnv) => (env.scheme === "dark" ? env.dark : env.light);

/** What a stage frame renders: one variant of one entry, under the controls. */
export type StageAddress = { entry: string; variant: string };

export function frameQuery(address: StageAddress, env: GalleryEnv): string {
  const params = writeEnv(env);
  params.set("entry", address.entry);
  params.set("variant", address.variant);
  return params.toString();
}
