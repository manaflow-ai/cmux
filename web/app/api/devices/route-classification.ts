// Route classification helpers for the device registry, kept out of `route.ts`
// because a Next.js route module may only export HTTP method handlers plus route
// config; an extra named export there fails the production build. Both `route.ts`
// and the route tests import these from here.

/**
 * Whether `host` names the local machine. The server mirror of the native
 * `CmxLoopbackHost` classifier (Swift): a loopback route is forbidden in
 * anything that arrives from outside the Mac (a QR/deep-link, and now a manual
 * CLI-added remote), because a phone that dials `127.0.0.1`/`localhost` dials
 * itself. Classification is value-based, not a string-prefix check, so legacy
 * IPv4 spellings (`127.1`, `0x7f.0.0.1`, `2130706433`) and every IPv6 form of
 * `::1`/`::`/IPv4-mapped loopback classify the same way they would dial.
 *
 * Covers `127.0.0.0/8`, the unspecified `0.0.0.0/8` (a connect to it lands on
 * loopback), IPv6 `::1` and `::`, IPv4-mapped/compatible IPv6 embedding those
 * ranges, and `localhost` / `*.localhost` with or without a trailing root dot.
 */
export function hostIsLoopback(rawHost: string): boolean {
  let host = rawHost.trim().toLowerCase();
  if (host.startsWith("[") && host.endsWith("]") && host.length > 2) {
    host = host.slice(1, -1);
  }
  // Strip an IPv6 zone index (`%lo0`): the zone scopes the interface, not the
  // address.
  const zone = host.indexOf("%");
  if (zone >= 0) host = host.slice(0, zone);
  // A single trailing root dot is the fully-qualified spelling of the same
  // name (`localhost.`) and must classify identically.
  if (host.endsWith(".") && host.length > 1) host = host.slice(0, -1);
  if (host.length === 0) return false;
  if (host === "localhost" || host.endsWith(".localhost")) return true;

  const ipv4FirstOctet = parseIPv4FirstOctet(host);
  if (ipv4FirstOctet !== null) return ipv4FirstOctet === 127 || ipv4FirstOctet === 0;

  const ipv6 = parseIPv6Bytes(host);
  if (ipv6) return ipv6IsSelfDialing(ipv6);

  return false;
}

/**
 * The first octet of `host` parsed with `inet_aton` semantics (dotted quad,
 * fewer-than-four parts, octal, hex, single 32-bit decimal), or `null` when it
 * is not an IPv4 literal in any of those forms. Mirrors `inet_aton` so a
 * name-looking numeric host classifies exactly as it dials.
 */
function parseIPv4FirstOctet(host: string): number | null {
  const parts = host.split(".");
  if (parts.length === 0 || parts.length > 4) return null;
  const values: number[] = [];
  for (const part of parts) {
    if (part.length === 0) return null;
    let value: number;
    if (/^0[xX][0-9a-fA-F]+$/.test(part)) {
      value = parseInt(part, 16);
    } else if (/^0[0-7]+$/.test(part)) {
      value = parseInt(part, 8);
    } else if (/^[0-9]+$/.test(part)) {
      value = parseInt(part, 10);
    } else {
      return null;
    }
    if (!Number.isFinite(value)) return null;
    values.push(value);
  }
  // The final part is a big-endian remainder filling the low bytes; all
  // leading parts must be single octets. The first octet is `values[0]` when
  // there is more than one part, else the high byte of the 32-bit value.
  if (values.length === 1) {
    const n = values[0];
    if (n < 0 || n > 0xffffffff) return null;
    return (n >>> 24) & 0xff;
  }
  for (let i = 0; i < values.length - 1; i++) {
    if (values[i] < 0 || values[i] > 0xff) return null;
  }
  const last = values[values.length - 1];
  const maxLast = Math.pow(256, 4 - (values.length - 1)) - 1;
  if (last < 0 || last > maxLast) return null;
  return values[0] & 0xff;
}

/**
 * The 16 address bytes of `host` parsed as an IPv6 literal, or `null` when it
 * is not one. Supports `::` compression and a trailing embedded IPv4 quad.
 */
