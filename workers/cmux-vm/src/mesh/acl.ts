/**
 * The mesh ACL compiler (M1 subset of the network policy shape, DESIGN.md
 * section 4.2). Pure: no store, no provider, no clock.
 *
 * A document is a list of allow rules, default deny:
 *   { "src": ["dev_..." | "device:*"], "dst": ["vm_..." | "vm:*"], "allow": ["tcp:8080", "udp:53", "tcp:*", "icmp", "*"] }
 * Each (device, VM, port) becomes one provider rule `{tunnel} -> {vm, protocol, port}`
 * (the provider takes one port per rule). Device-to-device and VM-to-device
 * rules do not exist in M1: the provider does not forward tunnel to tunnel
 * (DESIGN.md 1.4 Q1), and replies to a device's connection are stateful (Q5).
 *
 * Address rules (transport.md 7 and 13.6): a device that published its current
 * global IPv6 address also gets, for each VM it may reach by any rule, one
 * `{cidr: <address>/128} -> {vm, udp, 4101}` rule: the VM's overlay endpoint
 * on its public IPv6, the direct path. The overlay port only; the VM's peer
 * map and the link hello still decide who completes a session there.
 */

export type MeshProtocol = "tcp" | "udp" | "icmp";

export interface AclRuleInput {
  readonly src: ReadonlyArray<string>;
  readonly dst: ReadonlyArray<string>;
  readonly allow: ReadonlyArray<string>;
}

export interface AclDocument {
  readonly rules: ReadonlyArray<AclRuleInput>;
}

/** The VM's overlay endpoint port (transport.md 3.1): the only port an address rule opens. */
export const ADDRESS_RULE_PORT = 4101;

/**
 * One allowed path. `protocol` null means every protocol (then `port` is null
 * too). `cidr` null: the source is the device's tunnel; otherwise the source is
 * this `/128` (an address rule) and the rule is `udp` on ADDRESS_RULE_PORT.
 */
export interface DesiredRule {
  /** Canonical key; equal keys are the same provider rule. */
  readonly key: string;
  readonly deviceId: string;
  readonly vmId: string;
  readonly protocol: MeshProtocol | null;
  readonly port: number | null;
  readonly cidr: string | null;
}

export interface CompileInput {
  readonly document: AclDocument;
  /** Live devices of this mesh. */
  readonly deviceIds: ReadonlyArray<string>;
  /** VMs that are members of this mesh. */
  readonly vmIds: ReadonlyArray<string>;
  /** Each device's published public IPv6 address, canonical (parseDeviceIpv6); absent: no address rules. */
  readonly deviceIpv6?: ReadonlyMap<string, string>;
  readonly rulesPerResource: number;
  readonly rulesPerMesh: number;
}

export type CompileResult =
  | { readonly ok: true; readonly rules: ReadonlyArray<DesiredRule> }
  | { readonly ok: false; readonly reason: "invalid"; readonly message: string }
  | { readonly ok: false; readonly reason: "perResource"; readonly message: string; readonly resourceId: string; readonly count: number }
  | { readonly ok: false; readonly reason: "perMesh"; readonly message: string; readonly count: number };

interface PortSpec {
  readonly protocol: MeshProtocol | null;
  readonly port: number | null;
}

