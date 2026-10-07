// Portable value checks per row kind. The daemon is the authority; the mock provider uses
// these to behave like it, and the page uses them to refuse a bad field value before sending.
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

/** Returns null when `value` is valid for `row`, otherwise a short English reason. */
export function validate(row: SchemaRow, value: unknown, domains?: Partial<Domains>): string | null {
  const choices = row.choices?.map((choice) => choice.value) ?? [];
  if (row.validation === "domain:backdrop_selection") {
    // A listed painting or a macOS wallpaper by absolute path (each Mac has its own set).
    if (typeof value === "string" && (choices.includes(value) || value.startsWith("system:/"))) return null;
    return "expected none, a listed painting or system:<absolute path>";
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
      return inDomain(domains?.themes, value) ? null : "unknown theme";
    case "font_family":
      return inDomain(domains?.font_families, value) ? null : "unknown font family";
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
