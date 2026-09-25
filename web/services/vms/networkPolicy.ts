/**
 * Outbound network policy for a Cloud machine.
 *
 * A machine's outbound traffic is one of three modes:
 *
 * - `full`: every public address (the historical default, and what a machine
 *   with no stored policy has).
 * - `allowlist`: only the listed address ranges and the listed HTTPS domains,
 *   plus the hosts cmux itself needs (see {@link CMUX_REQUIRED_DOMAINS}).
 * - `none`: only the hosts cmux itself needs.
 *
 * Ranges become provider firewall rules (IP layer). Domains become provider
 * TLS egress rules: the provider steers the exact name to its edge through the
 * guest's `/etc/hosts`, so a domain works with no IP-layer grant and no DNS.
 * Domains are exact names on HTTPS/443 only; wildcards are not steerable yet.
 *
 * The policy is data owned by the control plane. The driver reconciles the
 * provider's rules to it on create and on every change, on a running machine,
 * with no restart (Freestyle applies rule changes live).
 */

export const NETWORK_POLICY_VERSION = 1 as const;

export type NetworkPolicyMode = "full" | "allowlist" | "none";

export type NetworkRangeProtocol = "tcp" | "udp";

/** One allowed IP range, optionally narrowed to a port. */
export type NetworkPolicyRange = {
  /** Canonical `network/prefix`, IPv4 or IPv6. A bare address is stored as /32 or /128. */
  readonly cidr: string;
  /** 1–65535. Requires `protocol`. Absent: every port and protocol. */
  readonly port?: number;
  readonly protocol?: NetworkRangeProtocol;
  /** Free-form label shown in the UI, up to 120 characters. */
  readonly note?: string;
};

export type NetworkPolicy = {
  readonly version: typeof NETWORK_POLICY_VERSION;
  readonly mode: NetworkPolicyMode;
  readonly ranges: readonly NetworkPolicyRange[];
  /** Exact lowercase host names, HTTPS only. */
  readonly domains: readonly string[];
  /** Preset ids from {@link NETWORK_POLICY_PRESETS}; expanded server-side so a preset update reaches every machine. */
  readonly presets: readonly string[];
  /**
   * Allowlist mode only: open DNS (53/udp+tcp) to the guest's configured
   * resolvers so tools can resolve names that ranges point at. Domains do not
   * need it. Open DNS is itself an outbound channel, which the UI says.
   */
  readonly allowDns: boolean;
};

export const DEFAULT_NETWORK_POLICY: NetworkPolicy = {
  version: NETWORK_POLICY_VERSION,
  mode: "full",
  ranges: [],
  domains: [],
  presets: [],
  allowDns: true,
};

export type NetworkPolicyPreset = {
  readonly id: string;
  readonly label: string;
  readonly domains: readonly string[];
};

/**
 * Quick-add groups. Exact names only: the provider cannot steer wildcards yet,
 * so a service that shards across many subdomains may need extra entries.
 */
