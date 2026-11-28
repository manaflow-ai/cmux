// The web client's own routes (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, Deeplinks): the page's
// path, read the way cmux-tui/crates/cmux-web-route (route.rs) reads it. That crate is the grammar;
// this is the page's copy of its path forms only, held to it by the shared vectors
// (schemas/deeplinks/web-routes.json, test/web-host-route.test.ts), until the web client's wasm
// (cmux-remote-web) carries the crate itself.
//
// - `/m/<machine>/agent/<harness>/<session>[?message=<id>]`
// - `/m/<machine>/ws/<ws_ id>`
// - `/deeplink/agent?harness=&session=[&host=&machine=&message=]`
//
// A route is an address and never runs anything: of a query only `message` is read.

export type WebMachine = { id: string } | { name: string };

export type WebRoute =
  | { kind: "agent"; machine?: WebMachine; harness: string; session: string; message?: string }
  | { kind: "workspace"; machine?: WebMachine; workspace: string };

/// RouteError::code in route.rs.
export type WebRouteError = "not-a-route" | "machine" | "harness" | "session" | "workspace" | "link";

export type WebRouteResult = { ok: true; route: WebRoute } | { ok: false; error: WebRouteError };

const HARNESS = /^[a-z0-9-]{1,64}$/;
const SESSION = /^(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;
const NAME = /^(?!\.+$)[A-Za-z0-9._-]{1,64}$/;
const MESSAGE = /^(?!\.+$)[A-Za-z0-9._-]{1,200}$/;
const MACHINE_ID = /^machine_[0-9a-f]{32}$/;
const WORKSPACE = /^ws_[0-9a-f]{32}$/;
const MAX_ADDRESS = 2048;

/// Percent-decoding that refuses a bad escape or bytes that are not UTF-8, as route.rs's.
function decode(value: string): string | undefined {
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

/// `key=value` pairs of a query, each decoded; `&amp;` read as `&` (a link copied from HTML).
function pairs(query: string): Array<[string, string | undefined]> {
  return query
    .replace(/&amp;/g, "&")
    .split("&")
    .filter((pair) => pair !== "")
    .map((pair) => {
      const at = pair.indexOf("=");
      const [key, value] = at < 0 ? [pair, ""] : [pair.slice(0, at), pair.slice(at + 1)];
      return [decode(key) ?? "", decode(value)];
    });
}

/// The one value of `key`, when the query carries it once and `pattern` takes it.
function single(query: string, key: string, pattern: RegExp): string | undefined {
  const values = pairs(query).filter(([k]) => k === key);
  if (values.length !== 1) return undefined;
  const value = values[0]![1];
  return value !== undefined && pattern.test(value) ? value : undefined;
}

function machineSegment(raw: string): WebMachine | undefined {
  const value = decode(raw);
  if (value === undefined) return undefined;
  if (value.startsWith("machine_")) return MACHINE_ID.test(value) ? { id: value } : undefined;
  return NAME.test(value) ? { name: value } : undefined;
}

/// The agent link page's query (schemas/deeplinks/agent-link.json): harness and session once
/// each, the machine id over the host, and the message.
function agentLink(query: string): WebRouteResult {
  const all = pairs(query);
  const required: Record<"harness" | "session", string> = { harness: "", session: "" };
  for (const key of ["harness", "session"] as const) {
    const values = all.filter(([k]) => k === key);
    if (values.length !== 1) return { ok: false, error: "link" };
    const value = values[0]![1];
    if (!value || !(key === "harness" ? HARNESS : SESSION).test(value)) return { ok: false, error: "link" };
    required[key] = value;
  }
  const id = single(query, "machine", MACHINE_ID);
  const host = single(query, "host", NAME);
  const message = single(query, "message", MESSAGE);
  const machine = id ? { id } : host ? { name: host } : undefined;
  return {
    ok: true,
    route: { kind: "agent", ...(machine && { machine }), ...required, ...(message && { message }) },
  };
}

/// The route a web client path names (`location.pathname + location.search`, any fragment ignored).
export function parseWebRoute(address: string): WebRouteResult {
  const text = address.trim();
  if (!text.startsWith("/") || text.length > MAX_ADDRESS || /\s/.test(text)) return { ok: false, error: "not-a-route" };
  const beforeFragment = text.split("#", 1)[0]!;
  const at = beforeFragment.indexOf("?");
  let path = at < 0 ? beforeFragment : beforeFragment.slice(0, at);
  const query = at < 0 ? "" : beforeFragment.slice(at + 1);
  if (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  if (path === "/deeplink/agent") return agentLink(query);
  const segments = path.split("/").slice(1);
  if (segments[0] !== "m" || segments.length < 2) return { ok: false, error: "not-a-route" };
  const machine = machineSegment(segments[1]!);
  if (!machine) return { ok: false, error: "machine" };
  const rest = segments.slice(2);
  if (rest[0] === "agent" && rest.length === 3) {
    const harness = decode(rest[1]!);
    if (harness === undefined || !HARNESS.test(harness)) return { ok: false, error: "harness" };
    const session = decode(rest[2]!);
    if (session === undefined || !SESSION.test(session)) return { ok: false, error: "session" };
    const message = single(query, "message", MESSAGE);
    return { ok: true, route: { kind: "agent", machine, harness, session, ...(message && { message }) } };
  }
  if (rest[0] === "ws" && rest.length === 2) {
    const workspace = decode(rest[1]!);
    if (workspace === undefined || !WORKSPACE.test(workspace)) return { ok: false, error: "workspace" };
    return { ok: true, route: { kind: "workspace", machine, workspace } };
  }
  return { ok: false, error: "not-a-route" };
}

/// The route's canonical path, as Route::path in route.rs.
export function webRoutePath(route: WebRoute): string | undefined {
  const segment = route.machine && ("id" in route.machine ? route.machine.id : route.machine.name);
  if (route.kind === "workspace") return segment ? `/m/${segment}/ws/${route.workspace}` : undefined;
  if (segment)
    return `/m/${segment}/agent/${route.harness}/${route.session}${route.message ? `?message=${route.message}` : ""}`;
  return `/deeplink/agent?harness=${route.harness}&session=${route.session}${route.message ? `&message=${route.message}` : ""}`;
}
