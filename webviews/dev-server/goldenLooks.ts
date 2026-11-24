// The golden screen's looks (src/gallery/golden/looks.json), resolved from the files they name: theme
// files (JSON with comments), setup folders (examples/looks/NAME and any folder in
// CMUX_GOLDEN_SETUPS, comma separated) and agent-pane/theme.css. Served to the gallery as
// virtual:cmux-gallery/looks (galleryHost.ts); `bun run golden:looks --setup DIR` passes
// CMUX_GOLDEN_SETUPS so an outside look (a look's own repo) draws beside the built-in ones.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { GoldenLook, GoldenScheme } from "../src/gallery/golden/look";

const webviewsRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
export const REPO_ROOT = path.join(webviewsRoot, "..");
export const GOLDEN_LOOKS_FILE = path.join(webviewsRoot, "src/gallery/golden/looks.json");

type ThemeFile = Record<string, unknown>;
type RegistryScheme = { themeFile?: string; theme?: ThemeFile };
type RegistryLook = {
  id: string;
  title: string;
  note?: string;
  composerLook?: "claude" | "codex";
  settings?: Record<string, unknown>;
  themeCSS?: string;
  setup?: string;
  schemes?: { light?: RegistryScheme; dark?: RegistryScheme };
};

/** JSON with `//` and `/* *\/` comments and trailing commas (theme files, setups), outside strings. */
export function parseJsonc(text: string): unknown {
  let out = "";
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i]!;
    if (c === '"') {
      const start = i;
      for (i += 1; i < text.length && text[i] !== '"'; i += text[i] === "\\" ? 2 : 1);
      out += text.slice(start, i + 1);
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i += 1;
      out += "\n";
    } else if (c === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2);
      if (i < 0) break;
      i += 1;
    } else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

const HEX = /^#[0-9a-fA-F]{6}$/;
const hex = (value: unknown) => (typeof value === "string" && HEX.test(value) ? value.toLowerCase() : undefined);

/** A theme file's keys, as the golden draws them (src/gallery/golden/look.ts applies them). */
export function schemeFromThemeFile(file: ThemeFile, source: string): GoldenScheme {
  const colors = (file.colors ?? {}) as Record<string, unknown>;
  const scheme: GoldenScheme = { source };
  if (typeof file.name === "string") scheme.name = file.name;
  if (typeof file["appearance.theme"] === "string") scheme.theme = file["appearance.theme"];
  const picked = {
    background: hex(colors.background),
    foreground: hex(colors.foreground),
    selection: hex(colors.selection),
    accent: hex(colors.accent),
  };
  const set = Object.fromEntries(Object.entries(picked).filter(([, value]) => value)) as GoldenScheme["colors"];
  if (set && Object.keys(set).length) scheme.colors = set;
  if (typeof file["appearance.accent"] === "string") scheme.accent = file["appearance.accent"];
  if (file["appearance.selection"] === "accent" || file["appearance.selection"] === "neutral")
    scheme.selection = file["appearance.selection"];
  const sidebar = hex(file["appearance.surfaces.sidebar.color"]);
  const agentPane = hex(file["appearance.surfaces.agentPane.color"]);
  if (sidebar || agentPane) scheme.surfaces = { ...(sidebar && { sidebar }), ...(agentPane && { agentPane }) };
  if (file["appearance.density"] === "compact" || file["appearance.density"] === "comfortable")
    scheme.density = file["appearance.density"];
  return scheme;
}

const luminance = (color: string) => {
  const value = parseInt(color.slice(1), 16);
  const f = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return (
    0.2126 * f(((value >> 16) & 0xff) / 255) +
    0.7152 * f(((value >> 8) & 0xff) / 255) +
    0.0722 * f((value & 0xff) / 255)
  );
};

/** Whether a theme file draws dark: its background darker than its text; else its terminal theme's name. */
export function themeFileIsDark(file: ThemeFile): boolean {
  const colors = (file.colors ?? {}) as Record<string, unknown>;
  const bg = hex(colors.background);
  const fg = hex(colors.foreground);
  if (bg && fg) return luminance(bg) < luminance(fg);
  return !/light/i.test(String(file["appearance.theme"] ?? ""));
}

const readText = (file: string) => fs.readFileSync(file, "utf8");
const repoPath = (relative: string) => (path.isAbsolute(relative) ? relative : path.join(REPO_ROOT, relative));
const shown = (file: string) => {
  const relative = path.relative(REPO_ROOT, file);
  return relative.startsWith("..") ? path.basename(file) : relative;
};

