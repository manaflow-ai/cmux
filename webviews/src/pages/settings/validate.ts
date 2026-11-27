// Portable value checks per row kind. The daemon is the authority; the mock provider uses
// these to behave like it, and the page uses them to refuse a bad field value before sending.
import { isPlacementMap } from "./backgroundPlacement";
import { parseThemeSpec } from "./themeSpec";
import { UI_FONT_VALIDATION } from "./fontPickerModel";
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

/** The installed families a font row takes: every family for the App Font (`domain:ui_font_family`),
 * the fixed-pitch ones for the rest. */
export function fontNames(validation: string | undefined, domains: Partial<Domains> | undefined): string[] | undefined {
  return validation === UI_FONT_VALIDATION ? domains?.ui_font_families : domains?.font_families;
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

/**
 * One command label item (`agentPane.display.commandLabels`): a preset name, or a rule with a label
 * and a program or pattern. The Swift rule is `CommandLabelsSetting.isItem`.
 */
export function isCommandLabel(value: unknown): boolean {
  const nonBlank = (item: unknown) => typeof item === "string" && item.trim() !== "";
  if (typeof value === "string") return nonBlank(value);
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const rule = value as Record<string, unknown>;
  if (!nonBlank(rule.label)) return false;
  if (rule.program !== undefined) {
    const names = Array.isArray(rule.program) ? rule.program : [rule.program];
    if (!names.length || !names.every(nonBlank)) return false;
  }
  if (rule.match !== undefined && !nonBlank(rule.match)) return false;
  if (["link", "icon"].some((key) => rule[key] !== undefined && typeof rule[key] !== "string")) return false;
  return rule.program !== undefined || rule.match !== undefined;
}

/** `sidebar.sections.hidden` / `order`: at most 256 distinct ids of 1 to 128 characters (`SidebarSectionIDsSetting`). */
export function isSidebarSectionIds(value: unknown): boolean {
  if (!Array.isArray(value) || value.length > 256) return false;
  const seen = new Set<string>();
  return value.every((id) => {
    if (typeof id !== "string" || id === "" || Array.from(id).length > 128 || seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

/** An ssh endpoint of a host: `ssh://[user@]host[:port]`, or what ssh takes (`[user@]host`, an alias). */
export function isHostEndpoint(text: unknown): boolean {
  if (typeof text !== "string" || text === "" || text.startsWith("-") || /[\s\p{Cc}]/u.test(text)) return false;
  const scheme = text.indexOf("://");
  if (scheme < 0) return true;
  if (text.slice(0, scheme).toLowerCase() !== "ssh") return false;
  let authority = text.slice(scheme + 3);
  if (authority.endsWith("/")) authority = authority.slice(0, -1);
  if (authority.includes("/")) return false;
  const at = authority.lastIndexOf("@");
  if (at === 0) return false;
  const hostPort = at > 0 ? authority.slice(at + 1) : authority;
  let host = hostPort;
  let port: string | undefined;
  if (hostPort.startsWith("[")) {
    const close = hostPort.indexOf("]");
    if (close < 0) return false;
    host = hostPort.slice(1, close);
    const after = hostPort.slice(close + 1);
    if (after.startsWith(":")) port = after.slice(1);
    else if (after !== "") return false;
  } else {
    const colon = hostPort.lastIndexOf(":");
    if (colon >= 0) {
      host = hostPort.slice(0, colon);
      if (host.includes(":")) return false;
      port = hostPort.slice(colon + 1);
    }
  }
  if (port !== undefined && (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535)) return false;
  return host !== "" && !host.startsWith("-");
}

/**
 * One host of `machines.hosts`: a label and its ssh endpoints tried in order. The Rust rule is
 * cmux-config `hosts::host`, the Swift one `HostsSetting`; a list also needs unique labels.
 */
export function isMachineHost(value: unknown): boolean {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const host = value as Record<string, unknown>;
  if (typeof host.label !== "string" || host.label.trim() === "" || Array.from(host.label).length > 64) return false;
  let endpoints: unknown[];
  if (host.endpoints !== undefined && host.endpoint === undefined) {
    if (!Array.isArray(host.endpoints) || host.endpoints.length < 1 || host.endpoints.length > 16) return false;
    endpoints = host.endpoints;
  } else if (host.endpoints === undefined && host.endpoint !== undefined) {
    endpoints = [host.endpoint];
  } else return false;
  if (!endpoints.every(isHostEndpoint)) return false;
  return ["icon", "id"].every((key) => host[key] === undefined || typeof host[key] === "string");
}

function isMachineHostList(value: unknown): boolean {
  if (!Array.isArray(value) || !value.every(isMachineHost)) return false;
  const labels = value.map((host) => (host as { label: string }).label.trim().toLowerCase());
  return new Set(labels).size === labels.length;
}

/**
 * A fixed picture (`appearance.backgroundLight` / `backgroundDark`, a Time of Day entry): a listed
 * painting or `desktop`, or a macOS wallpaper or image by absolute path; never a shuffle or none.
 * The Swift rule is `BackdropSelectionSetting.picture`; this is its portable shape.
 */
export function isBackdropPicture(value: unknown, choices: readonly string[] = []): boolean {
  if (typeof value !== "string") return false;
  if (["none", "daily", "appearance", "schedule"].includes(value)) return false;
  return choices.includes(value) || /^(system|file):\/./.test(value) || /^[a-z0-9]+(-[a-z0-9]+)*$/.test(value);
}

/** A Time of Day time: `H:MM` / `HH:MM`, or a sun event with an optional `±Nm` (≤1440) / `±Nh` (≤24) offset. */
export function isBackdropTime(key: string): boolean {
  const clock = /^(\d{1,2}):(\d{2})$/.exec(key);
  if (clock) return Number(clock[1]) < 24 && Number(clock[2]) < 60;
  const sun = /^(dawn|sunrise|noon|sunset|dusk)(?:[+-](\d+)([mh]))?$/.exec(key);
  if (!sun) return false;
  return sun[2] === undefined || Number(sun[2]) <= (sun[3] === "m" ? 1440 : 24);
}

/** `appearance.backgroundLocation`: `LAT,LON`, latitude -90...90 and longitude -180...180. */
export function isBackdropLocation(value: unknown): boolean {
  if (typeof value !== "string") return false;
  const parts = value.split(",").map((part) => part.trim());
  if (parts.length !== 2 || parts.some((part) => part === "" || !Number.isFinite(Number(part)))) return false;
  return Math.abs(Number(parts[0])) <= 90 && Math.abs(Number(parts[1])) <= 180;
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
  if (row.validation === "domain:backdrop_picture") {
    return isBackdropPicture(value, choices)
      ? null
      : "expected desktop, a listed painting, system:<absolute path> or file:<absolute path>";
  }
  if (row.validation === "domain:backdrop_schedule") {
    const ok =
      typeof value === "object" &&
      value !== null &&
      !Array.isArray(value) &&
      Object.entries(value).every(([time, picture]) => isBackdropTime(time) && isBackdropPicture(picture));
    return ok ? null : 'expected {"07:00" | "sunset-30m": picture, ...}';
  }
  if (row.validation === "domain:backdrop_placement") {
    return isPlacementMap(value) ? null : 'expected {"<picture>": "fill | fit | center | stretch[ X Y[ ZOOM]]", ...}';
  }
  if (row.validation === "domain:backdrop_memory") {
    const folder = (text: unknown) => typeof text === "string" && /^folder:\/./.test(text);
    const member: Record<string, (text: unknown) => boolean> = {
      rotate: (text) => text === "daily" || folder(text),
      folder,
      off: (text) => text === "none" || isBackdropPicture(text),
    };
    const ok =
      typeof value === "object" &&
      value !== null &&
      !Array.isArray(value) &&
      Object.entries(value).every(([name, text]) => Object.hasOwn(member, name) && member[name]!(text));
    return ok ? null : 'expected {"rotate": daily | folder:<path>, "folder": folder:<path>, "off": none | picture}';
  }
  if (row.validation === "domain:backdrop_location") {
    return isBackdropLocation(value) ? null : "expected LAT,LON such as 37.77,-122.42";
  }
  if (row.validation === "domain:custom_densities") {
    return Array.isArray(value) && value.every(isCustomDensity)
      ? null
      : "expected a list of densities, each with a lowercase id and a name";
  }
  if (row.validation === "domain:command_labels") {
    return Array.isArray(value) && value.every(isCommandLabel)
      ? null
      : "expected a list of preset names and rules, each with a label and a program or match";
  }
  if (row.validation === "domain:hosts") {
    return isMachineHostList(value) ? null : "expected a list of hosts, each with a unique label and ssh endpoints";
  }
  if (row.validation === "domain:app_id") {
    // The manifest's own id pattern, which the export carries on the row.
    return typeof value === "string" && row.pattern !== undefined && new RegExp(row.pattern).test(value)
      ? null
      : "expected an app id, publisher/name in lowercase letters, digits and -";
  }
  if (row.validation === "domain:sidebar_section_ids") {
    return isSidebarSectionIds(value) ? null : "expected a list of at most 256 distinct section ids";
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
      return inDomain(fontNames(row.validation, domains), value) ? null : "unknown font family";
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
    case "json":
      // The top-level type only, as the app: the daemon checks the shape and the row's domain
      // (the sidebar row reducer's bounds) and its refusal says where (`accepted.problems`).
      if (row.shape?.type === "object") {
        return typeof value === "object" && value !== null && !Array.isArray(value) ? null : "expected an object";
      }
      return Array.isArray(value) ? null : "expected a list";
  }
}
