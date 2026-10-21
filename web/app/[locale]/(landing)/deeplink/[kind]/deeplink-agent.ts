type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

// The parameters, charsets and vectors here are schemas/deeplinks/agent-link.json,
// the one schema this page and the app's parser share; web/tests/deeplink-agent.test.ts
// runs its vectors, so an emitter and a parser cannot drift.
export const AGENT_ALLOWED_PARAMS = [
  "harness",
  "session",
  "host",
  "name",
  "message",
] as const;
export const AGENT_REQUIRED_PARAMS = ["harness", "session"] as const;
/** The hints the native link carries as query parameters. */
export const AGENT_QUERY_PARAMS = ["host", "name", "message"] as const;

type AgentParam = (typeof AGENT_ALLOWED_PARAMS)[number];

/** The charset each parameter's value must match, as the shared schema states it. */
export const AGENT_PARAM_PATTERNS: Record<AgentParam, RegExp> = {
  harness: /^[a-z0-9-]{1,64}$/,
  session: /^(?!\.+$)[A-Za-z0-9._-]{1,200}$/,
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
  /** Required parameters the link does not carry. */
  missing: string[];
  /** Required parameters whose value cmux cannot use. */
  invalid: string[];
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

/**
 * Reads an agent link's parameters. Unknown and unusable hints are reported by
 * name and dropped; the session still opens, because an agent link is an address
 * and the app only opens what the viewer can already reach.
 */
export function agentLink(params: SearchParams): AgentLinkResult {
  const allowed = new Set<string>(AGENT_ALLOWED_PARAMS);
  const ignored = Object.keys(params)
    .filter((name) => !allowed.has(name))
    .map(displayParamName);
  const missing: string[] = [];
  const invalid: string[] = [];
  const values: Partial<Record<AgentParam, string>> = {};

  for (const name of AGENT_ALLOWED_PARAMS) {
    const value = params[name];
    if (value === undefined) {
      if (isRequired(name)) missing.push(name);
      continue;
    }
    // A repeated parameter (`?host=a&host=b`) arrives as an array: no single value.
    if (typeof value !== "string" || !AGENT_PARAM_PATTERNS[name].test(value)) {
      if (isRequired(name)) invalid.push(name);
      else ignored.push(name);
      continue;
    }
    values[name] = value;
  }

  const shown = Array.from(new Set(ignored)).slice(0, IGNORED_NAMES_SHOWN);
  const { harness, session } = values;
  if (harness === undefined || session === undefined) {
    return { model: null, ignored: shown, missing, invalid };
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
      ...(values.host !== undefined ? { host: values.host } : {}),
      ...(values.name !== undefined ? { name: values.name } : {}),
      ...(values.message !== undefined ? { message: values.message } : {}),
      href,
    },
    ignored: shown,
    missing,
    invalid,
  };
}

// Invariant: this model holds only the URL's own harness/session/host/name/message plus the cmux:// href; no lookups, ever.
export function agentLinkModel(params: SearchParams): AgentLinkModel | null {
  return agentLink(params).model;
}