/** A setup folder (cmux-setup.json, themes/, agent-pane/theme.css) as a look. */
export function lookFromSetup(dir: string, base: Partial<RegistryLook> = {}): GoldenLook {
  const setupFile = path.join(dir, "cmux-setup.json");
  const setup = parseJsonc(readText(setupFile)) as {
    id?: string;
    name?: string;
    tagline?: string;
    settings?: Record<string, unknown>;
  };
  const settings = { ...setup.settings };
  const schemes: GoldenLook["schemes"] = { light: {}, dark: {} };
  const themeName = settings["appearance.themeFile"];
  if (typeof themeName === "string") {
    const themeFile = path.join(dir, "themes", `${themeName}.json`);
    if (fs.existsSync(themeFile)) {
      const file = parseJsonc(readText(themeFile)) as ThemeFile;
      schemes[themeFileIsDark(file) ? "dark" : "light"] = schemeFromThemeFile(file, shown(themeFile));
    }
  }
  // A look's other themes (a light twin of a dark one): the first of the other scheme.
  const themesDir = path.join(dir, "themes");
  const otherScheme = schemes.dark.source ? "light" : schemes.light.source ? "dark" : undefined;
  if (otherScheme && fs.existsSync(themesDir))
    for (const name of fs.readdirSync(themesDir).sort()) {
      if (!name.endsWith(".json")) continue;
      const file = parseJsonc(readText(path.join(themesDir, name))) as ThemeFile;
      if (themeFileIsDark(file) === (otherScheme === "dark")) {
        schemes[otherScheme] = schemeFromThemeFile(file, shown(path.join(themesDir, name)));
        break;
      }
    }
  const css = path.join(dir, "agent-pane/theme.css");
  delete settings["appearance.themeFile"];
  return {
    id: base.id ?? path.basename(dir),
    title: base.title ?? setup.name ?? path.basename(dir),
    note: base.note ?? setup.tagline ?? "",
    source: shown(dir),
    settings,
    schemes,
    ...(fs.existsSync(css) ? { themeCSS: readText(css) } : {}),
    ...(base.composerLook ? { composerLook: base.composerLook } : {}),
  };
}

function resolveScheme(scheme: RegistryScheme | undefined): GoldenScheme {
  if (!scheme) return {};
  if (scheme.themeFile) {
    const file = repoPath(scheme.themeFile);
    return schemeFromThemeFile(parseJsonc(readText(file)) as ThemeFile, scheme.themeFile);
  }
  if (scheme.theme) return schemeFromThemeFile(scheme.theme, "looks.json");
  return {};
}

/** Why a registry look cannot draw in this checkout (a file it names is missing), or null. */
function missing(look: RegistryLook): string | null {
  const paths = [
    look.setup && path.join(look.setup, "cmux-setup.json"),
    look.themeCSS,
    look.schemes?.light?.themeFile,
    look.schemes?.dark?.themeFile,
  ].filter((value): value is string => Boolean(value));
  const absent = paths.find((relative) => !fs.existsSync(repoPath(relative)));
  return absent ? `${absent} is not in this checkout` : null;
}

export type GoldenLooks = { looks: GoldenLook[]; skipped: { id: string; reason: string }[] };

/** Every look of the registry this checkout can draw, then each setup folder in `extraSetups`. */
export function readGoldenLooks(
  extraSetups = (process.env.CMUX_GOLDEN_SETUPS ?? "").split(",").filter(Boolean),
  registryFile = GOLDEN_LOOKS_FILE,
): GoldenLooks {
  const registry = JSON.parse(readText(registryFile)) as { looks: RegistryLook[] };
  const looks: GoldenLook[] = [];
  const skipped: GoldenLooks["skipped"] = [];
  for (const look of registry.looks) {
    const reason = missing(look);
    if (reason) {
      skipped.push({ id: look.id, reason });
      continue;
    }
    if (look.setup) {
      looks.push(lookFromSetup(repoPath(look.setup), look));
      continue;
    }
    looks.push({
      id: look.id,
      title: look.title,
      note: look.note ?? "",
      source: "looks.json",
      settings: look.settings ?? {},
      schemes: { light: resolveScheme(look.schemes?.light), dark: resolveScheme(look.schemes?.dark) },
      ...(look.themeCSS ? { themeCSS: readText(repoPath(look.themeCSS)) } : {}),
      ...(look.composerLook ? { composerLook: look.composerLook } : {}),
    });
  }
  const ids = new Set(looks.map((look) => look.id));
  for (const dir of extraSetups) {
    const look = lookFromSetup(path.resolve(dir));
    // An outside folder named like a registry look keeps both: `<name>-setup`.
    if (ids.has(look.id)) look.id = `${look.id}-setup`;
    ids.add(look.id);
    looks.push(look);
  }
  return { looks, skipped };
}
