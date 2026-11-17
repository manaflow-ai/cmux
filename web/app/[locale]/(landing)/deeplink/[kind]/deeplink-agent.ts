type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

// The parameters, charsets and vectors here are schemas/deeplinks/agent-link.json,
// the one schema this page and the app's parser share; web/tests/deeplink-agent.test.ts
// runs its vectors, so an emitter and a parser cannot drift.
export const AGENT_ALLOWED_PARAMS = [
  "harness",
  "session",
  "machine",
  "host",
  "name",
  "message",
] as const;
export const AGENT_REQUIRED_PARAMS = ["harness", "session"] as const;
/** The query parameters the native link carries, in the order it writes them. */
export const AGENT_QUERY_PARAMS = ["host", "name", "message", "machine"] as const;

type AgentParam = (typeof AGENT_ALLOWED_PARAMS)[number];

/** The charset each parameter's value must match, as the shared schema states it. */
export const AGENT_PARAM_PATTERNS: Record<AgentParam, RegExp> = {
  harness: /^[a-z0-9-]{1,64}$/,
  session: /^(?!\.+$)[A-Za-z0-9._-]{1,200}$/,
  machine: /^machine_[0-9a-f]{32}$/,
  host: /^(?!\.+$)[A-Za-z0-9._-]{1,64}$/,
  name: /^(?!\.+$)[A-Za-z0-9._-]{1,64}$/,
  message: /^(?!\.+$)[A-Za-z0-9._-]{1,200}$/,
};

function isRequired(name: AgentParam): boolean {
  return (AGENT_REQUIRED_PARAMS as readonly string[]).includes(name);
}

/**
 * Path-form native URL (`cmux://agent/<harness>/<session>?host=&name=&message=`)
 * that cmux NEXT parses. Returns null unless harness and session are present and
 * valid, so the page never echoes unvalidated input into a link; a hint the app
 * cannot use is left out of the link instead of killing it.
 */
export function agentNativeHref(params: SearchParams): string | null {
  return agentLinkModel(params)?.href ?? null;
}

export type AgentLinkModel = {
  harness: string;
  session: string;
  machine?: string;
  host?: string;
  name?: string;
  message?: string;
  href: string;
};

/** What the page shows for a link: its model, plus the names it could not use. */
export type AgentLinkResult = {
  /** The link, or null when harness or session is missing or unusable. */
  model: AgentLinkModel | null;
  /**
   * Names, never values, of parameters cmux ignores: ones it does not know,
   * repeated ones, and hints whose value falls outside the charset. An ignored
   * name never stops the session from opening.
   */
  ignored: string[];
  /** Required parameters the link does not carry, or carries empty. */
  missing: string[];
  /** Required parameters whose value cmux cannot use. */
  invalid: string[];
  /**
   * Required parameters the link carries twice. Which session a link names
   * cannot be guessed, so the link is refused by its own name, not reported as
   * a bad value; a repeated hint is ignored instead (see `ignored`).
   */
  duplicates: string[];
};

/** How many ignored names the page lists, however long the URL is. */
const IGNORED_NAMES_SHOWN = 8;

/**
 * An unknown parameter's name as the page prints it: the link's own text, cut to
 * the charset and length a parameter name can have, so no URL text is echoed
 * verbatim. A name with nothing left prints as `?`.
 */
function displayParamName(name: string): string {
  return name.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 32) || "?";
}

/** Why cmux cannot use one parameter's value, in its own words. */
type ParamIssue = "missing" | "invalid" | "duplicate" | "ignored";

/**
 * One parameter as the page reads it: its value, or why cmux cannot use it. A
 * required parameter that is absent, empty, repeated or outside its charset
 * stops the link; an optional one is only ignored by name.
 */
function readParam(
  name: AgentParam,
  value: SearchValue,
): { value?: string; issue?: ParamIssue } {
  const required = isRequired(name);
  // Absent, or there with nothing in it: the link does not name it.
  if (value === undefined || value === "") {
    if (required) return { issue: "missing" };
    return value === "" ? { issue: "ignored" } : {};
  }
  // A repeated parameter (`?host=a&host=b`) arrives as an array: no single value.
  if (typeof value !== "string") return { issue: required ? "duplicate" : "ignored" };
  if (!AGENT_PARAM_PATTERNS[name].test(value)) {
    return { issue: required ? "invalid" : "ignored" };
  }
  return { value };
}

/**
 * Reads an agent link's parameters. Unknown and unusable hints are reported by
 * name and dropped; the session still opens, because an agent link is an address
 * and the app only opens what the viewer can already reach.
 */
export function agentLink(params: SearchParams): AgentLinkResult {
  const allowed = new Set<string>(AGENT_ALLOWED_PARAMS);
  const missing: string[] = [];
  const invalid: string[] = [];
  const duplicates: string[] = [];
  // The schema's order: the parameters it names, then the ones no agent link
  // reads, so a reader of the same link always names the same parameter first.
  const ignored: string[] = [];
  const values: Partial<Record<AgentParam, string>> = {};

  const named: Record<ParamIssue, string[]> = {
    missing,
    invalid,
    duplicate: duplicates,
    ignored,
  };
  for (const name of AGENT_ALLOWED_PARAMS) {
    const read = readParam(name, params[name]);
    if (read.value !== undefined) values[name] = read.value;
    else if (read.issue !== undefined) named[read.issue].push(name);
  }
  for (const name of Object.keys(params)) {
    if (allowed.has(name)) continue;
    const shown = displayParamName(name);
    // A name that prints as a parameter the link did use (`?[host]=x` beside `?host=big-red`)
    // would read as if cmux had ignored that one, right above a link that carries it.
    if (allowed.has(shown) && values[shown as AgentParam] !== undefined) continue;
    ignored.push(shown);
  }

  const shown = Array.from(new Set(ignored)).slice(0, IGNORED_NAMES_SHOWN);
  const { harness, session } = values;
  if (harness === undefined || session === undefined) {
    return { model: null, ignored: shown, missing, invalid, duplicates };
  }

  const query = new URLSearchParams();
  for (const name of AGENT_QUERY_PARAMS) {
    const value = values[name];
    if (value !== undefined) query.set(name, value);
  }
  const queryString = query.toString();
  const href = `cmux://agent/${encodeURIComponent(harness)}/${encodeURIComponent(session)}${
    queryString ? `?${queryString}` : ""
  }`;
  return {
    model: {
      harness,
      session,
      ...(values.machine !== undefined ? { machine: values.machine } : {}),
      ...(values.host !== undefined ? { host: values.host } : {}),
      ...(values.name !== undefined ? { name: values.name } : {}),
      ...(values.message !== undefined ? { message: values.message } : {}),
      href,
    },
    ignored: shown,
    missing,
    invalid,
    duplicates,
  };
}

/**
 * A private reference (`?id=aid-<20 hex>`) that agent links in public places
 * carry instead of harness, session and host. It names no machine or session,
 * and this page never resolves it: no table and no lookup ship here.
 */
export const AGENT_REFERENCE_PATTERN = /^aid-[0-9a-f]{20}$/;

/** The reference a link carries in place of a session, or null. */
export function agentReference(params: SearchParams): string | null {
  const id = params.id;
  if (typeof id !== "string" || !AGENT_REFERENCE_PATTERN.test(id)) return null;
  return params.session === undefined ? id : null;
}

// Invariant: this model holds only the URL's own harness/session/host/name/message plus the cmux:// href; no lookups, ever.
export function agentLinkModel(params: SearchParams): AgentLinkModel | null {
  return agentLink(params).model;
}