function parseIPv6Bytes(host: string): number[] | null {
  if (!host.includes(":")) return null;
  let work = host;
  const tailBytes: number[] = [];
  // A trailing embedded IPv4 quad (`::ffff:1.2.3.4`). Strip it and carry its 4
  // bytes as the fixed tail; the remaining hex groups parse as usual.
  const lastColon = work.lastIndexOf(":");
  const tail = work.slice(lastColon + 1);
  if (tail.includes(".")) {
    const quad = tail.split(".");
    if (quad.length !== 4) return null;
    for (const q of quad) {
      if (!/^[0-9]+$/.test(q)) return null;
      const v = parseInt(q, 10);
      if (v < 0 || v > 255) return null;
      tailBytes.push(v);
    }
    // Drop the dotted quad including its leading colon, leaving e.g. `::ffff`.
    work = work.slice(0, lastColon);
  }

  const doubleColon = work.indexOf("::");
  let headGroups: string[];
  let tailGroups: string[];
  if (doubleColon >= 0) {
    if (work.indexOf("::", doubleColon + 1) >= 0) return null;
    const head = work.slice(0, doubleColon);
    const rest = work.slice(doubleColon + 2);
    headGroups = head.length ? head.split(":") : [];
    tailGroups = rest.length ? rest.split(":") : [];
  } else {
    headGroups = work.split(":");
    tailGroups = [];
  }

  const groupToBytes = (g: string): number[] | null => {
    if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null;
    const v = parseInt(g, 16);
    return [(v >> 8) & 0xff, v & 0xff];
  };

  const headBytes: number[] = [];
  for (const g of headGroups) {
    const b = groupToBytes(g);
    if (!b) return null;
    headBytes.push(...b);
  }
  const tailGroupBytes: number[] = [];
  for (const g of tailGroups) {
    const b = groupToBytes(g);
    if (!b) return null;
    tailGroupBytes.push(...b);
  }

  const fixedTail = [...tailGroupBytes, ...tailBytes];
  const total = headBytes.length + fixedTail.length;
  if (doubleColon < 0) {
    return total === 16 ? headBytes : null;
  }
  if (total > 16) return null;
  const zeros = new Array(16 - total).fill(0);
  return [...headBytes, ...zeros, ...fixedTail];
}

/** Whether 16 IPv6 bytes name the local machine (`::1`, `::`, or mapped). */
function ipv6IsSelfDialing(bytes: number[]): boolean {
  if (bytes.length !== 16) return false;
  if (bytes.slice(0, 15).every((b) => b === 0) && bytes[15] <= 1) return true;
  const prefixZero = bytes.slice(0, 10).every((b) => b === 0);
  const isMapped = prefixZero && bytes[10] === 0xff && bytes[11] === 0xff;
  const isCompatible = prefixZero && bytes[10] === 0 && bytes[11] === 0;
  if (isMapped || isCompatible) {
    const first = bytes[12];
    return first === 127 || first === 0;
  }
  return false;
}

/**
 * Extract the host string from a route's endpoint, tolerating both the
 * `{type:"host_port",host,port}` shape and the older `{host,port}` shape that
 * appears in stored rows. Returns null for non-host endpoints (peer/url).
 */
function routeEndpointHost(route: Record<string, unknown>): string | null {
  const endpoint = route.endpoint;
  if (!endpoint || typeof endpoint !== "object" || Array.isArray(endpoint)) {
    return null;
  }
  const host = (endpoint as Record<string, unknown>).host;
  return typeof host === "string" ? host : null;
}

/**
 * Whether any route is a loopback route: declared `debug_loopback` kind or a
 * host:port endpoint whose host parses as loopback. Used to reject manual
 * CLI-added remotes that a phone could never reach.
 */
export function routesContainLoopback(routes: unknown[]): boolean {
  for (const route of routes) {
    if (!route || typeof route !== "object" || Array.isArray(route)) continue;
    const record = route as Record<string, unknown>;
    if (record.kind === "debug_loopback") return true;
    const host = routeEndpointHost(record);
    if (host !== null && hostIsLoopback(host)) return true;
  }
  return false;
}

/**
 * Whether `host` is a Tailscale address a signed-in phone can authenticate to:
 * a CGNAT `100.64.0.0/10` IP or a `*.ts.net` MagicDNS name. Mirrors the native
 * `MobileShellRouteAuthPolicy` (and the CLI's `RemoteRouteSpec.isTailscaleAttachable`).
 * iOS only sends the Stack token over a `.tailscale` route whose host matches
 * this, so any other host registers but fails to attach (`insecureManualRoute`).
 */