export const NETWORK_POLICY_PRESETS: readonly NetworkPolicyPreset[] = [
  { id: "anthropic", label: "Anthropic / Claude", domains: ["api.anthropic.com", "claude.ai", "console.anthropic.com", "statsig.anthropic.com"] },
  { id: "openai", label: "OpenAI / Codex", domains: ["api.openai.com", "auth.openai.com", "chatgpt.com"] },
  { id: "openrouter", label: "OpenRouter", domains: ["openrouter.ai"] },
  { id: "opencode", label: "OpenCode", domains: ["opencode.ai", "models.dev"] },
  {
    id: "github",
    label: "GitHub",
    domains: [
      "github.com", "api.github.com", "codeload.github.com", "uploads.github.com",
      "raw.githubusercontent.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ],
  },
  { id: "npm", label: "npm", domains: ["registry.npmjs.org"] },
  { id: "pypi", label: "PyPI", domains: ["pypi.org", "files.pythonhosted.org"] },
  { id: "rust", label: "Rust / crates.io", domains: ["crates.io", "index.crates.io", "static.crates.io", "static.rust-lang.org"] },
];

/**
 * Hosts cmux needs in every mode: guest CLI and cmux-tui daemon downloads.
 * The CodeRouter and reflection aliases are separate edge rules the model
 * plane owns; they stay reachable through the edge grant the driver adds.
 */
export const CMUX_REQUIRED_DOMAINS: readonly string[] = [
  "files.cmux.com",
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
];

export const NETWORK_POLICY_LIMITS = { ranges: 64, domains: 128, note: 120 } as const;

const DOMAIN = /^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/;

export class NetworkPolicyValidationError extends Error {
  constructor(readonly path: string, message: string) {
    super(message);
    this.name = "NetworkPolicyValidationError";
  }
}

/** Canonical CIDR, or throws. Accepts a bare address (→ /32 or /128). */
export function canonicalCidr(input: string, path = "cidr"): string {
  const raw = input.trim();
  const [address, prefixText, extra] = raw.split("/");
  if (extra !== undefined || !address) throw new NetworkPolicyValidationError(path, `${JSON.stringify(input)} is not an IP range`);
  const v4 = parseIpv4(address);
  if (v4 !== null) {
    const prefix = prefixText === undefined ? 32 : parsePrefix(prefixText, 32, path);
    const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
    const network = (v4 & mask) >>> 0;
    return `${[24, 16, 8, 0].map((s) => (network >>> s) & 255).join(".")}/${prefix}`;
  }
  const v6 = parseIpv6(address);
  if (v6) {
    const prefix = prefixText === undefined ? 128 : parsePrefix(prefixText, 128, path);
    const masked = v6.map((word, i) => {
      const bits = Math.max(0, Math.min(16, prefix - i * 16));
      return bits === 0 ? 0 : word & ((0xffff << (16 - bits)) & 0xffff);
    });
    return `${formatIpv6(masked)}/${prefix}`;
  }
  throw new NetworkPolicyValidationError(path, `${JSON.stringify(input)} is not an IPv4 or IPv6 address`);
}

/** Whether a canonical CIDR covers the whole of its address family (0.0.0.0/0, ::/0). */
export function isWholeInternet(cidr: string): boolean {
  return cidr === "0.0.0.0/0" || cidr === "::/0";
}

/** Validate and normalize an untrusted policy body. */
export function parseNetworkPolicy(input: unknown): NetworkPolicy {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new NetworkPolicyValidationError("", "network policy must be an object");
  }
  const body = input as Record<string, unknown>;
  const mode = body.mode;
  if (mode !== "full" && mode !== "allowlist" && mode !== "none") {
    throw new NetworkPolicyValidationError("mode", "mode must be full, allowlist, or none");
  }
  const ranges = arrayField(body.ranges, "ranges", NETWORK_POLICY_LIMITS.ranges).map((value, index) =>
    parseRange(value, `ranges.${index}`));
  const domains = arrayField(body.domains, "domains", NETWORK_POLICY_LIMITS.domains).map((value, index) =>
    parseDomain(value, `domains.${index}`));
  const knownPresets = new Set(NETWORK_POLICY_PRESETS.map((preset) => preset.id));
  const presets = arrayField(body.presets, "presets", NETWORK_POLICY_PRESETS.length).map((value, index) => {
    if (typeof value !== "string" || !knownPresets.has(value)) {
      throw new NetworkPolicyValidationError(`presets.${index}`, `unknown preset ${JSON.stringify(value)}`);
    }
    return value;
  });
  const allowDns = body.allowDns === undefined ? true : body.allowDns;
  if (typeof allowDns !== "boolean") throw new NetworkPolicyValidationError("allowDns", "allowDns must be a boolean");
  return {
    version: NETWORK_POLICY_VERSION,
    mode,
    ranges: dedupe(ranges, (range) => `${range.cidr}|${range.port ?? ""}|${range.protocol ?? ""}`),
    domains: dedupe(domains, (domain) => domain),
    presets: dedupe(presets, (preset) => preset),
    allowDns,
  };
}

/** A stored policy, tolerating legacy rows (null → full). Never throws. */
export function storedNetworkPolicy(value: unknown): NetworkPolicy {
  if (value === null || value === undefined) return DEFAULT_NETWORK_POLICY;
  try {
    return parseNetworkPolicy(value);
  } catch {
    // A row that no longer validates keeps the machine usable rather than
    // silently opening it: treat it as `none`, which the UI shows for repair.
    return { ...DEFAULT_NETWORK_POLICY, mode: "none" };
  }
}

/** The provider-neutral rule set a policy compiles to. */
export type NetworkRulePlan = {
  /** Whole public Internet at the IP layer. */
  readonly publicEgress: boolean;
  readonly ranges: readonly NetworkPolicyRange[];
  /** Exact HTTPS names steered through the provider edge (user + presets + required). */
  readonly domains: readonly string[];
  /** Open DNS to the guest's resolvers. */
  readonly dns: boolean;
};

export function compileNetworkPolicy(policy: NetworkPolicy): NetworkRulePlan {
  if (policy.mode === "full" || policy.ranges.some((range) => isWholeInternet(range.cidr) && range.port === undefined)) {
    return { publicEgress: true, ranges: [], domains: [], dns: false };
  }
  const presetDomains = policy.mode === "allowlist"
    ? policy.presets.flatMap((id) => NETWORK_POLICY_PRESETS.find((preset) => preset.id === id)?.domains ?? [])
    : [];
  const userDomains = policy.mode === "allowlist" ? policy.domains : [];
  return {
    publicEgress: false,
    ranges: policy.mode === "allowlist" ? policy.ranges : [],
    domains: dedupe([...CMUX_REQUIRED_DOMAINS, ...presetDomains, ...userDomains], (domain) => domain),
    dns: policy.mode === "allowlist" && policy.allowDns,
  };
}

