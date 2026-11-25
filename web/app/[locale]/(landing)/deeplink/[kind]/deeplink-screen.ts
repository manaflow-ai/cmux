type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

// A screen link opens one display of a Mac the viewer's own account already
// reaches, view-only unless the link asks for control and the viewer agrees:
// `cmux://mac-screen?device=<hub device id>&display=<CGDirectDisplayID>`, with
// an optional `control=1` and a display-only `name`. Like an agent link it is an
// address, not a credential.
export const SCREEN_ALLOWED_PARAMS = ["device", "display", "control", "name"] as const;
export const SCREEN_REQUIRED_PARAMS = ["device"] as const;
/** The query parameters the native link carries, in the order it writes them. */
const SCREEN_QUERY_PARAMS = ["device", "display", "control", "name"] as const;

type ScreenParam = (typeof SCREEN_ALLOWED_PARAMS)[number];

export const SCREEN_PARAM_PATTERNS: Record<ScreenParam, RegExp> = {
  device: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
  // A CGDirectDisplayID is a UInt32, written in decimal.
  display: /^[0-9]{1,10}$/,
  control: /^1$/,
  name: /^(?!\.+$)[A-Za-z0-9._ -]{1,64}$/,
};

export type ScreenLinkModel = {
  device: string;
  display?: string;
  control?: string;
  name?: string;
  href: string;
};

export type ScreenLinkResult = {
  model: ScreenLinkModel | null;
  /** Names, never values, of parameters cmux ignores; an ignored name never stops the screen from opening. */
  ignored: string[];
  missing: string[];
  invalid: string[];
  duplicates: string[];
};

/** A parameter name as the page prints it: cut to the charset a name can have. */
function displayParamName(name: string): string {
  return name.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 32) || "?";
}

const IGNORED_NAMES_SHOWN = 8;

export function screenLink(params: SearchParams): ScreenLinkResult {
  const missing: string[] = [];
  const invalid: string[] = [];
  const duplicates: string[] = [];
  const ignored: string[] = [];
  const values: Partial<Record<ScreenParam, string>> = {};

  for (const name of SCREEN_ALLOWED_PARAMS) {
    const required = (SCREEN_REQUIRED_PARAMS as readonly string[]).includes(name);
    const value = params[name];
    if (value === undefined || value === "") {
      if (required) missing.push(name);
      else if (value === "") ignored.push(name);
    } else if (typeof value !== "string") {
      (required ? duplicates : ignored).push(name);
    } else if (!SCREEN_PARAM_PATTERNS[name].test(value)) {
      (required ? invalid : ignored).push(name);
    } else {
      values[name] = name === "device" ? value.toLowerCase() : value;
    }
  }

  const known = new Set<string>(SCREEN_ALLOWED_PARAMS);
  for (const name of Object.keys(params)) {
    if (!known.has(name)) ignored.push(displayParamName(name));
  }

  const shown = ignored.slice(0, IGNORED_NAMES_SHOWN);
  const result = { ignored: shown, missing, invalid, duplicates };
  if (missing.length > 0 || invalid.length > 0 || duplicates.length > 0 || !values.device) {
    return { model: null, ...result };
  }
  const query = new URLSearchParams();
  for (const name of SCREEN_QUERY_PARAMS) {
    const value = values[name];
    if (value !== undefined) query.set(name, value);
  }
  const href = `cmux://mac-screen?${query.toString().replace(/\+/g, "%20")}`;
  return { model: { device: values.device, ...values, href }, ...result };
}
