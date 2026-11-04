// Text on a filled control reads in every theme (Leo, 2026-11-03, on the next-step card's Yes: "that
// "YES" was styled bad it was white font on white button :( we need to watch out for those"). The
// card's primary answer took its ink from `--agent-page-bg`, the page background, which is clear
// in a see-through window: the ink became the fill and the label vanished.
//
// Two checks over the shipped page stylesheets:
// - ink is never a see-through backdrop token (the page or surface background, the input field's
//   tint): those are clear or translucent over a wallpaper, so text in them takes the fill's tone;
// - every filled control (a button, action, chip, badge or check that sets both a fill and an ink)
//   in the agent pane and the empty viewer is resolved against the theme the app sends
//   (gallery/theme/web.ts, the same derivation as AgentPaneTheme.swift) for dark and light themes,
//   a light accent, and opaque and see-through windows, and its ink must reach 3:1 on its fill
//   (WCAG's minimum for controls). A fill under half opacity is a wash, not a fill, and is skipped.
// An exception goes in button-ink-contrast.allow.json, `file selector` with its reason.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import allowFile from "./button-ink-contrast.allow.json";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import { agentPaneTheme, themeTokens, webThemePayload } from "../src/gallery/theme/web";
import type { AppAccent } from "../src/theme/appTheme";

const SRC = path.resolve(import.meta.dir, "../src");
const MINIMUM = 3;
const { "//": _note, ...ALLOW } = allowFile as Record<string, string>;

