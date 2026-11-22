#!/usr/bin/env bun
// Writes the screenshot matrix manifest (scripts/gallery-matrix/manifest.schema.json) from the
// gallery registry: every entry x variant x locale x theme x width, or the subset the flags name.
// Each case opens frame.html with the gallery's URL contract (env.ts) as its params, so the
// runner's URL is exactly the stage the gallery shows.
//
//   bun scripts/gallery/manifest.ts --out manifest.json                      # entries x variants, en, default theme
//   bun scripts/gallery/manifest.ts --locales all --themes sample --out m.json
//   bun scripts/gallery/manifest.ts --entries agent-pane --variants streaming,math --widths narrow,wide
//
// --entries / --variants  comma-separated ids or id prefixes (default: all)
// --locales  en (default), shipped (21), all (21 + 2 pseudo), or a list
// --themes   default (Apple System Colors), pair (+ its Light), sample (12), all (every shipped), or a list
// --frame    window (default: the surface at its real pane size in a real-size cmux window; the
//            viewport is that pane, nothing native is drawn)
//            or component (the entry alone at a pane width)
// --windows  window sizes for window mode: 16x9 (default), all, or presets / <w>x<h>
// --layouts  pane layouts for window mode: one (default), all, or one|two|agent-right
// --widths   pane widths for component mode: normal (default), all, or narrow|normal|wide|<px>
// --limit    at most N cases (after the order above)
// --experiments  instead of the matrix above: for each entry with an experiment, one measured case
//            per arm (`measure=1`: the script at 1x, frame timings in the results) and a frame strip
//            per arm and step (`freeze=<step>:<ms>` at STRIP_TIMES_MS). Theme, locale and width as above.
import fs from "node:fs";
import { parseArgs } from "node:util";
import { readChromeMetrics, readShippedThemes } from "../../dev-server/galleryHost";
import { LOCALES, PSEUDO_LOCALES, WIDTHS, widthPx, type WidthName } from "../../src/gallery/env";
import { stageHeight, type GalleryEntry } from "../../src/gallery/format";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME, themeIsDark } from "../../src/gallery/theme/ghostty";
import { entryPaneSize, PANE_LAYOUTS, WINDOW_PRESETS } from "../../src/gallery/window";
import { loadEntries } from "./entries";

export const SAMPLE_THEMES = [
  "Apple System Colors",
  "Apple System Colors Light",
  "Dracula",
  "Nord",
  "Solarized Dark Higher Contrast",
  "Catppuccin Latte",
  "Gruvbox Dark",
  "Tokyo Night",
  "One Half Light",
  "Monokai Classic",
  "GitHub Light Default",
  "Rose Pine Dawn",
];

export type ManifestCase = { id: string; path_or_url: string; params: Record<string, string | number | boolean> };
/** Times after a step's input that a frame strip shows, in ms. */
export const STRIP_TIMES_MS = [0, 40, 80, 120, 160, 200, 260];

export type ManifestOptions = {
  entries?: string[];
  variants?: string[];
  locales?: string;
  themes?: string;
  widths?: string;
  frame?: "window" | "component";
  windows?: string;
  layouts?: string;
  limit?: number;
  experiments?: boolean;
};

const list = (value: string | undefined) =>
  value
    ? value
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean)
    : [];
const matches = (id: string, wanted: string[]) =>
  wanted.length === 0 || wanted.some((prefix) => id === prefix || id.startsWith(`${prefix}.`) || id.startsWith(prefix));