function parseRange(value: unknown, path: string): NetworkPolicyRange {
  const entry = typeof value === "string" ? { cidr: value } : value;
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    throw new NetworkPolicyValidationError(path, "range must be a CIDR string or an object");
  }
  const { cidr, port, protocol, note } = entry as Record<string, unknown>;
  if (typeof cidr !== "string") throw new NetworkPolicyValidationError(`${path}.cidr`, "cidr is required");
  const portProtocol = parseRangePort(port, protocol, path);
  if (note !== undefined && (typeof note !== "string" || note.length > NETWORK_POLICY_LIMITS.note)) {
    throw new NetworkPolicyValidationError(`${path}.note`, `note must be a string up to ${NETWORK_POLICY_LIMITS.note} characters`);
  }
  return {
    cidr: canonicalCidr(cidr, `${path}.cidr`),
    ...portProtocol,
    ...(note ? { note: (note as string).trim() } : {}),
  };
}

function parseRangePort(port: unknown, protocol: unknown, path: string): Pick<NetworkPolicyRange, "port" | "protocol"> {
  if (port !== undefined && (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535)) {
    throw new NetworkPolicyValidationError(`${path}.port`, "port must be 1–65535");
  }
  if (protocol !== undefined && protocol !== "tcp" && protocol !== "udp") {
    throw new NetworkPolicyValidationError(`${path}.protocol`, "protocol must be tcp or udp");
  }
  if (port !== undefined && protocol === undefined) {
    throw new NetworkPolicyValidationError(`${path}.protocol`, "a port needs a protocol");
  }
  return {
    ...(port !== undefined ? { port: port as number } : {}),
    ...(protocol !== undefined ? { protocol: protocol as NetworkRangeProtocol } : {}),
  };
}

function parseDomain(value: unknown, path: string): string {
  if (typeof value !== "string") throw new NetworkPolicyValidationError(path, "domain must be a string");
  const domain = value.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/\.$/, "");
  if (domain.includes("*")) {
    throw new NetworkPolicyValidationError(path, `${JSON.stringify(value)}: wildcards are not supported yet; list each exact name`);
  }
  if (!DOMAIN.test(domain)) throw new NetworkPolicyValidationError(path, `${JSON.stringify(value)} is not a host name`);
  return domain;
}

function arrayField(value: unknown, path: string, max: number): unknown[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new NetworkPolicyValidationError(path, `${path} must be an array`);
  if (value.length > max) throw new NetworkPolicyValidationError(path, `${path} allows at most ${max} entries`);
  return value;
}

function parsePrefix(text: string, max: number, path: string): number {
  if (!/^\d{1,3}$/.test(text)) throw new NetworkPolicyValidationError(path, `prefix ${JSON.stringify(text)} is not a number`);
  const prefix = Number(text);
  if (prefix > max) throw new NetworkPolicyValidationError(path, `prefix /${prefix} is longer than /${max}`);
  return prefix;
}

function parseIpv4(text: string): number | null {
  const parts = text.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255 || (part.length > 1 && part.startsWith("0")))) {
    return null;
  }
  return parts.reduce((acc, part) => ((acc << 8) | Number(part)) >>> 0, 0);
}

function parseIpv6(text: string): number[] | null {
  if (!/^[0-9a-fA-F:]+$/.test(text) || text.split("::").length > 2) return null;
  const [head, tail] = text.includes("::") ? text.split("::") : [text, undefined];
  const parse = (part: string) => (part === "" ? [] : part.split(":"));
  const headWords = parse(head);
  const tailWords = tail === undefined ? [] : parse(tail);
  const missing = 8 - headWords.length - tailWords.length;
  if (tail === undefined ? missing !== 0 : missing < 1) return null;
  const words = [...headWords, ...Array<string>(tail === undefined ? 0 : missing).fill("0"), ...tailWords];
  if (words.some((word) => !/^[0-9a-fA-F]{1,4}$/.test(word))) return null;
  return words.map((word) => parseInt(word, 16));
}

function formatIpv6(words: number[]): string {
  // RFC 5952: compress the longest run (length ≥ 2) of zero words.
  let bestStart = -1;
  let bestLength = 0;
  for (let i = 0; i < 8;) {
    if (words[i] !== 0) { i += 1; continue; }
    let j = i;
    while (j < 8 && words[j] === 0) j += 1;
    if (j - i > bestLength && j - i >= 2) { bestStart = i; bestLength = j - i; }
    i = j;
  }
  const hex = words.map((word) => word.toString(16));
  if (bestStart < 0) return hex.join(":");
  return `${hex.slice(0, bestStart).join(":")}::${hex.slice(bestStart + bestLength).join(":")}`;
}

function dedupe<T>(values: readonly T[], key: (value: T) => string): T[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    const k = key(value);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}
