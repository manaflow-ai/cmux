/**
 * The image keeps public IPv6 routable (RFD 0067 item 5, hq docs/rfd/0067-freestyle-ipv4-path.md).
 *
 * A fix made for one host whose IPv6 was dead, an `unreachable 2000::/3` route at metric 1
 * (hq docs/handbook/fetch-shape-stalls-before-the-first-byte.md), must never reach the Cloud VM image: on a
 * Freestyle VM IPv6 is the fast family (582 against 96 Mbit/s from the edge, RFD 0056) and IPv4 the lossy
 * one, so the route would put every fetch on the slow path. The smoke reads a clone's routes and fails when
 * a block route covers public IPv6, when there is no IPv6 default route, or when the route lookup for a
 * public address does not name a device.
 */

/** A public IPv6 address the route lookup is asked about (Cloudflare's resolver; nothing is sent to it). */
export const PUBLIC_IPV6_PROBE = "2606:4700:4700::1111";
/** The router advertisement can land a few seconds after boot; the command waits this long for a default route. */
export const DEFAULT_ROUTE_WAIT_SECONDS = 30;

/** Smoke step on a clone: the IPv6 default route, the main table, and the lookup for a public address. */
export function ipv6RouteSmokeCommand(): string {
  return [
    `for i in $(seq 1 ${DEFAULT_ROUTE_WAIT_SECONDS}); do ip -6 route show default 2>/dev/null | grep -q . && break; sleep 1; done`,
    "echo '== default'",
    "ip -6 route show default 2>&1",
    "echo '== main'",
    "ip -6 route show 2>&1",
    "echo '== get'",
    `ip -6 route get ${PUBLIC_IPV6_PROBE} 2>&1`,
    "echo '== end'",
  ].join("; ");
}

/** Route types that refuse a destination instead of sending it; `ip route` prints them before the prefix. */
const BLOCK_TYPES = new Set(["unreachable", "blackhole", "prohibit", "throw"]);

function sections(stdout: string): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  let current: string | undefined;
  for (const raw of stdout.split("\n")) {
    const line = raw.trim();
    const marker = /^== (\w+)$/.exec(line);
    if (marker) {
      current = marker[1];
      out[current] = [];
    } else if (current && line) out[current].push(line);
  }
  return out;
}

/** True when an IPv6 prefix overlaps global unicast (2000::/3) or is the default route. */
export function coversPublicIpv6(prefix: string): boolean {
  const p = prefix.toLowerCase();
  if (p === "default" || p === "::/0") return true;
  const [addr, lenText] = p.split("/");
  const len = lenText === undefined ? 128 : Number(lenText);
  const first = addr.startsWith("::") ? 0 : Number.parseInt(addr.split(":")[0] || "0", 16);
  if (!Number.isFinite(first) || !Number.isFinite(len)) return false;
  // A prefix shorter than /3 covers 2000::/3 when its leading bits match 2000's (only ::/1 and ::/2 do).
  if (len < 3) return (first >> (16 - len)) === (0x2000 >> (16 - len));
  return (first & 0xe000) === 0x2000;
}

/** What is wrong with the clone's IPv6 routes. Empty when public IPv6 is routed. */
export function ipv6RouteProblems(code: number, stdout: string): string[] {
  const s = sections(stdout);
  if (!s.end) return [`route read did not finish (exit ${code}): ${stdout.trim().slice(-300)}`];
  const problems: string[] = [];
  for (const line of s.main ?? []) {
    const [type, prefix] = line.split(/\s+/);
    if (BLOCK_TYPES.has(type) && prefix && coversPublicIpv6(prefix)) problems.push(`block route on public IPv6: ${line} (a dead-IPv6 host fix must not be in the image, RFD 0067)`);
  }
  if (!(s.default ?? []).some((l) => l.startsWith("default "))) problems.push(`no IPv6 default route after ${DEFAULT_ROUTE_WAIT_SECONDS} s: ${(s.default ?? []).join(" ; ") || "none"}`);
  const get = (s.get ?? []).join(" ; ");
  if (!(s.get ?? []).some((l) => l.startsWith(`${PUBLIC_IPV6_PROBE} `) && / dev \S+/.test(l))) problems.push(`route lookup for ${PUBLIC_IPV6_PROBE} names no device: ${get || "no output"}`);
  return problems;
}