export function manifestCases(entries: GalleryEntry[], options: ManifestOptions = {}): ManifestCase[] {
  const shipped = readShippedThemes();
  const byName = new Map(shipped.map((theme) => [theme.name, theme]));
  const locales =
    options.locales === "all"
      ? [...LOCALES, ...PSEUDO_LOCALES]
      : options.locales === "shipped"
        ? [...LOCALES]
        : list(options.locales ?? "en");
  const themes =
    options.themes === "all"
      ? shipped.map((theme) => theme.name)
      : options.themes === "sample"
        ? SAMPLE_THEMES.filter((name) => byName.has(name))
        : options.themes === "pair"
          ? [DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME]
          : options.themes && options.themes !== "default"
            ? list(options.themes)
            : [DEFAULT_DARK_THEME];
  for (const name of themes)
    if (!byName.has(name)) throw new Error(`no shipped Ghostty theme named ${JSON.stringify(name)}`);
  const widths: (WidthName | number)[] =
    options.widths === "all"
      ? ["narrow", "normal", "wide"]
      : list(options.widths ?? "normal").map((width) => (/^\d+$/.test(width) ? Number(width) : (width as WidthName)));
  const frame = options.frame ?? "window";
  const windows = options.windows === "all" ? Object.keys(WINDOW_PRESETS) : list(options.windows ?? "16x9");
  const layouts = options.layouts === "all" ? Object.keys(PANE_LAYOUTS) : list(options.layouts ?? "one");
  // Window mode varies the window and the panes; component mode varies the pane width.
  const shapes =
    frame === "window"
      ? windows.flatMap((window) => layouts.map((layout) => ({ window, layout })))
      : widths.map((width) => ({ width }));
  const cases: ManifestCase[] = [];
  for (const entry of entries.filter((candidate) => matches(candidate.id, options.entries ?? []))) {
    if (entry.host === "native") continue;
    const presets = entry.widths ?? WIDTHS;
    for (const variant of Object.keys(entry.variants).filter((name) =>
      options.variants?.length ? options.variants.includes(name) : true,
    ))
      for (const locale of locales)
        for (const theme of themes)
          for (const shape of shapes) {
            const colorScheme = themeIsDark(byName.get(theme)!) ? "dark" : "light";
            const base = { entry: entry.id, variant, locale, theme, colorScheme };
            if ("window" in shape) {
              // The viewport is the surface's real pane size in that window (nothing native drawn).
              const size = entryPaneSize(shape.window, shape.layout as never, "comfortable", readChromeMetrics());
              const id = [entry.id, variant, locale, theme, shape.window, shape.layout]
                .join("--")
                .replace(/[^A-Za-z0-9._-]+/g, "_");
              cases.push({
                id,
                path_or_url: "frame.html",
                params: {
                  ...base,
                  frame: "window",
                  window: shape.window,
                  layout: shape.layout,
                  width: size.width,
                  height: size.height,
                },
              });
            } else {
              const px = widthPx(shape.width, presets);
              const id = [entry.id, variant, locale, theme, `w${px}`].join("--").replace(/[^A-Za-z0-9._-]+/g, "_");
              cases.push({
                id,
                path_or_url: "frame.html",
                params: { ...base, frame: "component", width: px, height: stageHeight(entry, variant) },
              });
            }
          }
  }
  return options.limit ? cases.slice(0, options.limit) : cases;
}

/** The experiment cases (`--experiments`): per arm, one measured run of the script and its strips. */
export function experimentCases(entries: GalleryEntry[], options: ManifestOptions = {}): ManifestCase[] {
  const base = manifestCases(entries, { ...options, frame: "component", limit: undefined });
  const cases: ManifestCase[] = [];
  for (const item of base) {
    const entry = entries.find((candidate) => candidate.id === item.params.entry);
    const experiment = entry?.experiment;
    if (!experiment) continue;
    for (const arm of Object.keys(experiment.definition.arms)) {
      const params = { ...item.params, exp: experiment.definition.id, arm };
      cases.push({ id: `${item.id}--${arm}--measure`, path_or_url: "frame.html", params: { ...params, measure: "1" } });
      experiment.script.forEach((_, index) => {
        for (const ms of STRIP_TIMES_MS)
          cases.push({
            id: `${item.id}--${arm}--s${index + 1}-t${ms}`,
            path_or_url: "frame.html",
            params: { ...params, freeze: `${index + 1}:${ms}` },
          });
      });
    }
  }
  return options.limit ? cases.slice(0, options.limit) : cases;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      entries: { type: "string" },
      variants: { type: "string" },
      locales: { type: "string" },
      themes: { type: "string" },
      widths: { type: "string" },
      frame: { type: "string" },
      windows: { type: "string" },
      layouts: { type: "string" },
      limit: { type: "string" },
      experiments: { type: "boolean", default: false },
      out: { type: "string" },
    },
  });
  const build = values.experiments ? experimentCases : manifestCases;
  const cases = build(await loadEntries(), {
    entries: list(values.entries),
    variants: list(values.variants),
    locales: values.locales,
    themes: values.themes,
    widths: values.widths,
    frame: values.frame === "component" ? "component" : "window",
    windows: values.windows,
    layouts: values.layouts,
    limit: values.limit ? Number(values.limit) : undefined,
  });
  const json = `${JSON.stringify(cases, null, 2)}\n`;
  if (values.out) fs.writeFileSync(values.out, json);
  else process.stdout.write(json);
  console.error(`gallery manifest: ${cases.length} cases`);
}