export function hostIsTailscaleAttachable(rawHost: string): boolean {
  const host = rawHost.trim().toLowerCase();
  // A *.ts.net MagicDNS name, but only when the whole string is a syntactically
  // valid DNS hostname (labels of letters/digits/hyphens, dot-separated, no
  // scheme, spaces, port, or path). A loose suffix check would accept junk like
  // "bad host.ts.net" or "https://mac.ts.net" that the phone cannot dial.
  if (host.endsWith(".ts.net") && isValidDnsHostname(host)) return true;
  const parts = host.split(".");
  if (parts.length !== 4) return false;
  const octets: number[] = [];
  for (const part of parts) {
    // Canonical dotted decimal only: a single 0, or a non-zero leading digit.
    // Rejects leading-zero spellings like `0100` that inet_aton would read as
    // octal (so a route this gate marks Tailscale-safe could dial elsewhere
    // while the phone still sends the Stack token).
    if (!/^(0|[1-9][0-9]*)$/.test(part)) return false;
    const value = Number(part);
    if (value < 0 || value > 255) return false;
    octets.push(value);
  }
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

/** A syntactically valid DNS hostname: 1-253 chars, dot-separated labels of
 * 1-63 chars using letters/digits/hyphens, no leading/trailing hyphen per label. */
function isValidDnsHostname(host: string): boolean {
  if (host.length === 0 || host.length > 253) return false;
  const labels = host.split(".");
  for (const label of labels) {
    if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) return false;
  }
  return true;
}

/**
 * Whether any host:port route has a host that is NOT attachable from the phone
 * (not a Tailscale CGNAT/`*.ts.net` host). The server-side guard for manual
 * remotes so a direct API caller cannot register a remote that shows in the
 * device list but deterministically fails to attach, matching the CLI/app check.
 * Non-host routes (peer/url) and routes without a host are ignored here; the
 * loopback guard runs separately.
 */
export function routesContainNonAttachableHost(routes: unknown[]): boolean {
  for (const route of routes) {
    if (!route || typeof route !== "object" || Array.isArray(route)) continue;
    const record = route as Record<string, unknown>;
    const host = routeEndpointHost(record);
    if (host !== null && !hostIsTailscaleAttachable(host)) return true;
  }
  return false;
}

/**
 * Whether `routes` is a valid set of manual attach routes: a non-empty array
 * where every entry is a `tailscale` host:port route with a 1-65535 port and a
 * Tailscale-attachable host. The full server-side schema check for the manual
 * (`cmux remotes add`) path, mirroring the CLI's `RemoteRouteSpec`. Without it a
 * direct API caller could POST `manual: true` with an empty array or a `port: 0`
 * / wrong-kind route that stores but cannot be used, reintroducing the
 * "lists but cannot attach" failure. The Mac's own self-registration is not
 * `manual` and is not subject to this (it advertises whatever live routes it has).
 */
export function manualRoutesAreValid(routes: unknown[]): boolean {
  if (!Array.isArray(routes) || routes.length === 0) return false;
  for (const route of routes) {
    if (!route || typeof route !== "object" || Array.isArray(route)) return false;
    const record = route as Record<string, unknown>;
    if (record.kind !== "tailscale") return false;
    // Require a non-empty `id`: the iOS `CmxAttachRoute` decoder requires it, so
    // a route without one stores but the phone drops it as malformed.
    if (typeof record.id !== "string" || record.id.trim().length === 0) return false;
    const endpoint = record.endpoint;
    if (!endpoint || typeof endpoint !== "object" || Array.isArray(endpoint)) {
      return false;
    }
    const ep = endpoint as Record<string, unknown>;
    // Require `type: "host_port"` exactly: the iOS endpoint decoder keys on it,
    // so a missing/other type is undecodable on the phone.
    if (ep.type !== "host_port") return false;
    const host = ep.host;
    if (typeof host !== "string" || host.trim().length === 0) return false;
    if (!hostIsTailscaleAttachable(host)) return false;
    const port = ep.port;
    if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) {
      return false;
    }
    // `priority` is optional, but the iOS `CmxAttachRoute` decoder reads it as an
    // Int, so a non-integer (`"0"`, `1.5`) makes the phone drop the route.
    const priority = record.priority;
    if (priority !== undefined && (typeof priority !== "number" || !Number.isInteger(priority))) {
      return false;
    }
  }
  return true;
}
