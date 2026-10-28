// Portable value checks per row kind. The daemon is the authority; the mock provider uses
// these to behave like it, and the page uses them to refuse a bad field value before sending.
import { parseThemeSpec } from "./themeSpec";
import type { Domains } from "./ops";
import type { SchemaRow } from "./schema";

const hexColor = /^#?[0-9a-f]{6}([0-9a-f]{2})?$/i;
const time = /^([01]\d|2[0-3]):[0-5]\d$/;
const host = /^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?$/i;

export function isHexColor(value: unknown): value is string {
  return typeof value === "string" && hexColor.test(value);
}

export function isHost(value: unknown): value is string {
  return typeof value === "string" && host.test(value);
}

export function isTime(value: unknown): value is string {
  return typeof value === "string" && time.test(value);
}

/** The `browser.newTabPage` rules: empty, http(s), about:, file:, or a bare host with a dot. */
export function isPageURL(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const text = value.trim();
  if (text === "") return true;
  if (/\s/.test(text)) return false;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(text)?.[1]?.toLowerCase();
  if (scheme === "about" || scheme === "file") return true;
  if (scheme === "http" || scheme === "https") return hostOf(text) !== null;
  if (scheme !== undefined && !/^[^/]*:\d+/.test(text)) return false;
  const bare = hostOf(`https://${text}`);
  return bare !== null && bare.includes(".");
}

/**
 * An http or https address with a host and nothing else: no user info, no path other than "/",
 * no query, no fragment (Swift `SettingDescriptor.httpOrigin`, cmux-config `is_http_origin`).
 */