function files(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return files(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/** Page stylesheets: gallery fixtures and prototypes never ship. */
const pageCSS = files(SRC).filter((file) => !/\/(gallery|prototypes?)\//.test(file) && !file.endsWith(".gallery.css"));

type Rule = { file: string; selector: string; decls: Map<string, string> };

/** The rules with their declarations, comments removed; nested at-rule bodies are read as rules. */
function rules(file: string): Rule[] {
  const css = fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const out: Rule[] = [];
  for (const [, selector = "", body = ""] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const decls = new Map<string, string>();
    for (const part of body.split(";")) {
      const colon = part.indexOf(":");
      if (colon < 0) continue;
      decls.set(
        part.slice(0, colon).trim().toLowerCase(),
        part
          .slice(colon + 1)
          .replace(/!important/, "")
          .trim(),
      );
    }
    // A statement before the rule (`@import ...;`) is not part of its selector.
    const name = selector.split(";").pop()!.trim().replace(/\s+/g, " ");
    if (!name || name.startsWith("@")) continue;
    out.push({ file: path.relative(SRC, file), selector: name, decls });
  }
  return out;
}

const allRules = pageCSS.flatMap(rules);

/** The tokens that are clear or translucent over a see-through window. */
const BACKDROP = [
  "--agent-page-bg",
  "--agent-surface",
  "--agent-surface-elevated",
  "--agent-input-bg",
  "--agent-control",
  "--cmux-surface-background",
  "--cmux-surface-token",
  "--cmux-reading-background",
];

/** The bundles whose custom properties resolve from their own sheets: each pages/<name> page builds
 *  on its own base sheet, which this resolver does not order, so pages are left to the ink check. */
const RESOLVED = ["agent-session/", "viewer-empty/"];
/** A filled control: a button, an action, a pill or chip, a badge or check, a pressed tab. */
const CONTROL = /button|action|primary|submit|answer|chip|pill|badge|check|toggle|tab\b|\[aria-pressed|\[data-primary/i;
const isControl = (rule: Rule) =>
  RESOLVED.some((prefix) => rule.file.startsWith(prefix)) && CONTROL.test(rule.selector);

const firstVar = (value: string) => value.match(/^var\(\s*(--[\w-]+)/)?.[1];

describe("text on a fill reads", () => {
  test("ink is never a see-through backdrop token", () => {
    const found = allRules
      .filter((rule) => {
        const ink = rule.decls.get("color");
        return ink !== undefined && BACKDROP.includes(firstVar(ink) ?? "");
      })
      .map((rule) => `${rule.file} ${rule.selector}`)
      .filter((key) => !(key in ALLOW));
    expect(found).toEqual([]);
  });

  test("a filled control's ink reaches 3:1 on its fill in dark, light, light-accent and see-through themes", () => {
    const failures = new Map<string, string>();
    for (const scheme of SCHEMES) {
      const base = scheme.base;
      const bundles = new Map<string, Map<string, string>>();
      for (const rule of allRules.filter(isControl)) {
        let vars = bundles.get(bundle(rule.file));
        if (!vars) bundles.set(bundle(rule.file), (vars = variables(scheme, rule.file)));
        const fillText = rule.decls.get("background-color") ?? rule.decls.get("background");
        const inkText = rule.decls.get("color");
        if (!fillText || !inkText) continue;
        const key = `${rule.file} ${rule.selector}`;
        if (key in ALLOW || failures.has(key)) continue;
        const scope = new Map(vars);
        for (const [name, value] of rule.decls) if (name.startsWith("--")) scope.set(name, value);
        const fill = resolve(fillText, scope, scheme.dark);
        const ink = resolve(inkText, scope, scheme.dark);
        if (!fill || !ink) continue;
        // A faint wash (a hover tint) is not a fill; its text is checked as page text elsewhere.
        if (fill.a < 0.5) continue;
        const shown = over(fill, base);
        const ratio = contrast(over(ink, shown), shown);
        if (ratio < MINIMUM)
          failures.set(key, `${key}: ${ratio.toFixed(2)}:1 in ${scheme.name} (ink ${hex(ink)} on ${hex(shown)})`);
      }
    }
    expect([...failures.values()]).toEqual([]);
  });

  test("the allow list names only rules that exist", () => {
    const keys = new Set(allRules.map((rule) => `${rule.file} ${rule.selector}`));
    expect(Object.keys(ALLOW).filter((key) => !keys.has(key))).toEqual([]);
  });
});

// Themes: a dark and a light one with their palettes (so an accent has a hue), each with the
// neutral accent (the text colour), the theme's own accent and a light named accent, in an opaque
// and a see-through window (the page background clear, as over a wallpaper).
const MOCHA = `background = #1e1e2e
foreground = #cdd6f4
${["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de", "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"].map((hex, index) => `palette = ${index}=${hex}`).join("\n")}
`;
const DAWN = `background = #faf4ed
foreground = #575279
${["#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279", "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279"].map((hex, index) => `palette = ${index}=${hex}`).join("\n")}
`;

type Scheme = { name: string; dark: boolean; base: RGBA; agent: Record<string, unknown>; web: Record<string, string> };

const SCHEMES: Scheme[] = [
  ["Catppuccin Mocha", MOCHA],
  ["Rose Pine Dawn", DAWN],
].flatMap(([name, text]) => {
  const theme = parseGhosttyTheme(name!, text!)!;
  return (["neutral", "theme", "yellow", "cyan"] as AppAccent[]).flatMap((accent) =>
    [false, true].map((seeThrough) => {
      const tokens = themeTokens(theme, accent);
      const agent = agentPaneTheme(tokens, false, seeThrough);
      return {
        name: `${name} ${accent}${seeThrough ? " see-through" : ""}`,
        dark: tokens.isDark,
        // A see-through window shows its tint over the picture; the opaque page stands for it.
        base: parse(String(agent.accentText))!,
        agent,
        web: webThemePayload(tokens, undefined, seeThrough).variables,
      };
    }),
  );
});

/** AgentSessionTheme keys to the page's variables (shared/theme.ts). */
const AGENT_VARS: Record<string, string> = {
  pageBackground: "--agent-page-bg",
  surfaceBackground: "--agent-surface",
  surfaceElevatedBackground: "--agent-surface-elevated",
  inputBackground: "--agent-input-bg",
  border: "--agent-border",
  borderStrong: "--agent-border-strong",
  text: "--agent-text",
  mutedText: "--agent-muted",
  softText: "--agent-soft",
  accent: "--agent-accent",
  accentSoft: "--agent-accent-soft",
  litGlyph: "--agent-lit-glyph",
  accentText: "--agent-accent-text",
  onAccent: "--agent-on-accent",
  danger: "--agent-danger",
  warning: "--agent-warning",
  success: "--agent-success",
  highlight: "--agent-highlight",
  highlightText: "--agent-highlight-text",
  shadow: "--agent-shadow",
};

/** Each page bundle is its top folder under src (agent-session, pages, viewer-empty); loose files
 *  at the top are the web pages' own sheet. A rule reads only its bundle's custom properties. */
const bundle = (file: string) => (file.includes("/") ? file.slice(0, file.indexOf("/")) : "");
/** The sheets that declare a bundle's base properties, read first (build-agent-pane-web.sh order). */
const BASE_SHEETS = ["agent-session/shared/styles.css", "agent-session/acpmux/styles.css"];

/** Custom properties a bundle's stylesheets declare (its base sheets first, then the first
 *  declaration wins), under the theme's own. */
const declared = (() => {
  const byBundle = new Map<string, Map<string, string>>();
  const ordered = [...allRules].sort((a, b) => rank(a.file) - rank(b.file));
  for (const rule of ordered) {
    const map = byBundle.get(bundle(rule.file)) ?? new Map<string, string>();
    byBundle.set(bundle(rule.file), map);
    for (const [name, value] of rule.decls) if (name.startsWith("--") && !map.has(name)) map.set(name, value);
  }
  return byBundle;
})();

function rank(file: string): number {
  const index = BASE_SHEETS.indexOf(file);
  return index < 0 ? BASE_SHEETS.length : index;
}

function variables(scheme: Scheme, file: string): Map<string, string> {
  const out = new Map(declared.get(bundle(file)));
  for (const [name, value] of Object.entries(scheme.web)) out.set(name, value);
  for (const [key, name] of Object.entries(AGENT_VARS)) {
    const value = scheme.agent[key];
    if (typeof value === "string") out.set(name, value);
  }
  const palette = scheme.agent.palette;
  if (Array.isArray(palette)) palette.forEach((color, index) => out.set(`--agent-ansi-${index}`, String(color)));
  return out;
}

// A small CSS color evaluator: hex, rgb()/rgba(), transparent, Canvas, light-dark(), var() with
// fallbacks and color-mix() (mixed in sRGB with premultiplied alpha, close enough for a 3:1 floor).
// Anything else (currentColor, gradients, images) is not a single colour and skips the rule.
type RGBA = { r: number; g: number; b: number; a: number };

/** `text` split on its top-level commas. */
function args(text: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === "(") depth++;
    else if (char === ")") depth--;
    else if (char === "," && depth === 0) {
      out.push(text.slice(start, index).trim());
      start = index + 1;
    }
  }
  out.push(text.slice(start).trim());
  return out;
}

/** `name(inner)` when `text` is exactly one call of `name`. */
function call(text: string, name: string): string | undefined {
  if (!text.toLowerCase().startsWith(`${name}(`) || !text.endsWith(")")) return undefined;
  let depth = 0;
  for (let index = name.length; index < text.length; index++) {
    if (text[index] === "(") depth++;
    else if (text[index] === ")" && --depth === 0)
      return index === text.length - 1 ? text.slice(name.length + 1, -1) : undefined;
  }
  return undefined;
}

function parse(text: string): RGBA | undefined {
  const hex = text.match(/^#([0-9a-f]{3,8})$/i)?.[1];
  if (hex) {
    const full = hex.length <= 4 ? hex.replace(/./g, (c) => c + c) : hex;
    if (full.length !== 6 && full.length !== 8) return undefined;
    const value = (offset: number) => parseInt(full.slice(offset, offset + 2), 16) / 255;
    return { r: value(0), g: value(2), b: value(4), a: full.length === 8 ? value(6) : 1 };
  }
  const rgb = text.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/i);
  if (rgb) {
    const alpha = rgb[4] === undefined ? 1 : rgb[4].endsWith("%") ? parseFloat(rgb[4]) / 100 : parseFloat(rgb[4]);
    return { r: +rgb[1]! / 255, g: +rgb[2]! / 255, b: +rgb[3]! / 255, a: alpha };
  }
  if (/^transparent$/i.test(text)) return { r: 0, g: 0, b: 0, a: 0 };
  if (/^white$/i.test(text)) return { r: 1, g: 1, b: 1, a: 1 };
  if (/^black$/i.test(text)) return { r: 0, g: 0, b: 0, a: 1 };
  return undefined;
}

function resolve(text: string, vars: Map<string, string>, dark: boolean, depth = 0): RGBA | undefined {
  if (depth > 24) return undefined;
  const value = text.trim();
  const own = parse(value);
  if (own) return own;
  if (/^canvas$/i.test(value)) return dark ? { r: 0.07, g: 0.07, b: 0.07, a: 1 } : { r: 1, g: 1, b: 1, a: 1 };
  const reference = call(value, "var");
  if (reference !== undefined) {
    const [name = "", ...rest] = args(reference);
    const set = vars.get(name);
    if (set !== undefined) return resolve(set, vars, dark, depth + 1);
    return rest.length ? resolve(rest.join(","), vars, dark, depth + 1) : undefined;
  }
  const pair = call(value, "light-dark");
  if (pair !== undefined) {
    const [light = "", darkValue = ""] = args(pair);
    return resolve(dark ? darkValue : light, vars, dark, depth + 1);
  }
  const mix = call(value, "color-mix");
  if (mix !== undefined) {
    const [, first = "", second = ""] = args(mix);
    const part = (text: string) => {
      const match = text.match(/^(.*?)(?:\s+([\d.]+)%)?$/s)!;
      return {
        color: resolve(match[1]!, vars, dark, depth + 1),
        weight: match[2] === undefined ? undefined : +match[2] / 100,
      };
    };
    const a = part(first);
    const b = part(second);
    if (!a.color || !b.color) return undefined;
    let p = a.weight ?? (b.weight === undefined ? 0.5 : 1 - b.weight);
    let q = b.weight ?? 1 - p;
    const sum = p + q;
    const scale = sum < 1 ? sum : 1;
    p /= sum;
    q /= sum;
    const alpha = a.color.a * p + b.color.a * q;
    if (alpha === 0) return { r: 0, g: 0, b: 0, a: 0 };
    const channel = (key: "r" | "g" | "b") => (a.color![key] * a.color!.a * p + b.color![key] * b.color!.a * q) / alpha;
    return { r: channel("r"), g: channel("g"), b: channel("b"), a: alpha * scale };
  }
  return undefined;
}

function hex(color: RGBA): string {
  const byte = (value: number) =>
    Math.round(value * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${byte(color.r)}${byte(color.g)}${byte(color.b)}${color.a < 1 ? byte(color.a) : ""}`;
}

function over(top: RGBA, under: RGBA): RGBA {
  const mix = (x: number, y: number) => x * top.a + y * (1 - top.a);
  return { r: mix(top.r, under.r), g: mix(top.g, under.g), b: mix(top.b, under.b), a: 1 };
}

function luminance(color: RGBA): number {
  const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
}

function contrast(a: RGBA, b: RGBA): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi! + 0.05) / (lo! + 0.05);
}
