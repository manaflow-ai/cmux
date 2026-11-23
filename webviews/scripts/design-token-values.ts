/**
 * The named px/ms values the webviews' stylesheets define: every top-level `:root { --name: <N>px|<N>ms }`
 * custom property, read from the sheets themselves. check-design-tokens.ts uses it to refuse a test,
 * gallery or component stylesheet that hand-types a value a token already holds (`token-copy`), and
 * tests read the same values through test/support/gridTokens.ts `designTokenValue`, so a token's number
 * lives in its sheet and nowhere else (Leo, 2026-11-15: "fewer sources of truth for individual things").
 *
 * A token's surface is where its value is the name to use: a sheet in GLOBAL_TOKEN_SHEETS reaches every
 * file; any other sheet reaches only the files under its own folder.
 * Only plain literals count (`--grid-half-step: 2px`); a token defined with calc() or var(), or defined
 * with two different plain values across :root blocks, is not a single value and is left out.
 */
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

/** Sheets whose :root tokens every surface reads (paths under src/). */
export const GLOBAL_TOKEN_SHEETS: readonly string[] = [
  "styles.css",
  "pages/shared/desktop.css",
  "pages/shared/pageBase.css",
  "agent-session/shared/styles.css",
  "ui/popupSurface.css",
  "ui/glass/glass.css",
];

/** A px or ms value, alone: `24px`, `0.5px`, `-4px`, `180ms`. */
export const PX_MS_VALUE = /^-?(?:\d+\.?\d*|\.\d+)(?:px|ms)$/;

export interface DesignToken {
  name: string;
  /** Normalised (`24px`, `0.5px`, `180ms`). */
  value: string;
  /** The defining sheet, under src/. */
  sheet: string;
  /** "" for a global token, else the area under src/ it names values for. */
  surface: string;
}

export function normalizePxMs(value: string): string | undefined {
  const text = value.trim().toLowerCase();
  if (!PX_MS_VALUE.test(text)) return undefined;
  const unit = text.endsWith("ms") ? "ms" : "px";
  return `${Number(text.slice(0, -2))}${unit}`;
}

/** The folder under src/ a sheet's local tokens name values for: the sheet's own folder. */
export function surfaceOf(rel: string): string {
  const parts = rel.replaceAll("\\", "/").split("/");
  return parts.slice(0, -1).join("/");
}

/** Whether a file at `rel` (under src/) is inside `surface` ("" is everywhere). */
export function inSurface(rel: string, surface: string): boolean {
  return !surface || rel.replaceAll("\\", "/").startsWith(`${surface}/`);
}

/** Each top-level `:root { ... }` block body of a sheet (comments removed). */
export function rootBlocks(css: string): string[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const bodies: string[] = [];
  let depth = 0;
  let start = -1;
  let prelude = "";
  let last = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "{") {
      if (depth === 0) {
        prelude = text.slice(last, i).trim();
        start = i + 1;
      }
      depth++;
    } else if (ch === "}") {
      depth--;
      if (depth === 0) {
        if (prelude === ":root") bodies.push(text.slice(start, i));
        last = i + 1;
      }
    } else if (ch === ";" && depth === 0) {
      last = i + 1;
    }
  }
  return bodies;
}

function sheets(): string[] {
  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      if (entry.isDirectory() && (entry.name === "node_modules" || entry.name === "generated")) return [];
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return walk(path);
      return entry.name.endsWith(".css") && !entry.name.includes(".gallery.") ? [path] : [];
    });
  return walk(SRC);
}

let cached: DesignToken[] | undefined;

/** Every single-valued px/ms token, from every non-gallery sheet's top-level :root blocks. */
export function designTokens(): DesignToken[] {
  if (cached) return cached;
  const byName = new Map<string, DesignToken[]>();
  for (const path of sheets()) {
    const sheet = relative(SRC, path).replaceAll("\\", "/");
    const surface = GLOBAL_TOKEN_SHEETS.includes(sheet) ? "" : surfaceOf(sheet);
    for (const body of rootBlocks(readFileSync(path, "utf8"))) {
      for (const decl of body.split(";")) {
        const colon = decl.indexOf(":");
        if (colon < 0) continue;
        const name = decl.slice(0, colon).trim();
        if (!name.startsWith("--")) continue;
        const raw = decl.slice(colon + 1).trim();
        const value = normalizePxMs(raw);
        const list = byName.get(name) ?? [];
        // A non-literal definition (calc(), var()) still counts, as a value this token can take.
        list.push({ name, value: value ?? `(${raw})`, sheet, surface });
        byName.set(name, list);
      }
    }
  }
  cached = [...byName.values()].flatMap((defs) => {
    const values = new Set(defs.map((def) => def.value));
    const surfaces = new Set(defs.map((def) => def.surface));
    if (values.size !== 1 || surfaces.size !== 1 || defs[0]!.value.startsWith("(")) return [];
    return [defs[0]!];
  });
  return cached;
}