export function isHttpOrigin(value: unknown): value is string {
  if (typeof value !== "string" || /[\s?#@]/.test(value) || !/^https?:\/\//i.test(value)) return false;
  try {
    const url = new URL(value);
    return url.hostname !== "" && url.pathname === "/";
  } catch {
    return false;
  }
}

function hostOf(url: string): string | null {
  try {
    const host = new URL(url).hostname;
    return host === "" ? null : host;
  } catch {
    return null;
  }
}

function inRange(row: SchemaRow, value: unknown): boolean {
  const range = row.range;
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    (range === undefined || (value >= range.min && value <= range.max))
  );
}

function inDomain(list: string[] | undefined, value: unknown): boolean {
  if (typeof value !== "string" || value.trim() === "") return false;
  // With no published domain (headless host) any non-empty name passes.
  return !list || list.length === 0 || list.includes(value);
}

/** A theme name, or `light:<theme>,dark:<theme>` with each side a name (AppThemeSetting's ThemeSpec). */
function themeInDomain(list: string[] | undefined, value: unknown): boolean {
  const spec = parseThemeSpec(value);
  if (!spec) return false;
  return spec.kind === "single" ? inDomain(list, spec.name) : inDomain(list, spec.light) && inDomain(list, spec.dark);
}

/**
 * A custom search engine address (`browser.customSearchEngine.*`): empty, or a page address that
 * marks where the typed text goes with %s or {searchTerms}. The Swift rule is
 * `BrowserOmnibarSetting.isSearchTemplate`.
 */
export function isSearchTemplate(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const text = value.trim();
  if (text === "") return true;
  if (!text.includes("%s") && !text.includes("{searchTerms}")) return false;
  return isPageURL(text.replaceAll("%s", "x").replaceAll("{searchTerms}", "x"));
}

/**
 * One custom density (`appearance.customDensities`): a lowercase id, a name, and optional numbers.
 * The Swift rule is `CustomDensitiesSetting.density(from:)`.
 */
export function isCustomDensity(value: unknown): boolean {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const entry = value as Record<string, unknown>;
  const id = entry.id;
  if (typeof id !== "string" || id.length < 1 || id.length > 64 || id.startsWith("-") || !/^[a-z0-9-]+$/.test(id))
    return false;
  if (typeof entry.name !== "string" || entry.name.trim() === "") return false;
  for (const key of ["level", "spacing", "fontSize"]) {
    const number = entry[key];
    if (number !== undefined && (typeof number !== "number" || !Number.isFinite(number))) return false;
  }
  const tokens = entry.tokens;
  if (tokens === undefined) return true;
  if (typeof tokens !== "object" || tokens === null || Array.isArray(tokens)) return false;
  return Object.values(tokens).every((token) => typeof token === "number" && Number.isFinite(token) && token >= 0);
}

/** Returns null when `value` is valid for `row`, otherwise a short English reason. */
export function validate(row: SchemaRow, value: unknown, domains?: Partial<Domains>): string | null {
  const choices = row.choices?.map((choice) => choice.value) ?? [];
  if (row.validation === "domain:backdrop_selection") {
    // A listed painting, Shuffle Paintings, a shuffled folder, or a macOS wallpaper by absolute path (each Mac has its own set).
    if (
      typeof value === "string" &&
      (choices.includes(value) || value === "daily" || /^(system|file|folder):\//.test(value))
    )
      return null;
    return "expected none, daily, a listed painting, system:<absolute path>, file:<absolute path> or folder:<absolute path>";
  }
  if (row.validation === "domain:custom_densities") {
    return Array.isArray(value) && value.every(isCustomDensity)
      ? null
      : "expected a list of densities, each with a lowercase id and a name";
  }
  if (row.validation === "domain:search_template") {
    return isSearchTemplate(value) ? null : "expected a web address with %s or {searchTerms}, or empty";
  }
  switch (row.kind) {
    case "toggle":
      return typeof value === "boolean" ? null : "expected true or false";
    case "choice":
      return typeof value === "string" && choices.includes(value) ? null : `expected one of ${choices.join(", ")}`;
    case "choice_or_number":
      if (typeof value === "string" && choices.includes(value)) return null;
      return inRange(row, value)
        ? null
        : `expected one of ${choices.join(", ")} or a number from ${row.range?.min} to ${row.range?.max}`;
    case "choice_or_url": {
      if (typeof value === "string" && choices.includes(value)) return null;
      const key = row.url_key ?? "url";
      const members = typeof value === "object" && value !== null && !Array.isArray(value) ? Object.keys(value) : [];
      return members.length === 1 && members[0] === key && isHttpOrigin((value as Record<string, unknown>)[key])
        ? null
        : `expected one of ${choices.join(", ")} or {"${key}": "http(s)://host[:port]"}`;
    }
    case "number":
      return inRange(row, value) ? null : `expected a number from ${row.range?.min} to ${row.range?.max}`;
    case "color":
      return isHexColor(value) ? null : "expected a color #RRGGBB or #RRGGBBAA";
    case "url":
      return isPageURL(value) ? null : "expected an http(s), about: or file: address";
    case "host_list":
      return Array.isArray(value) && value.every(isHost) ? null : "expected a list of host names";
    case "folder_list":
      if (row.key === "agents.chats.roots") {
        // Full home/TCC/symlink validation belongs to the native host; this is the portable shape.
        return Array.isArray(value) &&
          value.every(
            (item) =>
              typeof item === "string" &&
              item.startsWith("/") &&
              item !== "/" &&
              !/^\/(Volumes|Network|net)(\/|$)/i.test(item),
          )
          ? null
          : "expected absolute, unprotected chat folder paths";
      }
      return Array.isArray(value) &&
        value.every((item) => typeof item === "string" && (item.startsWith("/") || item.startsWith("~/")))
        ? null
        : "expected a list of absolute or ~/ folder paths";
    case "time_range": {
      const range = value as { start?: unknown; end?: unknown } | null;
      return typeof range === "object" && range !== null && isTime(range.start) && isTime(range.end)
        ? null
        : "expected {start, end} times HH:MM";
    }
    case "theme":
      // A theme row's default is a keyword (appearance.appTheme: followTerminal), not a theme.
      if (row.default !== null && value === row.default) return null;
      return themeInDomain(domains?.themes, value) ? null : "unknown theme";
    case "font_family":
      return inDomain(domains?.font_families, value) ? null : "unknown font family";
    case "text":
      return typeof value === "string" ? null : "expected text";
    case "sound":
      return inDomain(domains?.sounds, value) ? null : "unknown sound";
    case "number_list":
      return Array.isArray(value) && value.every((item) => inRange(row, item))
        ? null
        : `expected a list of numbers from ${row.range?.min} to ${row.range?.max}`;
    case "string_map":
      return typeof value === "object" &&
        value !== null &&
        !Array.isArray(value) &&
        Object.values(value).every((item) => typeof item === "string")
        ? null
        : "expected an object of strings";
    case "sound_rules":
      return typeof value === "object" &&
        value !== null &&
        !Array.isArray(value) &&
        Object.values(value).every(
          (item) => typeof item === "string" || (typeof item === "object" && item !== null && !Array.isArray(item)),
        )
        ? null
        : "expected an object of sound rules";
    case "string_list":
      if (row.choices) {
        const values = row.choices.map((choice) => choice.value);
        return Array.isArray(value) && value.every((item) => typeof item === "string" && values.includes(item))
          ? null
          : `expected a list of ${values.map((item) => `"${item}"`).join(", ")}`;
      }
      return Array.isArray(value) && value.every((item) => typeof item === "string" && item.length > 0)
        ? null
        : "expected a list of non-empty strings";
  }
}
