type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

export const AGENT_ALLOWED_PARAMS = ["harness", "session", "host", "name"] as const;
export const AGENT_REQUIRED_PARAMS = ["harness", "session"] as const;

const agentParamPatterns: Record<(typeof AGENT_ALLOWED_PARAMS)[number], RegExp> = {
  harness: /^[a-z0-9-]{1,32}$/,
  session: /^[A-Za-z0-9._-]{1,200}$/,
  host: /^[A-Za-z0-9._-]{1,64}$/,
  name: /^[A-Za-z0-9._-]{1,64}$/,
};

/** Present params whose values fall outside the agent link's strict charset. */
export function invalidAgentParams(params: SearchParams): string[] {
  return AGENT_ALLOWED_PARAMS.filter((name) => {
    const value = params[name];
    if (value === undefined) return false;
    return typeof value !== "string" || !agentParamPatterns[name].test(value);
  });
}

/**
 * Path-form native URL (`cmux://agent/<harness>/<session>?host=&name=`) that
 * cmux NEXT parses. Returns null unless every param is present and valid, so
 * the page never echoes unvalidated input into a link.
 */
export function agentNativeHref(params: SearchParams): string | null {
  return agentLinkModel(params)?.href ?? null;
}

export type AgentLinkModel = {
  harness: string;
  session: string;
  host?: string;
  name?: string;
  href: string;
};

// Invariant: this model holds only the URL's own harness/session/host/name plus the cmux:// href; no lookups, ever.
export function agentLinkModel(params: SearchParams): AgentLinkModel | null {
  const allowed: readonly string[] = AGENT_ALLOWED_PARAMS;
  if (Object.keys(params).some((key) => !allowed.includes(key))) return null;
  const { harness, session, host, name } = params;
  if (typeof harness !== "string" || typeof session !== "string") return null;
  if (invalidAgentParams(params).length > 0) return null;
  const query = new URLSearchParams();
  if (typeof host === "string") query.set("host", host);
  if (typeof name === "string") query.set("name", name);
  const queryString = query.toString();
  const href = `cmux://agent/${encodeURIComponent(harness)}/${encodeURIComponent(session)}${
    queryString ? `?${queryString}` : ""
  }`;
  return {
    harness,
    session,
    ...(typeof host === "string" ? { host } : {}),
    ...(typeof name === "string" ? { name } : {}),
    href,
  };
}