/** A token's px/ms value (`designTokenValue("--grid-half-step")` is "2px"); throws if it is not one. */
export function designTokenValue(name: string): string {
  const token = designTokens().find((candidate) => candidate.name === name);
  if (!token) throw new Error(`${name} is not a single px/ms value in a :root block of webviews/src`);
  return token.value;
}

/**
 * What a value means, so `line-height: 18px` is never told to use the composer's 18px radius. A token's
 * family comes from its name, a property's from the property; a value matches only its own family.
 * An icon token is a `size` that also needs an icon context (an icon selector, `icon`/`glyph`/`svg`).
 */
export type TokenFamily = "radius" | "duration" | "spacing" | "size" | "stroke";

export function tokenFamily(token: Pick<DesignToken, "name" | "value">): TokenFamily | undefined {
  const name = token.name;
  if (token.value.endsWith("ms")) return "duration";
  if (/font|line-height|blur|frost|refraction/.test(name) || Number.parseFloat(token.value) >= 999) return undefined;
  if (/radius/.test(name)) return "radius";
  if (/hairline|ring-width|border/.test(name)) return "stroke";
  if (/space|gap|inset|padding|step|distance|-x$|trailing|room|tail/.test(name)) return "spacing";
  if (
    /icon|glyph|size|height|width|control|row|button|bar|header|tabs|sheet|column|subhead|min|max|thumb|stage|dot|badge|check|group|triage|pop|field/.test(
      name,
    )
  )
    return "size";
  return undefined;
}

export function isIconToken(name: string): boolean {
  return /icon|glyph|check|dot|badge/.test(name);
}

/** A component's own token (--cmux-menu-*, --surface-toast-radius) names that component's values only. */
const COMPONENT_WORD =
  /focus|menu|toast|card|sheet|group|popover|popup|chip|composer|glass|pill|finish|permission|context|find|feed|wave|ghost|reveal|spinner|activity|subhead|preview|chevron|media/;

/** Whether `context` (a selector, or the code around a test's literal) is where `name` applies. */
export function tokenApplies(name: string, context: string): boolean {
  const word = COMPONENT_WORD.exec(name)?.[0];
  return !word || context.toLowerCase().includes(word);
}

export function propertyFamily(property: string): TokenFamily | undefined {
  if (/^border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius$/.test(property)) return "radius";
  if (/^(?:transition|animation)(?:-duration|-delay)?$/.test(property)) return "duration";
  if (
    /^(?:padding|margin|inset|gap|row-gap|column-gap|scroll-padding|scroll-margin)(?:-[a-z-]+)?$|^(?:top|right|bottom|left)$/.test(
      property,
    )
  )
    return "spacing";
  if (/^(?:(?:min-|max-)?(?:width|height|block-size|inline-size)|flex-basis|size)$/.test(property)) return "size";
  if (/^(?:outline-width|border(?:-(?:top|right|bottom|left|block|inline))?-width)$/.test(property)) return "stroke";
  return undefined;
}

/**
 * The token a literal copies, if exactly one does: among global tokens and the file's own surface's,
 * in the value's family, icon tokens in an icon context and the others outside one, a component's
 * token only where `context` names the component. An ambiguous value names no token, so it is never
 * a finding; 0 is never one.
 */
export function tokenFor(
  rel: string,
  value: string,
  family: TokenFamily,
  context: string,
  iconContext: boolean,
): DesignToken | undefined {
  if (Number.parseFloat(value) === 0) return undefined;
  const matches = designTokens().filter(
    (token) =>
      token.value === value &&
      inSurface(rel, token.surface) &&
      tokenFamily(token) === family &&
      isIconToken(token.name) === iconContext &&
      tokenApplies(token.name, context),
  );
  return matches.length === 1 ? matches[0] : undefined;
}
