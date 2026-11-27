// SSRF pre-checks for generic integrations. cmux code (no upstream code).
//
// The gateway owns egress: it fetches spec URLs and runs calls through the
// external-effect ledger, refuses private, loopback, link-local and ULA
// targets after DNS resolution and again after every redirect, stops at
// EGRESS_LIMITS.maxResponseBytes and EGRESS_LIMITS.timeoutMs, and stores a
// catalog only up to CATALOG_BLOB_MAX_BYTES. These pure checks see only the
// URL text (no DNS), so a client can refuse obvious bad input early with the
// same error codes the gateway returns; they never replace the gateway check.

import { utf8Length } from "./text.ts"

/** Limits the gateway enforces on every generic fetch and call. */
export const EGRESS_LIMITS = { maxResponseBytes: 10 * 1024 * 1024, timeoutMs: 30_000 } as const

/** Largest catalog (ingested tool list) the ConnectionDO stores in `catalog_blobs`. */
export const CATALOG_BLOB_MAX_BYTES = 2 * 1024 * 1024

export type EgressErrorCode = "egress.invalid_url" | "egress.credentials_in_url" | "egress.private_target" | "egress.too_large" | "egress.timeout" | "egress.host_not_allowed"

export type EgressCheck = { readonly ok: true; readonly host: string } | { readonly ok: false; readonly code: EgressErrorCode; readonly host?: string }

export interface ParsedUrl {
  readonly scheme: "http" | "https"
  /** Lower case; IPv6 without brackets; no trailing dot. */
  readonly host: string
  readonly port?: number
  readonly userinfo: boolean
}

/** Parses an absolute http(s) URL without the URL global. Null for anything else. */
export const parseHttpUrl = (text: string): ParsedUrl | null => {
  const m = /^(https?):\/\/([^/?#\s]*)([/?#][^\s]*)?$/i.exec(text.trim())
  if (!m) return null
  let authority = m[2]!
  let userinfo = false
  const at = authority.lastIndexOf("@")
  if (at >= 0) {
    userinfo = true
    authority = authority.slice(at + 1)
  }
  let host: string
  let portText: string | undefined
  if (authority.startsWith("[")) {
    const close = authority.indexOf("]")
    if (close < 0) return null
    host = authority.slice(1, close)
    const rest = authority.slice(close + 1)
    if (rest !== "" && !rest.startsWith(":")) return null
    portText = rest ? rest.slice(1) : undefined
    if (!/^[0-9a-f:.]+(%25[a-z0-9._~-]+)?$/i.test(host)) return null
  } else {
    const colon = authority.lastIndexOf(":")
    host = colon >= 0 ? authority.slice(0, colon) : authority
    portText = colon >= 0 ? authority.slice(colon + 1) : undefined
    if (!/^[a-z0-9._-]+$/i.test(host)) return null
  }
  if (host === "" || host === ".") return null
  let port: number | undefined
  if (portText !== undefined && portText !== "") {
    if (!/^[0-9]{1,5}$/.test(portText)) return null
    port = Number(portText)
    if (port < 1 || port > 65535) return null
  }
  return { scheme: m[1]!.toLowerCase() as "http" | "https", host: host.toLowerCase().replace(/\.$/, ""), ...(port !== undefined ? { port } : {}), userinfo }
}

// ---------------------------------------------------------------------------
// IP literals. IPv4 accepts every form resolvers accept (inet_aton): 1 to 4
// parts, each decimal, octal (leading 0) or hex (0x), so `0x7f.1` and
// `2130706433` are loopback too.
// ---------------------------------------------------------------------------

const parsePart = (part: string): number | null => {
  if (/^0x[0-9a-f]*$/i.test(part)) return part.length === 2 ? 0 : parseInt(part.slice(2), 16)
  if (/^0[0-7]+$/.test(part)) return parseInt(part.slice(1), 8)
  if (/^(0|[1-9][0-9]*)$/.test(part)) return Number(part)
  return null
}

/** IPv4 literal to an unsigned 32-bit number, or null. */
export const parseIpv4 = (host: string): number | null => {
  const parts = host.split(".")
  if (parts.length === 0 || parts.length > 4 || parts.some((p) => p === "")) return null
  const nums = parts.map(parsePart)
  if (nums.some((n) => n === null)) return null
  const values = nums as number[]
  const last = values[values.length - 1]!
  const head = values.slice(0, -1)
  if (head.some((n) => n > 255)) return null
  if (last >= 2 ** (8 * (5 - values.length))) return null
  let out = 0
  for (const n of head) out = out * 256 + n
  return out * 2 ** (8 * (5 - values.length)) + last
}

const inV4 = (ip: number, base: string, bits: number): boolean => {
  const b = parseIpv4(base)!
  const size = 2 ** (32 - bits)
  return Math.floor(ip / size) === Math.floor(b / size)
}

/** Not publicly routable: unspecified, private, shared (CGNAT), loopback, link-local, benchmark, multicast, reserved. */
const NON_PUBLIC_V4: ReadonlyArray<readonly [string, number]> = [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4]
]

export const isNonPublicIpv4 = (ip: number): boolean => NON_PUBLIC_V4.some(([base, bits]) => inV4(ip, base, bits))

/** IPv6 literal (no brackets, optional zone) to 8 groups, or null. */
export const parseIpv6 = (text: string): number[] | null => {
  let host = text.replace(/%.*$/, "")
  if (!/^[0-9a-f:.]+$/i.test(host) || !host.includes(":")) return null
  const lastColon = host.lastIndexOf(":")
  const tail = host.slice(lastColon + 1)
  if (tail.includes(".")) {
    // A dotted IPv4 tail becomes two hex groups.
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(tail) || tail.split(".").some((p) => Number(p) > 255)) return null
    const v4 = parseIpv4(tail)!
    host = `${host.slice(0, lastColon + 1)}${Math.floor(v4 / 65536).toString(16)}:${(v4 % 65536).toString(16)}`
  }
  const halves = host.split("::")
  if (halves.length > 2) return null
  const groups = (s: string) => (s === "" ? [] : s.split(":"))
  const left = groups(halves[0]!)
  const right = halves.length === 2 ? groups(halves[1]!) : []
  if ([...left, ...right].some((g) => !/^[0-9a-f]{1,4}$/i.test(g))) return null
  const known = left.length + right.length
  if (halves.length === 1 && known !== 8) return null
  if (halves.length === 2 && known > 7) return null
  const fill = halves.length === 2 ? new Array<number>(8 - known).fill(0) : []
  return [...left.map((g) => parseInt(g, 16)), ...fill, ...right.map((g) => parseInt(g, 16))]
}