/** Parses one `allow` entry; null when malformed. */
export const parseAllow = (entry: string): PortSpec | null => {
  if (entry === "*") return { protocol: null, port: null };
  if (entry === "icmp") return { protocol: "icmp", port: null };
  const match = /^(tcp|udp):(\*|[0-9]{1,5})$/u.exec(entry);
  if (match === null) return null;
  const protocol = match[1] === "tcp" ? "tcp" : "udp";
  if (match[2] === "*") return { protocol, port: null };
  const port = Number(match[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { protocol, port };
};

export const ruleKey = (deviceId: string, vmId: string, spec: PortSpec): string =>
  `${deviceId}>${vmId}:${spec.protocol ?? "any"}:${spec.port ?? "*"}`;

/** The key of an address rule: names the address, so a new address is a new rule. */
export const addressRuleKey = (deviceId: string, vmId: string, cidr: string): string => `${deviceId}>${vmId}:udp:${ADDRESS_RULE_PORT}:from:${cidr}`;

/** True for the key of an address rule (its source is a cidr, so deleting the device's tunnel does not delete it). */
export const isAddressRuleKey = (key: string): boolean => key.includes(":from:");

const HEXTET = /^[0-9a-f]{1,4}$/u;

/** The 8 hextets of an IPv6 literal (lowercase, no zone, no prefix, no dotted IPv4 tail); null when malformed. */
const hextets = (text: string): number[] | null => {
  if (text.length === 0 || text.length > 39 || !/^[0-9a-f:]+$/u.test(text)) return null;
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const part = (half: string): number[] | null => {
    if (half === "") return [];
    const groups = half.split(":");
    if (groups.some((group) => !HEXTET.test(group))) return null;
    return groups.map((group) => Number.parseInt(group, 16));
  };
  const head = part(halves[0] ?? "");
  const tail = halves.length === 2 ? part(halves[1] ?? "") : [];
  if (head === null || tail === null) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const missing = 8 - head.length - tail.length;
  if (missing < 1) return null;
  return [...head, ...Array.from({ length: missing }, () => 0), ...tail];
};

/** RFC 5952 text: lowercase, no leading zeros, the longest run (2 or more, first on a tie) of zero hextets as "::". */
const canonical = (groups: ReadonlyArray<number>): string => {
  let bestStart = -1;
  let bestLength = 1;
  for (let index = 0; index < groups.length; ) {
    if (groups[index] !== 0) {
      index++;
      continue;
    }
    let end = index;
    while (end < groups.length && groups[end] === 0) end++;
    if (end - index > bestLength) {
      bestStart = index;
      bestLength = end - index;
    }
    index = end;
  }
  const text = groups.map((group) => group.toString(16));
  if (bestStart < 0) return text.join(":");
  return `${text.slice(0, bestStart).join(":")}::${text.slice(bestStart + bestLength).join(":")}`;
};

/**
 * A device's published public IPv6 address in canonical form, or null. Only
 * one global unicast address (2000::/3) is accepted, never a prefix, zone or
 * IPv4 form, and not the shared transition ranges whose one address stands
 * for many hosts (Teredo 2001::/32, 6to4 2002::/16) or documentation
 * (2001:db8::/32): the rule opens a VM port to exactly one device.
 */
export const parseDeviceIpv6 = (text: string): string | null => {
  const groups = hextets(text.toLowerCase());
  if (groups === null) return null;
  const [first = 0, second = 0] = groups;
  if ((first & 0xe000) !== 0x2000) return null;
  if (first === 0x2001 && (second === 0x0000 || second === 0x0db8)) return null;
  if (first === 0x2002) return null;
  return canonical(groups);
};

const expand = (selectors: ReadonlyArray<string>, wildcard: string, prefix: string, members: ReadonlyArray<string>, side: string) => {
  const memberSet = new Set(members);
  const out = new Set<string>();
  for (const selector of selectors) {
    if (selector === wildcard) {
      for (const member of members) out.add(member);
      continue;
    }
    if (!selector.startsWith(prefix)) return { ok: false as const, message: `${side} entry ${JSON.stringify(selector)} must be ${wildcard} or a ${prefix} id` };
    if (!memberSet.has(selector)) return { ok: false as const, message: `${side} ${selector} is not a member of this mesh` };
    out.add(selector);
  }
  return { ok: true as const, ids: [...out] };
};

export const compileAcl = (input: CompileInput): CompileResult => {
  const byKey = new Map<string, DesiredRule>();
  for (const [index, rule] of input.document.rules.entries()) {
    const sources = expand(rule.src, "device:*", "dev_", input.deviceIds, `rules[${index}].src`);
    if (!sources.ok) return { ok: false, reason: "invalid", message: sources.message };
    const destinations = expand(rule.dst, "vm:*", "vm_", input.vmIds, `rules[${index}].dst`);
    if (!destinations.ok) return { ok: false, reason: "invalid", message: destinations.message };
    const specs: PortSpec[] = [];
    for (const entry of rule.allow) {
      const spec = parseAllow(entry);
      if (spec === null) return { ok: false, reason: "invalid", message: `rules[${index}].allow entry ${JSON.stringify(entry)} is not tcp:<port>, udp:<port>, tcp:*, udp:*, icmp or *` };
      specs.push(spec);
    }
    for (const deviceId of sources.ids) {
      for (const vmId of destinations.ids) {
        for (const spec of specs) {
          const key = ruleKey(deviceId, vmId, spec);
          byKey.set(key, { key, deviceId, vmId, protocol: spec.protocol, port: spec.port, cidr: null });
        }
        const address = input.deviceIpv6?.get(deviceId);
        if (address !== undefined && specs.length > 0) {
          const cidr = `${address}/128`;
          const key = addressRuleKey(deviceId, vmId, cidr);
          byKey.set(key, { key, deviceId, vmId, protocol: "udp", port: ADDRESS_RULE_PORT, cidr });
        }
      }
    }
  }
  const rules = [...byKey.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const perResource = new Map<string, number>();
  for (const rule of rules) {
    perResource.set(rule.deviceId, (perResource.get(rule.deviceId) ?? 0) + 1);
    perResource.set(rule.vmId, (perResource.get(rule.vmId) ?? 0) + 1);
  }
  for (const [resourceId, count] of perResource) {
    if (count > input.rulesPerResource) {
      return {
        ok: false,
        reason: "perResource",
        resourceId,
        count,
        message: `This policy puts ${count} firewall rules on ${resourceId}; the limit is ${input.rulesPerResource}`,
      };
    }
  }
  if (rules.length > input.rulesPerMesh) {
    return {
      ok: false,
      reason: "perMesh",
      count: rules.length,
      message: `This policy compiles to ${rules.length} firewall rules; the mesh limit is ${input.rulesPerMesh}`,
    };
  }
  return { ok: true, rules };
};

/** Splits current rules (by key) against desired ones: create these, then delete those. */
export const planApply = <T extends { readonly key: string }>(
  current: ReadonlyArray<T>,
  desired: ReadonlyArray<DesiredRule>,
): { readonly create: ReadonlyArray<DesiredRule>; readonly remove: ReadonlyArray<T> } => {
  const desiredKeys = new Set(desired.map((rule) => rule.key));
  const currentKeys = new Set(current.map((rule) => rule.key));
  return {
    create: desired.filter((rule) => !currentKeys.has(rule.key)),
    remove: current.filter((rule) => !desiredKeys.has(rule.key)),
  };
};

/** What one device may reach through its tunnel, grouped by VM (address rules open only the overlay port, not a service). */
export const peersOf = (deviceId: string, rules: ReadonlyArray<DesiredRule>): ReadonlyMap<string, ReadonlyArray<DesiredRule>> => {
  const out = new Map<string, DesiredRule[]>();
  for (const rule of rules) {
    if (rule.deviceId !== deviceId || rule.cidr !== null) continue;
    const list = out.get(rule.vmId) ?? [];
    list.push(rule);
    out.set(rule.vmId, list);
  }
  return out;
};