const embeddedV4 = (g: number[]): number => g[6]! * 65536 + g[7]!

/** Not publicly routable: unspecified, loopback, link-local, site-local, ULA, multicast, and IPv4-embedding forms of a non-public IPv4. */
export const isNonPublicIpv6 = (g: number[]): boolean => {
  const zeroUntil = (n: number) => g.slice(0, n).every((x) => x === 0)
  if (zeroUntil(8)) return true // ::
  if (zeroUntil(7) && g[7] === 1) return true // ::1
  if ((g[0]! & 0xffc0) === 0xfe80) return true // fe80::/10 link-local
  if ((g[0]! & 0xffc0) === 0xfec0) return true // fec0::/10 site-local (deprecated)
  if ((g[0]! & 0xfe00) === 0xfc00) return true // fc00::/7 unique local (ULA)
  if ((g[0]! & 0xff00) === 0xff00) return true // ff00::/8 multicast
  if (zeroUntil(5) && g[5] === 0xffff) return isNonPublicIpv4(embeddedV4(g)) // ::ffff:a.b.c.d mapped
  if (zeroUntil(6)) return isNonPublicIpv4(embeddedV4(g)) // ::a.b.c.d compatible (deprecated)
  if (g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((x) => x === 0)) return isNonPublicIpv4(embeddedV4(g)) // 64:ff9b::/96 NAT64
  if (g[0] === 0x2002) return isNonPublicIpv4(g[1]! * 65536 + g[2]!) // 2002::/16 6to4
  return false
}

const LOCAL_SUFFIXES = [".localhost", ".local", ".internal", ".home.arpa", ".lan", ".intranet", ".corp"]

/**
 * True for hosts that can only name a private target: non-public IP literals,
 * `localhost`, local-only suffixes and single-label names (they resolve only
 * through a local search domain). Public names that resolve to private
 * addresses pass here; the gateway refuses them after DNS.
 */
export const isPrivateHost = (host: string): boolean => {
  const h = host.toLowerCase().replace(/\.$/, "")
  const v6 = parseIpv6(h)
  if (v6) return isNonPublicIpv6(v6)
  const v4 = parseIpv4(h)
  if (v4 !== null) return isNonPublicIpv4(v4)
  if (h === "localhost" || LOCAL_SUFFIXES.some((s) => h.endsWith(s))) return true
  return !h.includes(".")
}

/** The checks a URL import runs before any fetch: http(s), no credentials in the URL, not a private target. */
export const checkEgressUrl = (text: string): EgressCheck => {
  const url = parseHttpUrl(text)
  if (!url) return { ok: false, code: "egress.invalid_url" }
  if (url.userinfo) return { ok: false, code: "egress.credentials_in_url", host: url.host }
  if (isPrivateHost(url.host)) return { ok: false, code: "egress.private_target", host: url.host }
  return { ok: true, host: url.host }
}

/** A document larger than the gateway would fetch. */
export const checkDocumentSize = (text: string): EgressCheck | null => (utf8Length(text) > EGRESS_LIMITS.maxResponseBytes ? { ok: false, code: "egress.too_large" } : null)

// ---------------------------------------------------------------------------
// Team host allowlist (`generic_hosts` in the team integration policy).
// `null` allows any public host; a list allows only matching hosts. Patterns:
// an exact host (`api.example.com`) or `*.example.com` (any subdomain, not the
// apex). The gateway (owner) enforces it on connect, refresh and every call.
// ---------------------------------------------------------------------------

export const isValidHostPattern = (pattern: string): boolean => /^(\*\.)?([a-z0-9-]+\.)*[a-z0-9-]+$/i.test(pattern) && !/^\*\.[^.]+$/.test(pattern)

export const hostMatches = (host: string, pattern: string): boolean => {
  const h = host.toLowerCase().replace(/\.$/, "")
  const p = pattern.toLowerCase()
  if (p.startsWith("*.")) return h.endsWith(p.slice(1)) && h.length > p.length - 1
  return h === p
}

export const hostAllowed = (host: string, genericHosts: ReadonlyArray<string> | null | undefined): boolean =>
  genericHosts === null || genericHosts === undefined || genericHosts.some((p) => hostMatches(host, p))

/** The URL checks plus the team host allowlist, in the order the gateway applies them. */
export const checkGenericTarget = (text: string, genericHosts: ReadonlyArray<string> | null | undefined): EgressCheck => {
  const r = checkEgressUrl(text)
  if (!r.ok) return r
  return hostAllowed(r.host, genericHosts) ? r : { ok: false, code: "egress.host_not_allowed", host: r.host }
}
